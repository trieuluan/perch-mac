//
//  SystemAudioAnalyzer.swift
//  Perch
//
//  Taps the Mac's system audio output with a Core Audio process tap (macOS 14.2+)
//  and turns it into a few frequency bands for the music visualizer.
//
//  Audio never leaves the process: samples go into a small ring buffer and are
//  only used to compute band levels.
//

import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os

@MainActor
final class SystemAudioAnalyzer {
    static let shared = SystemAudioAnalyzer()

    private let logger = Logger(subsystem: "com.trieuluan.perch", category: "Visualizer")

    // MARK: Tap state

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleRate: Double = 48_000
    private var consumers = 0
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let ioQueue = DispatchQueue(label: "com.trieuluan.perch.visualizer.io", qos: .userInteractive)

    // MARK: Analysis state

    private static let fftSize = 1024
    private let ring = OSAllocatedUnfairLock(initialState: RingBuffer(capacity: fftSize))
    private let fft = FFTHelper(size: fftSize)
    /// Auto-gain peaks per requested band count, so views asking for different
    /// numbers of bands don't reset each other.
    private var peaks: [Int: [Float]] = [:]
    private var lastSignal = Date.distantPast

    /// True when real audio has been seen recently. When false (no permission,
    /// tap failed, or silence) the view falls back to its idle animation.
    var hasSignal: Bool { Date().timeIntervalSince(lastSignal) < 1.5 }

    /// Raw per-frame features from the last `bands(count:)` call, computed on
    /// unnormalized magnitudes (band levels are auto-gained, so they can't say
    /// which part of the spectrum is really dominant).
    struct Features {
        /// Pitch of the strongest note between ~150 Hz and ~2 kHz, as 0...1 on a log scale.
        var melody: Float = 0.5
        /// How clearly that note stands out from its neighbours, 0...1.
        var melodyStrength: Float = 0
        /// Spectral centroid ("how bright the sound is"), 0 = dark/warm ... 1 = bright/airy.
        var brightness: Float = 0.5
    }

    private(set) var features = Features()

    private init() {}

    // MARK: - Lifecycle

    /// Reference-counted: the tap runs while at least one visualizer is playing.
    func start() {
        consumers += 1
        guard consumers == 1 else { return }
        startTap()
        observeDefaultOutputDevice()
    }

    func stop() {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        stopObservingDefaultOutputDevice()
        stopTap()
    }

    // MARK: - Bands

    /// Returns `count` band levels in 0...1, low frequencies first.
    func bands(count: Int) -> [Float] {
        let samples = ring.withLock { $0.latest() }
        guard samples.count == Self.fftSize else { return Array(repeating: 0, count: count) }

        // Silence gate.
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        guard rms > 0.0005 else {
            features.melodyStrength = 0
            return Array(repeating: 0, count: count)
        }
        lastSignal = Date()

        let magnitudes = fft.magnitudes(of: samples)
        let binHz = Float(sampleRate) / Float(Self.fftSize)
        features = Self.features(magnitudes: magnitudes, binHz: binHz)

        // Log-spaced band edges between ~60 Hz and ~12 kHz.
        let low: Float = 60
        let high: Float = min(12_000, Float(sampleRate) / 2)
        let ratio = pow(high / low, 1 / Float(count))

        var bandPeaks = peaks[count] ?? Array(repeating: 0.0001, count: count)

        var result = [Float](repeating: 0, count: count)
        for band in 0 ..< count {
            let fromHz = low * pow(ratio, Float(band))
            let toHz = fromHz * ratio
            let fromBin = max(1, Int(fromHz / binHz))
            let toBin = min(magnitudes.count - 1, max(fromBin + 1, Int(toHz / binHz)))

            var level: Float = 0
            magnitudes[fromBin ..< toBin].withUnsafeBufferPointer {
                vDSP_meanv($0.baseAddress!, 1, &level, vDSP_Length($0.count))
            }

            // Simple per-band automatic gain: follow the recent peak, decay slowly.
            bandPeaks[band] = max(level, bandPeaks[band] * 0.995)
            result[band] = min(1, level / max(bandPeaks[band], 0.0001))
        }
        peaks[count] = bandPeaks
        return result
    }

    private static func features(magnitudes: [Float], binHz: Float) -> Features {
        var result = Features()

        // Spectral centroid between 60 Hz and 12 kHz, mapped log-wise from 300 Hz to 6 kHz.
        let lowBin = max(1, Int(60 / binHz))
        let highBin = min(magnitudes.count - 1, Int(12_000 / binHz))
        var weighted: Float = 0
        var total: Float = 0
        for bin in lowBin ... highBin {
            weighted += Float(bin) * binHz * magnitudes[bin]
            total += magnitudes[bin]
        }
        if total > 0 {
            let centroid = weighted / total
            result.brightness = min(1, max(0, log2(centroid / 300) / log2(6000 / 300)))
        }

        // Dominant note in the melody range.
        let melodyLow = max(1, Int(150 / binHz))
        let melodyHigh = min(magnitudes.count - 1, Int(2000 / binHz))
        var peakBin = melodyLow
        var peak: Float = 0
        var sum: Float = 0
        for bin in melodyLow ... melodyHigh {
            sum += magnitudes[bin]
            if magnitudes[bin] > peak {
                peak = magnitudes[bin]
                peakBin = bin
            }
        }
        let mean = sum / Float(melodyHigh - melodyLow + 1)
        if mean > 0 {
            let frequency = Float(peakBin) * binHz
            result.melody = min(1, max(0, log2(frequency / 150) / log2(2000 / 150)))
            result.melodyStrength = min(1, max(0, (peak / mean - 2.5) / 6))
        }
        return result
    }

    // MARK: - Core Audio tap

    private func startTap() {
        guard #available(macOS 14.2, *) else {
            logger.info("Process taps need macOS 14.2+; using idle animation")
            return
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Perch Visualizer"

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else {
            logger.error("AudioHardwareCreateProcessTap failed: \(status)")
            return
        }
        tapID = newTap

        guard let outputUID = Self.defaultOutputDeviceUID() else {
            logger.error("No default output device")
            stopTap()
            return
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Perch Visualizer Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard status == noErr else {
            logger.error("AudioHardwareCreateAggregateDevice failed: \(status)")
            stopTap()
            return
        }
        aggregateID = newAggregate

        if let format = Self.tapFormat(tapID) {
            sampleRate = format.mSampleRate
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue, Self.makeIOBlock(ring: ring))
        guard status == noErr, let ioProcID else {
            logger.error("AudioDeviceCreateIOProcIDWithBlock failed: \(status)")
            stopTap()
            return
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            logger.error("AudioDeviceStart failed: \(status)")
            stopTap()
            return
        }
        logger.info("System audio tap started (\(self.sampleRate, privacy: .public) Hz)")
    }

    /// Built outside the main actor: the block runs on the realtime IO queue.
    private nonisolated static func makeIOBlock(ring: OSAllocatedUnfairLock<RingBuffer>) -> AudioDeviceIOBlock {
        return { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let samples = data.assumingMemoryBound(to: Float.self)
            ring.withLock { $0.append(interleaved: samples, frames: frames, channels: channels) }
        }
    }

    private func stopTap() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        ring.withLock { $0.reset() }
        peaks = [:]
    }

    // MARK: - Output device changes (e.g. AirPods connected)

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func observeDefaultOutputDevice() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.consumers > 0 else { return }
                self.stopTap()
                self.startTap()
            }
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, listener)
    }

    private func stopObservingDefaultOutputDevice() {
        guard let outputListener else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, outputListener)
        self.outputListener = nil
    }

    // MARK: - Core Audio helpers

    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultOutputAddress
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr
        else { return nil }

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }
}

// MARK: - Ring buffer (mono, filled from the IO thread)

private struct RingBuffer {
    private var storage: [Float]
    private var writeIndex = 0
    private var filled = 0

    init(capacity: Int) {
        storage = Array(repeating: 0, count: capacity)
    }

    mutating func append(interleaved samples: UnsafePointer<Float>, frames: Int, channels: Int) {
        let capacity = storage.count
        for frame in 0 ..< frames {
            var sum: Float = 0
            for channel in 0 ..< channels { sum += samples[frame * channels + channel] }
            storage[writeIndex] = sum / Float(channels)
            writeIndex = (writeIndex + 1) % capacity
        }
        filled = min(capacity, filled + frames)
    }

    /// The buffer contents in chronological order, or empty until it has filled once.
    func latest() -> [Float] {
        guard filled == storage.count else { return [] }
        return Array(storage[writeIndex...] + storage[..<writeIndex])
    }

    mutating func reset() {
        for i in storage.indices { storage[i] = 0 }
        writeIndex = 0
        filled = 0
    }
}

// MARK: - FFT

private final class FFTHelper {
    private let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]

    init(size: Int) {
        self.size = size
        log2n = vDSP_Length(log2(Float(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = Array(repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Magnitudes of the first `size / 2` frequency bins.
    func magnitudes(of samples: [Float]) -> [Float] {
        var windowed = [Float](repeating: 0, count: size)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))

        let half = size / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        return magnitudes
    }
}

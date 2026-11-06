//
//  AudioOutputManager.swift
//  Perch
//
//  Lists the Mac's audio outputs, switches between them, and announces in the
//  notch when headphones or a Bluetooth speaker connect (with battery levels
//  when the helper can read them).
//

import AppKit
import CoreAudio
import Defaults

extension Defaults.Keys {
    static let headphonesAlerts = Key<Bool>("perchHeadphonesAlerts", default: true)
    /// Set once the audio output button has been offered in the music player.
    static let audioOutputSlotAdded = Key<Bool>("perchAudioOutputSlotAdded", default: false)
}

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker"
        default: return "speaker.wave.2"
        }
    }
}

@MainActor
final class AudioOutputManager: ObservableObject {
    static let shared = AudioOutputManager()

    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var currentID: AudioObjectID = kAudioObjectUnknown

    private var started = false
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private init() {}

    /// Call once at launch.
    func start() {
        guard !started else { return }
        started = true
        refresh(announce: false)
        addMigrationSlotIfNeeded()

        // When headphones connect, the "default output changed" event can arrive
        // before "devices changed", so either one may be the first to see the new
        // device; both announce newcomers.
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(Self.system, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh(announce: true) }
            }
        }
    }

    func select(_ device: AudioOutputDevice) {
        var id = device.id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(Self.system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
        refresh(announce: false)
    }

    var current: AudioOutputDevice? { devices.first { $0.id == currentID } }

    // MARK: - Refresh

    private func refresh(announce: Bool) {
        let previous = Set(devices.map(\.uid))
        devices = Self.outputDevices()
        currentID = Self.defaultOutputID()

        guard announce, Defaults[.headphonesAlerts] else { return }
        for device in devices where device.isBluetooth && !previous.contains(device.uid) {
            announceConnection(of: device)
        }
    }

    private func announceConnection(of device: AudioOutputDevice) {
        let connected = String(localized: "\(device.name) connected")
        PerchLiveActivity.shared.show(.init(symbol: device.symbol, tint: .blue, text: connected), for: 4)
        Task {
            // Battery comes from System Information, which takes a moment.
            guard let battery = await XPCHelperClient.shared.bluetoothBattery(deviceName: device.name) else { return }
            PerchLiveActivity.shared.show(
                .init(symbol: device.symbol, tint: .blue, text: "\(device.name) · \(battery)"), for: 4)
        }
    }

    /// Puts the output button in the music player's last free slot once, so
    /// existing users discover it; they can move or remove it in Settings.
    private func addMigrationSlotIfNeeded() {
        guard !Defaults[.audioOutputSlotAdded] else { return }
        Defaults[.audioOutputSlotAdded] = true
        var slots = Defaults[.musicControlSlots]
        guard !slots.contains(.audioOutput), let free = slots.lastIndex(of: .none) else { return }
        slots[free] = .audioOutput
        Defaults[.musicControlSlots] = slots
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputID() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id)
        return id
    }

    private static func outputDevices() -> [AudioOutputDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutput(id) else { return nil }
            let transport: UInt32 = property(id, kAudioDevicePropertyTransportType) ?? 0
            // Skip aggregate and virtual devices, including Perch's own visualizer tap.
            guard transport != kAudioDeviceTransportTypeAggregate,
                  transport != kAudioDeviceTransportTypeVirtual,
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID)
            else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name, transport: transport)
        }
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

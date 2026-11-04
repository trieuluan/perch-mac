//
//  LiveAudioSpectrumView.swift
//  Perch
//
//  Drop-in replacement for upstream's AudioSpectrumView: same 4-bar, 16x14pt
//  geometry, but the bars follow the real system audio. Falls back to the
//  original random animation when there is no signal (no permission yet,
//  tap unavailable, or silence).
//

import AppKit
import SwiftUI

final class LiveAudioSpectrum: NSView {
    private static let barCount = 4
    private static let barWidth: CGFloat = 2
    private static let barHeight: CGFloat = 14
    private static let minScale: CGFloat = 0.2

    private var barLayers: [CAShapeLayer] = []
    private var levels: [CGFloat] = Array(repeating: minScale, count: barCount)
    private var timer: Timer?
    private var tick = 0
    private var isPlaying = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupBars()
    }

    deinit {
        timer?.invalidate()
        if isPlaying {
            MainActor.assumeIsolated { SystemAudioAnalyzer.shared.stop() }
        }
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if playing {
            SystemAudioAnalyzer.shared.start()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        } else {
            timer?.invalidate()
            timer = nil
            SystemAudioAnalyzer.shared.stop()
            apply(Array(repeating: Self.minScale, count: Self.barCount), animated: true)
        }
    }

    // MARK: - Drawing

    private func setupBars() {
        wantsLayer = true
        let spacing = Self.barWidth
        frame.size = CGSize(width: CGFloat(Self.barCount) * (Self.barWidth + spacing), height: Self.barHeight)

        for i in 0 ..< Self.barCount {
            let x = CGFloat(i) * (Self.barWidth + spacing)
            let bar = CAShapeLayer()
            bar.frame = CGRect(x: x, y: 0, width: Self.barWidth, height: Self.barHeight)
            bar.position = CGPoint(x: x + Self.barWidth / 2, y: Self.barHeight / 2)
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = Self.barWidth / 2
            bar.transform = CATransform3DMakeScale(1, Self.minScale, 1)
            barLayers.append(bar)
            layer?.addSublayer(bar)
        }
    }

    @MainActor
    private func update() {
        let analyzer = SystemAudioAnalyzer.shared
        let bands = analyzer.bands(count: Self.barCount)

        if analyzer.hasSignal {
            // Rise fast, fall slowly.
            for i in 0 ..< Self.barCount {
                let target = Self.minScale + (1 - Self.minScale) * CGFloat(bands[i])
                let speed: CGFloat = target > levels[i] ? 0.6 : 0.2
                levels[i] += (target - levels[i]) * speed
            }
            apply(levels, animated: false)
        } else {
            // Idle animation like upstream: a new random height every ~0.3s.
            tick += 1
            guard tick % 9 == 0 else { return }
            levels = (0 ..< Self.barCount).map { _ in CGFloat.random(in: 0.35 ... 1.0) }
            apply(levels, animated: true)
        }
    }

    private func apply(_ scales: [CGFloat], animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.3)
        } else {
            CATransaction.setDisableActions(true)
        }
        for (bar, scale) in zip(barLayers, scales) {
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
        CATransaction.commit()
    }
}

struct LiveAudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool

    func makeNSView(context: Context) -> LiveAudioSpectrum {
        let view = LiveAudioSpectrum()
        view.setPlaying(isPlaying)
        return view
    }

    func updateNSView(_ nsView: LiveAudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ nsView: LiveAudioSpectrum, coordinator: ()) {
        nsView.setPlaying(false)
    }
}

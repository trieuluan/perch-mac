//
//  VisualizerEngine.swift
//  Perch
//
//  Publishes smoothed spectrum levels at 30fps for SwiftUI and menu bar
//  visualizers. Runs only while at least one visualizer is visible and music
//  is playing.
//

import Combine
import Defaults
import Foundation

extension Defaults.Keys {
    static let menuBarVisualizer = Key<Bool>("perchMenuBarVisualizer", default: true)
}

/// Smoothed, musically meaningful features shared by every visualizer so they
/// all react the same way.
struct MusicFeatures {
    /// Pitch of the lead note: 0 = low, 1 = high.
    var melody: CGFloat = 0.5
    /// How clearly a lead note stands out right now, 0...1.
    var melodyStrength: CGFloat = 0
    /// How bright the overall sound is: 0 = warm/dark, 1 = airy/bright.
    var brightness: CGFloat = 0.5

    /// Emphasis for something at `position` 0...1 on the pitch axis, peaking
    /// where the melody is. Effects laid out with the bass in the middle pass
    /// their distance from the center.
    func melodyBoost(at position: CGFloat, width: CGFloat = 0.14) -> CGFloat {
        let d = (position - melody) / width
        return melodyStrength * exp(-d * d)
    }
}

@MainActor
final class VisualizerEngine: ObservableObject {
    static let shared = VisualizerEngine()
    static let bandCount = 24

    /// 0...1 per band, low frequencies first.
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0, count: bandCount)
    /// Lead-note pitch and tonal brightness, smoothed.
    @Published private(set) var features = MusicFeatures()

    private var consumers = 0
    private var timer: Timer?

    private init() {}

    func start() {
        consumers += 1
        guard consumers == 1 else { return }
        SystemAudioAnalyzer.shared.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func stop() {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        timer?.invalidate()
        timer = nil
        SystemAudioAnalyzer.shared.stop()
        levels = Array(repeating: 0, count: Self.bandCount)
        features.melodyStrength = 0
    }

    /// Averages the engine's bands down to `count` values.
    func levels(_ count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let source = levels
        return (0 ..< count).map { i in
            let from = i * source.count / count
            let to = max(from + 1, (i + 1) * source.count / count)
            let slice = source[from ..< to]
            return slice.reduce(0, +) / CGFloat(slice.count)
        }
    }

    private func update() {
        let analyzer = SystemAudioAnalyzer.shared
        let bands = analyzer.bands(count: Self.bandCount)
        let hasSignal = analyzer.hasSignal

        var next = levels
        for i in 0 ..< Self.bandCount {
            let target = hasSignal ? CGFloat(bands[i]) : 0
            let speed: CGFloat = target > next[i] ? 0.55 : 0.18
            next[i] += (target - next[i]) * speed
        }
        levels = next

        var f = features
        if hasSignal {
            let raw = analyzer.features
            // Glide the pitch only while a note is clearly there, so it doesn't jitter.
            if raw.melodyStrength > 0.15 {
                f.melody += (CGFloat(raw.melody) - f.melody) * 0.25
            }
            f.melodyStrength += (CGFloat(raw.melodyStrength) - f.melodyStrength) * 0.3
            // Brightness follows slowly: it describes the section, not single notes.
            f.brightness += (CGFloat(raw.brightness) - f.brightness) * 0.04
        } else {
            f.melodyStrength *= 0.85
        }
        features = f
    }
}

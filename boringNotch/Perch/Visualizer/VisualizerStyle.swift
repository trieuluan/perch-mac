//
//  VisualizerStyle.swift
//  Perch
//
//  Settings for which visualizers are shown and how they are colored.
//

import AppKit
import Defaults
import SwiftUI

enum VisualizerColorMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case albumArt
    case monochrome
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .albumArt: return String(localized: "Album art")
        case .monochrome: return String(localized: "Monochrome")
        case .custom: return String(localized: "Custom gradient")
        }
    }
}

enum PlayerBackgroundStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case none
    case particles
    case aurora
    case pulse
    case ripples
    case silk
    case bars
    case warp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "None")
        case .particles: return String(localized: "Floating particles")
        case .aurora: return String(localized: "Aurora")
        case .pulse: return String(localized: "Pulse glow")
        case .ripples: return String(localized: "Beat ripples")
        case .silk: return String(localized: "Silk lines")
        case .bars: return String(localized: "Spectrum bars")
        case .warp: return String(localized: "Warp speed")
        }
    }

    var detail: String {
        switch self {
        case .none: return String(localized: "No background behind the player.")
        case .particles: return String(localized: "Glowing dust that follows the music: brightest around the melody, rises with the bass, sparks on snares, twinkles on hi-hats and notes.")
        case .aurora: return String(localized: "Soft ribbons of light swaying with the melody. Good for ambient and chill.")
        case .pulse: return String(localized: "A glow behind the album art that breathes with the beat.")
        case .ripples: return String(localized: "Rings on every drum hit and note attack: thick for kicks, thin for hi-hats, pitch-colored for plucked or played notes. Works with or without drums.")
        case .silk: return String(localized: "Thin lines rippling across the player. Good for acoustic and piano.")
        case .bars: return String(localized: "Thin bars fading upward, with peak caps that hold and fall slowly. Bass in the middle.")
        case .warp: return String(localized: "Stars streaking toward you, faster on the bass. Good for fast tracks.")
        }
    }

    /// How strongly the effect shows behind text and controls.
    var opacity: Double {
        switch self {
        case .particles: return 0.8
        case .warp: return 0.8
        default: return 1
        }
    }
}

struct GradientPreset: Identifiable {
    let name: String
    let colors: [String]
    var id: String { name }

    static let all: [GradientPreset] = [
        GradientPreset(name: "Sunset", colors: ["#FF5F6D", "#FFC371"]),
        GradientPreset(name: "Ocean", colors: ["#2193B0", "#6DD5ED"]),
        GradientPreset(name: "Neon", colors: ["#F72585", "#7209B7", "#4CC9F0"]),
        GradientPreset(name: "Aurora", colors: ["#00F5A0", "#00D9F5", "#7B61FF"]),
        GradientPreset(name: "Ember", colors: ["#F83600", "#F9D423"]),
    ]
}

extension Defaults.Keys {
    /// The small bars beside the album art in the closed notch.
    static let closedNotchBars = Key<Bool>("perchClosedNotchBars", default: true)
    static let visualizerColorMode = Key<VisualizerColorMode>("perchVisualizerColorMode", default: .albumArt)
    static let visualizerGradient = Key<[String]>("perchVisualizerGradient", default: GradientPreset.all[0].colors)
    static let playerBackground = Key<PlayerBackgroundStyle>("perchPlayerBackground", default: .particles)
}

/// Resolves the colors every visualizer should use right now.
enum VisualizerPalette {
    /// Upstream's "Colored spectrogram" setting (no longer shown) also tints the
    /// Sneak Peek artist name and gates album-art color sampling. Keep it in step
    /// with Perch's color mode. Call at launch and when the mode changes.
    static func syncUpstreamColorSetting() {
        Defaults[.coloredSpectrogram] = Defaults[.visualizerColorMode] == .albumArt
    }

    /// Colors from left to right (or bottom to top), already shifted by how
    /// bright the music sounds right now.
    @MainActor
    static func colors(albumArt: NSColor = MusicManager.shared.avgColor) -> [Color] {
        let brightness = VisualizerEngine.shared.features.brightness
        switch Defaults[.visualizerColorMode] {
        case .albumArt:
            // Vivid colors picked from the cover (not the gray-ish average),
            // shifted along with the music like a custom gradient.
            return shift(AlbumArtPalette.shared.colors, by: brightness)
        case .monochrome:
            let white = Color.white.opacity(0.7 + 0.25 * Double(brightness))
            return [white, white]
        case .custom:
            let colors = Defaults[.visualizerGradient].compactMap(Color.init(perchHex:))
            switch colors.count {
            case 0: return [.white, .white]
            case 1:
                let color = lighten(colors[0], by: brightness)
                return [color, color]
            default: return shift(colors, by: brightness)
            }
        }
    }

    /// Slides a 60%-wide window along the gradient: warm, bassy music leans to
    /// the first colors, bright, airy music to the last ones.
    private static func shift(_ colors: [Color], by brightness: CGFloat) -> [Color] {
        let start = 0.4 * max(0, min(1, brightness))
        let count = colors.count
        return (0 ..< count).map { i in
            sample(colors, at: start + 0.6 * CGFloat(i) / CGFloat(count - 1))
        }
    }

    /// Single-color modes get lighter as the music gets brighter.
    private static func lighten(_ color: Color, by brightness: CGFloat) -> Color {
        lighten(color, amount: max(0, brightness - 0.45) * 0.6)
    }

    /// Mixes `color` toward white by `amount` 0...1.
    static func lighten(_ color: Color, amount: CGFloat) -> Color {
        mix(color, .white, amount)
    }

    /// Color at position 0...1 along the gradient stops.
    static func sample(_ colors: [Color], at t: CGFloat) -> Color {
        guard colors.count > 1 else { return colors.first ?? .white }
        let x = max(0, min(1, t)) * CGFloat(colors.count - 1)
        let i = min(colors.count - 2, Int(x))
        return mix(colors[i], colors[i + 1], x - CGFloat(i))
    }

    private static func mix(_ a: Color, _ b: Color, _ t: CGFloat) -> Color {
        let ca = NSColor(a).usingColorSpace(.sRGB) ?? .white
        let cb = NSColor(b).usingColorSpace(.sRGB) ?? .white
        let t = max(0, min(1, t))
        return Color(
            .sRGB,
            red: Double(ca.redComponent + (cb.redComponent - ca.redComponent) * t),
            green: Double(ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t),
            blue: Double(ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t),
            opacity: Double(ca.alphaComponent + (cb.alphaComponent - ca.alphaComponent) * t)
        )
    }

    @MainActor
    static func horizontal(albumArt: NSColor = MusicManager.shared.avgColor) -> LinearGradient {
        LinearGradient(colors: colors(albumArt: albumArt), startPoint: .leading, endPoint: .trailing)
    }

    @MainActor
    static func vertical(albumArt: NSColor = MusicManager.shared.avgColor) -> LinearGradient {
        LinearGradient(colors: colors(albumArt: albumArt), startPoint: .bottom, endPoint: .top)
    }
}

// MARK: - Hex helpers

extension Color {
    init?(perchHex hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    var perchHex: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}

// MARK: - Engine lifetime

extension View {
    /// Keeps VisualizerEngine running while this view is on screen and `active`.
    func runsVisualizerEngine(_ active: Bool) -> some View {
        modifier(VisualizerEngineConsumer(active: active))
    }
}

private struct VisualizerEngineConsumer: ViewModifier {
    let active: Bool
    @State private var running = false

    func body(content: Content) -> some View {
        content
            .onAppear { set(active) }
            .onDisappear { set(false) }
            .onChange(of: active) { _, value in set(value) }
    }

    private func set(_ run: Bool) {
        guard run != running else { return }
        running = run
        if run {
            VisualizerEngine.shared.start()
        } else {
            VisualizerEngine.shared.stop()
        }
    }
}

//
//  MenuBarOverlayView.swift
//  Perch
//
//  Visualizer effects drawn across the whole menu bar. The overlay sits on top
//  of the menu bar (macOS doesn't allow drawing underneath its items), so every
//  style is either thin or translucent to keep menus and icons readable.
//

import Defaults
import SwiftUI

enum MenuBarOverlayStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case none
    case fromNotch
    case silhouette
    case ledMeter
    case helix
    case blocks3D
    case waveLine
    case pulseLine
    case comets
    case notchRipples
    case bassGlow
    case fullBars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "Off")
        case .fromNotch: return String(localized: "Spread from notch")
        case .silhouette: return String(localized: "Spectrum silhouette")
        case .ledMeter: return String(localized: "LED meter")
        case .pulseLine: return String(localized: "Heartbeat line")
        case .comets: return String(localized: "Beat comets")
        case .notchRipples: return String(localized: "Notch ripples")
        case .helix: return String(localized: "3D helix")
        case .blocks3D: return String(localized: "3D blocks")
        case .waveLine: return String(localized: "Flowing wave")
        case .bassGlow: return String(localized: "Bass glow")
        case .fullBars: return String(localized: "Full-height bars")
        }
    }

    var detail: String {
        switch self {
        case .none: return String(localized: "No overlay on the menu bar.")
        case .fromNotch: return String(localized: "Bass right beside the notch, highs spreading to the edges.")
        case .silhouette: return String(localized: "A smooth, filled mountain range of the spectrum flowing out of the notch.")
        case .ledMeter: return String(localized: "Retro LED dots lighting up row by row, like a hi-fi level meter.")
        case .pulseLine: return String(localized: "A heartbeat trace scrolling out from the notch, spiking on kicks and snares.")
        case .comets: return String(localized: "Streaks shooting out of the notch on every drum hit and note. Great for rhythmic songs.")
        case .notchRipples: return String(localized: "Arcs spreading out from under the notch on kicks, snares and notes.")
        case .helix: return String(localized: "Two strands twisting in 3D out of the notch, swelling with each part of the spectrum.")
        case .blocks3D: return String(localized: "Little 3D blocks rising from the notch outward, with lit tops and shaded sides.")
        case .waveLine: return String(localized: "Two interlaced, glowing waves flowing out of the notch along the bottom edge.")
        case .bassGlow: return String(localized: "A soft light spreading from the notch along the bottom edge, further on every beat.")
        case .fullBars: return String(localized: "Translucent bars the height of the menu bar. Most striking.")
        }
    }
}

extension Defaults.Keys {
    static let menuBarOverlay = Key<MenuBarOverlayStyle>("perchMenuBarOverlay", default: .fromNotch)
    static let menuBarOverlayIntensity = Key<Double>("perchMenuBarOverlayIntensity", default: 0.7)
}

/// Horizontal geometry of the notch inside the overlay, in overlay points.
struct NotchGap {
    var minX: CGFloat
    var maxX: CGFloat
}

struct MenuBarOverlayView: View {
    /// The physical notch. While music plays, Perch's closed notch widens to
    /// show the album art and bars, so effects start from that wider edge.
    let physicalNotch: NotchGap

    init(notch: NotchGap) {
        physicalNotch = notch
    }

    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    private var notch: NotchGap {
        let liveActivity = coordinator.musicLiveActivityEnabled && (music.isPlaying || !music.isPlayerIdle)
        let inset: CGFloat = liveActivity ? 46 : 0
        return NotchGap(minX: physicalNotch.minX - inset, maxX: physicalNotch.maxX + inset)
    }

    @ObservedObject private var engine = VisualizerEngine.shared
    @ObservedObject private var music = MusicManager.shared
    @Default(.menuBarOverlay) private var style
    @Default(.menuBarOverlayIntensity) private var intensity
    @Default(.visualizerColorMode) private var colorMode
    @Default(.visualizerGradient) private var gradient
    @State private var state = MenuBarOverlayState()

    var body: some View {
        let colors = VisualizerPalette.colors(albumArt: music.avgColor)
        let source = engine.levels
        let features = engine.features
        let time = Date().timeIntervalSinceReferenceDate
        let _ = state.update(levels: source, features: features, time: time)
        Canvas { context, size in
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
            switch style {
            case .none: break
            case .fromNotch: Self.drawFromNotch(&context, size, source, shading, notch, features)
            case .helix: MenuBarOverlayEffects.drawHelix(&context, size, source, notch, time, colors)
            case .blocks3D: MenuBarOverlayEffects.drawBlocks3D(&context, size, source, notch, features, colors)
            case .waveLine: Self.drawWave(&context, size, source, shading, notch, features)
            case .silhouette: MenuBarOverlayEffects.drawSilhouette(&context, size, source, notch, features, colors)
            case .ledMeter: MenuBarOverlayEffects.drawLEDMeter(&context, size, source, notch, features, colors, state, time)
            case .pulseLine: MenuBarOverlayEffects.drawPulseLine(&context, size, state, notch, colors)
            case .comets: MenuBarOverlayEffects.drawComets(&context, size, state, notch, time, colors)
            case .notchRipples: MenuBarOverlayEffects.drawNotchRipples(&context, size, state, notch, time, colors)
            case .bassGlow: MenuBarOverlayEffects.drawBassGlow(&context, size, state, notch, features, colors)
            case .fullBars: Self.drawFullBars(&context, size, source, shading, features)
            }
        }
        .opacity(music.isPlaying ? intensity : 0)
        .animation(.smooth(duration: 0.5), value: music.isPlaying)
        .runsVisualizerEngine(music.isPlaying && style != .none)
        .allowsHitTesting(false)
    }

    // MARK: - Sampling

    /// Linearly interpolated level at position 0...1 (0 = bass).
    private static func sample(_ levels: [CGFloat], at position: CGFloat) -> CGFloat {
        guard levels.count > 1 else { return levels.first ?? 0 }
        let x = max(0, min(1, position)) * CGFloat(levels.count - 1)
        let i = Int(x)
        let next = min(levels.count - 1, i + 1)
        let t = x - CGFloat(i)
        return levels[i] * (1 - t) + levels[next] * t
    }

    // MARK: - Styles

    private static func drawFromNotch(_ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [CGFloat],
                                      _ shading: GraphicsContext.Shading, _ notch: NotchGap,
                                      _ features: MusicFeatures) {
        let barWidth: CGFloat = 6
        let gap: CGFloat = 4
        let step = barWidth + gap
        let leftSpan = notch.minX - 6
        let rightSpan = size.width - notch.maxX - 6
        let perSide = Int(max(leftSpan, rightSpan) / step)
        guard perSide > 0 else { return }

        for i in 0 ..< perSide {
            let u = CGFloat(i) / CGFloat(perSide)
            let level = sample(levels, at: u)
            let boost = features.melodyBoost(at: u)
            let fade = 1 - u
            let height = max(2, size.height * min(1, level * (0.35 + 0.6 * fade) + 0.45 * boost))
            var layer = ctx
            layer.opacity = min(1, 0.15 + 0.6 * fade + 0.5 * boost)

            let leftX = notch.minX - 6 - CGFloat(i + 1) * step + gap / 2
            if leftX >= 0 {
                layer.fill(Path(roundedRect: CGRect(x: leftX, y: size.height - height, width: barWidth, height: height),
                                cornerRadius: 1.5), with: shading)
            }
            let rightX = notch.maxX + 6 + CGFloat(i) * step + gap / 2
            if rightX + barWidth <= size.width {
                layer.fill(Path(roundedRect: CGRect(x: rightX, y: size.height - height, width: barWidth, height: height),
                                cornerRadius: 1.5), with: shading)
            }
        }
    }

    /// Two interlaced waves along the bottom edge, travelling outward from the
    /// notch, with a soft glow under the main one. Stays in the lower part of
    /// the bar so it never crosses menu titles or icons.
    private static func drawWave(_ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [CGFloat],
                                 _ shading: GraphicsContext.Shading, _ notch: NotchGap,
                                 _ features: MusicFeatures) {
        let baseline = size.height - 9
        let maxAmplitude: CGFloat = 7.5
        let time = CGFloat(Date().timeIntervalSinceReferenceDate)
        let reach = max(1, min(notch.minX, size.width - notch.maxX) - 4)
        let colors = shading // horizontal palette for the whole bar

        // (frequency, speed, phase offset, amplitude scale)
        let waves: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(18, 3.0, 0, 1), (23, 2.3, .pi * 0.6, 0.65)]

        func path(direction: CGFloat, wave: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Path {
            var path = Path()
            let start = direction < 0 ? notch.minX : notch.maxX
            let steps = Int(reach / 3)
            for s in 0 ... steps {
                let d = CGFloat(s) / CGFloat(steps) * reach
                let u = d / reach
                let level = sample(levels, at: u)
                let boost = features.melodyBoost(at: u)
                let amplitude = min(maxAmplitude, maxAmplitude * (0.2 + level + 1.2 * boost)) * wave.3
                // Ease in from the notch so the wave starts flat at its edge.
                let ease = min(1, d / 30)
                let y = baseline + sin(d / wave.0 - time * wave.1 + wave.2) * amplitude * ease
                let point = CGPoint(x: start + direction * d, y: y)
                if s == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }

        for direction in [-1.0, 1.0] as [CGFloat] {
            let main = path(direction: direction, wave: waves[0])
            let second = path(direction: direction, wave: waves[1])

            // Glow under the main wave.
            var glow = ctx
            glow.addFilter(.blur(radius: 4))
            glow.opacity = 0.55
            glow.stroke(main, with: colors, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

            // Fainter second wave, out of phase, for a ribbon-like depth.
            var back = ctx
            back.opacity = 0.45
            back.stroke(second, with: colors, style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))

            ctx.stroke(main, with: colors, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }
    }

    private static func drawFullBars(_ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [CGFloat],
                                     _ shading: GraphicsContext.Shading, _ features: MusicFeatures) {
        let count = 48
        let step = size.width / CGFloat(count)
        for i in 0 ..< count {
            let u = abs(CGFloat(i) / CGFloat(count - 1) - 0.5) * 2
            let boost = features.melodyBoost(at: u)
            let height = max(2, min(1, sample(levels, at: u) + 0.35 * boost) * size.height)
            var layer = ctx
            layer.opacity = 0.32 + 0.3 * Double(boost)
            layer.fill(Path(roundedRect: CGRect(x: CGFloat(i) * step + 3, y: size.height - height,
                                                width: step - 6, height: height), cornerRadius: 2),
                       with: shading)
        }
    }
}

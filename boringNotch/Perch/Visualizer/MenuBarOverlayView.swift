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
    case edgeBars
    case waveLine
    case bassGlow
    case fullBars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "Off")
        case .fromNotch: return String(localized: "Spread from notch")
        case .edgeBars: return String(localized: "Edge bars")
        case .waveLine: return String(localized: "Flowing wave")
        case .bassGlow: return String(localized: "Bass glow")
        case .fullBars: return String(localized: "Full-height bars")
        }
    }

    var detail: String {
        switch self {
        case .none: return String(localized: "No overlay on the menu bar.")
        case .fromNotch: return String(localized: "Bass right beside the notch, highs spreading to the edges.")
        case .edgeBars: return String(localized: "A thin spectrum along the bottom edge. Never covers text.")
        case .waveLine: return String(localized: "A smooth wave gliding along the bottom edge.")
        case .bassGlow: return String(localized: "The bottom edge glows and pulses with the beat.")
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
    let notch: NotchGap

    @ObservedObject private var engine = VisualizerEngine.shared
    @ObservedObject private var music = MusicManager.shared
    @Default(.menuBarOverlay) private var style
    @Default(.menuBarOverlayIntensity) private var intensity
    @Default(.visualizerColorMode) private var colorMode
    @Default(.visualizerGradient) private var gradient

    var body: some View {
        let colors = VisualizerPalette.colors(albumArt: music.avgColor)
        let source = engine.levels
        let features = engine.features
        Canvas { context, size in
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
            switch style {
            case .none: break
            case .fromNotch: Self.drawFromNotch(&context, size, source, shading, notch, features)
            case .edgeBars: Self.drawEdgeBars(&context, size, source, shading, features)
            case .waveLine: Self.drawWave(&context, size, source, shading, notch, features)
            case .bassGlow: Self.drawBassGlow(&context, size, source, shading, notch, features, colors)
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

    private static func drawEdgeBars(_ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [CGFloat],
                                     _ shading: GraphicsContext.Shading, _ features: MusicFeatures) {
        let step: CGFloat = 12
        let count = Int(size.width / step)
        for i in 0 ..< count {
            // Mirror so bass sits in the middle of the screen.
            let u = abs(CGFloat(i) / CGFloat(max(1, count - 1)) - 0.5) * 2
            let height = 1.5 + sample(levels, at: u) * 5 + features.melodyBoost(at: u) * 4
            ctx.fill(Path(roundedRect: CGRect(x: CGFloat(i) * step + 2, y: size.height - height,
                                              width: step - 4, height: height), cornerRadius: 1),
                     with: shading)
        }
    }

    private static func drawWave(_ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [CGFloat],
                                 _ shading: GraphicsContext.Shading, _ notch: NotchGap,
                                 _ features: MusicFeatures) {
        let baseline = size.height - 5
        let amplitude: CGFloat = 4
        let time = CGFloat(Date().timeIntervalSinceReferenceDate)
        var path = Path()
        let steps = Int(size.width / 4)
        for s in 0 ... steps {
            let x = CGFloat(s) / CGFloat(steps) * size.width
            let center = (notch.minX + notch.maxX) / 2
            let u = min(1, abs(x - center) / (size.width / 2))
            let level = sample(levels, at: u)
            let boost = features.melodyBoost(at: u)
            let y = baseline + sin(x / 18 - time * 3) * amplitude * (0.15 + level + 1.2 * boost)
            if s == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }

    private static func drawBassGlow(_ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [CGFloat],
                                     _ shading: GraphicsContext.Shading, _ notch: NotchGap,
                                     _ features: MusicFeatures, _ colors: [Color]) {
        // Two bright spots glide along the edge with the melody's pitch,
        // mirrored around the notch (higher notes further out).
        if features.melodyStrength > 0.05 {
            let center = (notch.minX + notch.maxX) / 2
            let offset = (notch.maxX - notch.minX) / 2 + 20 + features.melody * (size.width / 2 - 80)
            let tint = colors[colors.count / 2]
            for x in [center - offset, center + offset] {
                let radius: CGFloat = 40 + 50 * features.melodyStrength
                let point = CGPoint(x: x, y: size.height)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x - radius, y: size.height - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: tint.opacity(0.6 * Double(features.melodyStrength)), location: 0),
                            .init(color: .clear, location: 1),
                        ]),
                        center: point, startRadius: 0, endRadius: radius))
            }
        }

        let bass = sample(levels, at: 0.05)
        // Soft wash in the lower part of the bar, stronger on the beat.
        var wash = ctx
        wash.opacity = Double(bass) * 0.3
        wash.fill(Path(CGRect(x: 0, y: size.height * 0.5, width: size.width, height: size.height * 0.5)),
                  with: shading)

        var edge = ctx
        edge.opacity = 0.35 + Double(bass) * 0.65
        let thickness = 1.5 + bass * 2
        edge.fill(Path(CGRect(x: 0, y: size.height - thickness, width: size.width, height: thickness)), with: shading)
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

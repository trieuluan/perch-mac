//
//  MenuBarOverlayEffects.swift
//  Perch
//
//  Rhythm-aware menu bar effects (comets, pulse line, notch ripples), the
//  LED meter, the spectrum silhouette and the reworked bass glow. Shared state
//  lives in MenuBarOverlayState so hits and history survive between frames.
//

import SwiftUI

/// Per-frame state for the menu bar overlay.
final class MenuBarOverlayState {
    struct Comet {
        var born: Double
        var hit: DrumHit
        var direction: CGFloat // -1 left, 1 right
        var pitch: CGFloat // melody pitch at birth, for note comets
    }

    struct Ring {
        var born: Double
        var hit: DrumHit
    }

    private let detector = DrumHitDetector()
    private var lastTime: Double = 0
    private var spikeQueue: [CGFloat] = []

    /// Fast-attack, slow-release bass envelope.
    private(set) var pulse: CGFloat = 0
    private(set) var comets: [Comet] = []
    private(set) var rings: [Ring] = []
    /// Pulse-line samples, newest first (drawn from the notch outward).
    private(set) var history: [CGFloat] = Array(repeating: 0, count: 160)

    /// LED meter peak-hold, in rows, per column; falls one row at a time.
    var ledPeaks: [CGFloat] = []
    var ledPeakTime: Double = 0

    func update(levels: [CGFloat], features: MusicFeatures, time: Double) {
        let bass = levels.mean(0 ..< 3)
        pulse = max(bass, pulse * 0.88)

        for hit in detector.detect(levels: levels, time: time) {
            switch hit {
            case .kick:
                comets += [-1, 1].map { Comet(born: time, hit: hit, direction: $0, pitch: 0) }
                rings.append(Ring(born: time, hit: hit))
                spikeQueue = [0.35, 1, -0.55, 0.25, 0.05]
            case .snare:
                comets += [-1, 1].map { Comet(born: time, hit: hit, direction: $0, pitch: 0.5) }
                rings.append(Ring(born: time, hit: hit))
                if spikeQueue.isEmpty { spikeQueue = [0.25, 0.6, -0.3, 0.1] }
            case .hat:
                comets += [-1, 1].map { Comet(born: time, hit: hit, direction: $0, pitch: 1) }
            case .note:
                let side: CGFloat = Bool.random() ? -1 : 1
                comets.append(Comet(born: time, hit: hit, direction: side, pitch: features.melody))
                rings.append(Ring(born: time, hit: hit))
                if spikeQueue.isEmpty { spikeQueue = [0.15, 0.35, -0.15] }
            }
        }
        comets.removeAll { time - $0.born > MenuBarOverlayEffects.cometLife($0.hit) }
        rings.removeAll { time - $0.born > 1.3 }

        // Pulse line advances roughly every frame; spikes come from hits,
        // otherwise a small wobble that follows the overall loudness.
        if time - lastTime > 1.0 / 40.0 {
            lastTime = time
            let loudness = levels.mean(0 ..< levels.count)
            let next = spikeQueue.isEmpty
                ? CGFloat.random(in: -1 ... 1) * 0.08 * loudness
                : spikeQueue.removeFirst()
            history.insert(next, at: 0)
            history.removeLast()
        }
    }
}

enum MenuBarOverlayEffects {
    static func cometLife(_ hit: DrumHit) -> Double { [1.0, 0.85, 0.5, 0.9][hit.rawValue] }

    private static func sample(_ levels: [CGFloat], at position: CGFloat) -> CGFloat {
        guard levels.count > 1 else { return levels.first ?? 0 }
        let x = max(0, min(1, position)) * CGFloat(levels.count - 1)
        let i = Int(x)
        let t = x - CGFloat(i)
        return levels[i] * (1 - t) + levels[min(levels.count - 1, i + 1)] * t
    }

    /// Room from the notch edge to the screen edge, using the narrower side.
    private static func span(_ size: CGSize, _ notch: NotchGap) -> CGFloat {
        max(1, min(notch.minX, size.width - notch.maxX) - 4)
    }

    // MARK: - Bass glow: a soft light spreading from the notch on the beat

    static func drawBassGlow(_ ctx: inout GraphicsContext, _ size: CGSize, _ state: MenuBarOverlayState,
                             _ notch: NotchGap, _ features: MusicFeatures, _ colors: [Color]) {
        let pulse = state.pulse
        let reach = span(size, notch) * (0.35 + 0.65 * pulse)
        let core = colors.first ?? .white
        let tip = colors.last ?? core

        for direction in [-1.0, 1.0] as [CGFloat] {
            let start = direction < 0 ? notch.minX : notch.maxX
            let end = start + direction * reach
            let gradient = Gradient(stops: [
                .init(color: core, location: 0),
                .init(color: tip.opacity(0.6), location: 0.5),
                .init(color: tip.opacity(0), location: 1),
            ])
            let shading = GraphicsContext.Shading.linearGradient(
                gradient, startPoint: CGPoint(x: start, y: 0), endPoint: CGPoint(x: end, y: 0))
            let minX = min(start, end)

            // Soft halo rising from the bottom edge: a few stacked, fading bands
            // (much cheaper than a blur filter at 30fps).
            let haloHeight = 6 + 12 * pulse
            for band in 0 ..< 4 {
                let t = CGFloat(band + 1) / 4
                var halo = ctx
                halo.opacity = (0.45 + 0.55 * Double(pulse)) * 0.22
                halo.fill(Path(roundedRect: CGRect(x: minX, y: size.height - haloHeight * t, width: reach,
                                                   height: haloHeight * t), cornerRadius: haloHeight * t / 2),
                          with: shading)
            }

            // Crisp line along the bottom edge.
            var line = ctx
            line.opacity = 0.7 + 0.3 * Double(pulse)
            let thickness = 1.5 + 1.5 * pulse
            line.fill(Path(roundedRect: CGRect(x: minX, y: size.height - thickness, width: reach, height: thickness),
                           cornerRadius: thickness / 2), with: shading)
        }

        // Melody: two soft spots gliding along the edge at the lead note's pitch.
        if features.melodyStrength > 0.08 {
            let tint = VisualizerPalette.sample(colors, at: features.melody)
            let offset = features.melody * span(size, notch)
            for x in [notch.minX - 10 - offset, notch.maxX + 10 + offset] {
                var spot = ctx
                spot.opacity = Double(features.melodyStrength) * 0.9
                let center = CGPoint(x: x, y: size.height - 3)
                spot.fill(Path(ellipseIn: CGRect(x: x - 22, y: size.height - 14, width: 44, height: 22)),
                          with: .radialGradient(Gradient(colors: [tint, tint.opacity(0)]),
                                                center: center, startRadius: 0, endRadius: 22))
            }
        }
    }

    // MARK: - Spectrum silhouette: a smooth filled mountain range from the notch

    static func drawSilhouette(_ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [CGFloat],
                               _ notch: NotchGap, _ features: MusicFeatures, _ colors: [Color]) {
        let reach = span(size, notch)
        let steps = 40
        for direction in [-1.0, 1.0] as [CGFloat] {
            let start = direction < 0 ? notch.minX : notch.maxX
            var top: [CGPoint] = []
            for s in 0 ... steps {
                let u = CGFloat(s) / CGFloat(steps)
                let level = min(1, sample(levels, at: u) + 0.4 * features.melodyBoost(at: u))
                let height = size.height * 0.9 * level * (1 - u * 0.55)
                top.append(CGPoint(x: start + direction * u * reach, y: size.height - height))
            }
            var area = Path()
            area.move(to: CGPoint(x: start, y: size.height))
            appendSmooth(&area, top)
            area.addLine(to: CGPoint(x: start + direction * reach, y: size.height))
            area.closeSubpath()

            let horizontal = GraphicsContext.Shading.linearGradient(
                Gradient(colors: colors), startPoint: CGPoint(x: start, y: 0),
                endPoint: CGPoint(x: start + direction * reach, y: 0))
            var fill = ctx
            fill.opacity = 0.3
            fill.fill(area, with: horizontal)

            var outline = Path()
            outline.move(to: top[0])
            appendSmooth(&outline, top)
            var edge = ctx
            edge.opacity = 0.85
            edge.stroke(outline, with: horizontal, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - LED meter: retro dot columns lighting up row by row

    static func drawLEDMeter(_ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [CGFloat],
                             _ notch: NotchGap, _ features: MusicFeatures, _ colors: [Color],
                             _ state: MenuBarOverlayState, _ time: Double) {
        let dot: CGFloat = 3
        let gap: CGFloat = 1.6
        let step: CGFloat = 7
        // As many rows as fit in the full menu bar height.
        let rows = max(3, Int((size.height - 2 + gap) / (dot + gap)))
        let top = (size.height - (CGFloat(rows) * (dot + gap) - gap)) / 2
        let reach = span(size, notch)
        let columns = Int(reach / step)
        guard columns > 0 else { return }

        // Peak-hold LEDs fall back at a steady pace.
        if state.ledPeaks.count != columns { state.ledPeaks = Array(repeating: 0, count: columns) }
        let dt = state.ledPeakTime == 0 ? 0 : min(0.1, time - state.ledPeakTime)
        state.ledPeakTime = time

        // Collect dots into one path per row and state, then fill each once:
        // a few dozen fills per frame instead of thousands.
        var lit = [Path](repeating: Path(), count: rows)
        var peaks = [Path](repeating: Path(), count: rows)
        var off = Path()

        for c in 0 ..< columns {
            let u = CGFloat(c) / CGFloat(columns)
            let level = min(1, sample(levels, at: u) + 0.4 * features.melodyBoost(at: u))
            // sqrt lifts quieter bands so the meter uses its full height.
            let litRows = max(1, level.squareRoot() * CGFloat(rows) * (1 - u * 0.25))
            let litCount = Int(litRows.rounded(.down))
            state.ledPeaks[c] = max(litRows, state.ledPeaks[c] - CGFloat(dt) * CGFloat(rows) * 0.9)
            let peakRow = Int(state.ledPeaks[c].rounded(.down))

            for direction in [-1.0, 1.0] as [CGFloat] {
                let edge = direction < 0 ? notch.minX : notch.maxX
                let x = edge + direction * (6 + CGFloat(c) * step) - (direction < 0 ? dot : 0)
                for r in 0 ..< rows {
                    let rect = CGRect(x: x, y: top + CGFloat(rows - 1 - r) * (dot + gap), width: dot, height: dot)
                    // Plain squares: at 3pt a corner radius isn't visible and costs a lot.
                    if r < litCount {
                        lit[r].addRect(rect)
                    } else if r == peakRow {
                        peaks[r].addRect(rect)
                    } else {
                        off.addRect(rect)
                    }
                }
            }
        }

        var dim = ctx
        dim.opacity = 0.06
        dim.fill(off, with: .color(colors.first ?? .white))
        for r in 0 ..< rows {
            // Rows take colors bottom to top along the gradient, like a hi-fi meter.
            let color = VisualizerPalette.sample(colors, at: CGFloat(r) / CGFloat(max(1, rows - 1)))
            var on = ctx
            on.opacity = 0.85
            on.fill(lit[r], with: .color(color))
            var peak = ctx
            peak.opacity = 0.9
            peak.fill(peaks[r], with: .color(VisualizerPalette.lighten(color, amount: 0.5)))
        }
    }

    // MARK: - Beat comets: streaks shooting out of the notch on every hit

    static func drawComets(_ ctx: inout GraphicsContext, _ size: CGSize, _ state: MenuBarOverlayState,
                           _ notch: NotchGap, _ time: Double, _ colors: [Color]) {
        let reach = span(size, notch)
        for comet in state.comets {
            let life = cometLife(comet.hit)
            let t = CGFloat(min(1, (time - comet.born) / life))
            let eased = 1 - pow(1 - t, 2.2) // fast start, gliding finish
            let distance: CGFloat = [1.0, 0.75, 0.4, 0.6][comet.hit.rawValue] * reach * eased
            let start = comet.direction < 0 ? notch.minX : notch.maxX
            let head = CGPoint(x: start + comet.direction * (8 + distance),
                               y: size.height * [0.82, 0.62, 0.42, 0.55][comet.hit.rawValue])
            let radius: CGFloat = [2.6, 2, 1.3, 1.8][comet.hit.rawValue]
            let tail = (40 + 60 * (1 - t)) * [1, 0.8, 0.4, 0.7][comet.hit.rawValue]
            let color = comet.hit == .note
                ? VisualizerPalette.sample(colors, at: comet.pitch)
                : VisualizerPalette.sample(colors, at: CGFloat(comet.hit.rawValue) / 2)
            let fade = Double(1 - t)

            var trail = Path()
            trail.move(to: CGPoint(x: head.x - comet.direction * tail, y: head.y))
            trail.addLine(to: head)
            var streak = ctx
            streak.opacity = fade * 0.8
            streak.stroke(trail, with: .linearGradient(
                Gradient(colors: [color.opacity(0), color]),
                startPoint: CGPoint(x: head.x - comet.direction * tail, y: head.y), endPoint: head),
                style: StrokeStyle(lineWidth: radius * 1.2, lineCap: .round))

            var glow = ctx
            glow.opacity = fade
            glow.fill(Path(ellipseIn: CGRect(x: head.x - radius * 3, y: head.y - radius * 3,
                                             width: radius * 6, height: radius * 6)),
                      with: .radialGradient(Gradient(colors: [color, color.opacity(0)]),
                                            center: head, startRadius: 0, endRadius: radius * 3))
            var dotLayer = ctx
            dotLayer.opacity = fade
            dotLayer.fill(Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius,
                                                 width: radius * 2, height: radius * 2)),
                          with: .color(VisualizerPalette.lighten(color, amount: 0.5)))
        }
    }

    // MARK: - Pulse line: a heartbeat trace scrolling out from the notch

    static func drawPulseLine(_ ctx: inout GraphicsContext, _ size: CGSize, _ state: MenuBarOverlayState,
                              _ notch: NotchGap, _ colors: [Color]) {
        let reach = span(size, notch)
        let history = state.history
        let spacing = reach / CGFloat(history.count - 1)
        let baseline = size.height - 7
        let amplitude = size.height * 0.42

        for direction in [-1.0, 1.0] as [CGFloat] {
            let start = direction < 0 ? notch.minX : notch.maxX
            var path = Path()
            for (i, value) in history.enumerated() {
                let fade = 1 - CGFloat(i) / CGFloat(history.count)
                let point = CGPoint(x: start + direction * CGFloat(i) * spacing,
                                    y: baseline - value * amplitude * fade)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: colors + [colors.last?.opacity(0) ?? .clear]),
                startPoint: CGPoint(x: start, y: 0), endPoint: CGPoint(x: start + direction * reach, y: 0))

            var glow = ctx
            glow.opacity = 0.18
            glow.stroke(path, with: shading, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - Notch ripples: arcs spreading out from under the notch

    static func drawNotchRipples(_ ctx: inout GraphicsContext, _ size: CGSize, _ state: MenuBarOverlayState,
                                 _ notch: NotchGap, _ time: Double, _ colors: [Color]) {
        let center = CGPoint(x: (notch.minX + notch.maxX) / 2, y: 0)
        let startRadius = max(20, (notch.maxX - notch.minX) / 2)
        let reach = span(size, notch) * 0.9

        for ring in state.rings {
            let t = CGFloat(min(1, (time - ring.born) / 1.3))
            let eased = 1 - pow(1 - t, 2)
            let radius = startRadius + eased * reach
            let height = size.height * (1.1 + 0.6 * eased)
            let width: CGFloat = [3, 2, 1, 1.6][ring.hit.rawValue] * (1 - t * 0.5)
            let color = VisualizerPalette.sample(colors, at: CGFloat(ring.hit.rawValue) / 3)

            var arc = ctx
            arc.opacity = Double(1 - t) * 0.85
            arc.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - height,
                                              width: radius * 2, height: height * 2)),
                       with: .color(color), lineWidth: width)
        }
    }

    // MARK: - 3D helix: two strands twisting out of the notch

    static func drawHelix(_ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [CGFloat],
                          _ notch: NotchGap, _ time: Double, _ colors: [Color]) {
        let reach = span(size, notch)
        let mid = size.height / 2
        let points = 120
        // Segments are grouped into a few depth layers and each layer is drawn
        // with one stroke, back to front.
        let layers = 6

        for direction in [-1.0, 1.0] as [CGFloat] {
            let start = direction < 0 ? notch.minX : notch.maxX
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: colors), startPoint: CGPoint(x: start, y: 0),
                endPoint: CGPoint(x: start + direction * reach, y: 0))

            var paths = [Path](repeating: Path(), count: layers)
            var rungs = Path()
            var previous: [(CGPoint, CGFloat)] = []

            for p in 0 ..< points {
                let u = CGFloat(p) / CGFloat(points - 1)
                let x = start + direction * (6 + u * (reach - 6))
                // The twist travels outward from the notch.
                let phase = u * 16 - CGFloat(time) * 2.4
                let level = sample(levels, at: u)
                let amplitude = size.height * 0.38 * (0.4 + 0.6 * level) * (1 - u * 0.3)

                var current: [(CGPoint, CGFloat)] = []
                for strand in 0 ..< 2 {
                    let angle = phase + CGFloat(strand) * .pi
                    current.append((CGPoint(x: x, y: mid + sin(angle) * amplitude), (cos(angle) + 1) / 2))
                }
                if p % 6 == 0 {
                    rungs.move(to: current[0].0)
                    rungs.addLine(to: current[1].0)
                }
                if !previous.isEmpty {
                    for strand in 0 ..< 2 {
                        let depth = (previous[strand].1 + current[strand].1) / 2
                        let layer = min(layers - 1, Int(depth * CGFloat(layers)))
                        paths[layer].move(to: previous[strand].0)
                        paths[layer].addLine(to: current[strand].0)
                    }
                }
                previous = current
            }

            var rungLayer = ctx
            rungLayer.opacity = 0.15
            rungLayer.stroke(rungs, with: shading, lineWidth: 0.8)

            for layer in 0 ..< layers {
                let depth = (CGFloat(layer) + 0.5) / CGFloat(layers)
                var stroke = ctx
                stroke.opacity = 0.2 + 0.8 * Double(depth)
                stroke.stroke(paths[layer], with: shading,
                              style: StrokeStyle(lineWidth: 0.6 + 1.8 * depth, lineCap: .round))
                // Front-most layers get a light highlight.
                if layer >= layers - 2 {
                    var shine = ctx
                    shine.opacity = 0.25
                    shine.stroke(paths[layer], with: .color(.white),
                                 style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
                }
            }
        }
    }

    // MARK: - 3D blocks: little extruded bars with lit tops and shaded sides

    static func drawBlocks3D(_ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [CGFloat],
                             _ notch: NotchGap, _ features: MusicFeatures, _ colors: [Color]) {
        let reach = span(size, notch)
        let step: CGFloat = 11
        let width: CGFloat = 6
        let depthX: CGFloat = 3 // extrusion toward the screen edge
        let depthY: CGFloat = 2.5
        let columns = Int(reach / step)
        guard columns > 0 else { return }
        let floor = size.height - 2

        for direction in [-1.0, 1.0] as [CGFloat] {
            let edge = direction < 0 ? notch.minX : notch.maxX
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: colors + [(colors.last ?? .white).opacity(0.5)]),
                startPoint: CGPoint(x: edge, y: 0), endPoint: CGPoint(x: edge + direction * reach, y: 0))

            // All faces of one kind go into a single path, filled once.
            var fronts = Path()
            var sides = Path()
            var tops = Path()

            for c in 0 ..< columns {
                let u = CGFloat(c) / CGFloat(columns)
                let level = min(1, sample(levels, at: u) + 0.4 * features.melodyBoost(at: u))
                let height = max(2, (size.height - 6) * level * (1 - u * 0.3))
                let left = direction < 0
                    ? edge - 6 - CGFloat(c + 1) * step + (step - width)
                    : edge + 6 + CGFloat(c) * step
                // Extrude away from the notch so both sides look symmetric.
                let dx = direction * depthX
                let front = CGRect(x: left, y: floor - height, width: width, height: height)
                fronts.addRect(front)

                tops.move(to: CGPoint(x: front.minX, y: front.minY))
                tops.addLine(to: CGPoint(x: front.maxX, y: front.minY))
                tops.addLine(to: CGPoint(x: front.maxX + dx, y: front.minY - depthY))
                tops.addLine(to: CGPoint(x: front.minX + dx, y: front.minY - depthY))
                tops.closeSubpath()

                let sideX = direction > 0 ? front.maxX : front.minX
                sides.move(to: CGPoint(x: sideX, y: front.minY))
                sides.addLine(to: CGPoint(x: sideX + dx, y: front.minY - depthY))
                sides.addLine(to: CGPoint(x: sideX + dx, y: front.maxY - depthY))
                sides.addLine(to: CGPoint(x: sideX, y: front.maxY))
                sides.closeSubpath()
            }

            var sideLayer = ctx
            sideLayer.opacity = 0.4
            sideLayer.fill(sides, with: shading)
            var frontLayer = ctx
            frontLayer.opacity = 0.75
            frontLayer.fill(fronts, with: shading)
            ctx.fill(tops, with: shading)
            var shine = ctx
            shine.opacity = 0.4
            shine.fill(tops, with: .color(.white))
        }
    }

    // MARK: - Helpers

    /// Smooth curve through `points` (quadratic segments between midpoints),
    /// continuing from the path's current point.
    private static func appendSmooth(_ path: inout Path, _ points: [CGPoint]) {
        guard let first = points.first else { return }
        path.addLine(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return
        }
        for i in 1 ..< points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
    }
}

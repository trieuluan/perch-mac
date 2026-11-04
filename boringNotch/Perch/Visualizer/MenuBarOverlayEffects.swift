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

            // Blurred halo rising from the bottom edge.
            var halo = ctx
            halo.addFilter(.blur(radius: 7))
            halo.opacity = 0.45 + 0.55 * Double(pulse)
            let haloHeight = 6 + 12 * pulse
            halo.fill(Path(roundedRect: CGRect(x: minX, y: size.height - haloHeight, width: reach, height: haloHeight * 1.4),
                           cornerRadius: haloHeight / 2), with: shading)

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
                spot.addFilter(.blur(radius: 6))
                spot.opacity = Double(features.melodyStrength) * 0.9
                spot.fill(Path(ellipseIn: CGRect(x: x - 18, y: size.height - 9, width: 36, height: 12)), with: .color(tint))
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

        for c in 0 ..< columns {
            let u = CGFloat(c) / CGFloat(columns)
            let level = min(1, sample(levels, at: u) + 0.4 * features.melodyBoost(at: u))
            // sqrt lifts quieter bands so the meter uses its full height.
            let litRows = max(1, level.squareRoot() * CGFloat(rows) * (1 - u * 0.25))
            let lit = Int(litRows.rounded(.down))
            state.ledPeaks[c] = max(litRows, state.ledPeaks[c] - CGFloat(dt) * CGFloat(rows) * 0.9)
            let peakRow = Int(state.ledPeaks[c].rounded(.down))

            for direction in [-1.0, 1.0] as [CGFloat] {
                let edge = direction < 0 ? notch.minX : notch.maxX
                let x = edge + direction * (6 + CGFloat(c) * step) - (direction < 0 ? dot : 0)
                for r in 0 ..< rows {
                    let y = top + CGFloat(rows - 1 - r) * (dot + gap)
                    // Rows take colors bottom to top along the gradient, like a hi-fi meter.
                    let color = VisualizerPalette.sample(colors, at: CGFloat(r) / CGFloat(max(1, rows - 1)))
                    let on = r < lit
                    let isPeak = r == peakRow && peakRow >= lit
                    var led = ctx
                    led.opacity = on ? 0.85 : (isPeak ? 0.9 : 0.06)
                    led.fill(Path(roundedRect: CGRect(x: x, y: y, width: dot, height: dot), cornerRadius: 0.8),
                             with: .color(isPeak ? VisualizerPalette.lighten(color, amount: 0.5) : color))
                }
            }
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
            glow.addFilter(.blur(radius: 3))
            glow.opacity = fade
            glow.fill(Path(ellipseIn: CGRect(x: head.x - radius * 2, y: head.y - radius * 2,
                                             width: radius * 4, height: radius * 4)), with: .color(color))
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
            glow.addFilter(.blur(radius: 3))
            glow.opacity = 0.6
            glow.stroke(path, with: shading, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
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

        for direction in [-1.0, 1.0] as [CGFloat] {
            let start = direction < 0 ? notch.minX : notch.maxX
            // Precompute both strands so they can be drawn as continuous ribbons.
            var strands: [[(point: CGPoint, depth: CGFloat, u: CGFloat)]] = [[], []]
            for p in 0 ..< points {
                let u = CGFloat(p) / CGFloat(points - 1)
                let x = start + direction * (6 + u * (reach - 6))
                // The twist travels outward from the notch.
                let phase = u * 16 - CGFloat(time) * 2.4
                let level = sample(levels, at: u)
                let amplitude = size.height * 0.38 * (0.4 + 0.6 * level) * (1 - u * 0.3)
                for strand in 0 ..< 2 {
                    let angle = phase + CGFloat(strand) * .pi
                    strands[strand].append((CGPoint(x: x, y: mid + sin(angle) * amplitude), (cos(angle) + 1) / 2, u))
                }
                // Faint rungs between the strands.
                if p % 6 == 0 {
                    var rung = Path()
                    rung.move(to: strands[0][p].point)
                    rung.addLine(to: strands[1][p].point)
                    var layer = ctx
                    layer.opacity = 0.15
                    layer.stroke(rung, with: .color(VisualizerPalette.sample(colors, at: u)), lineWidth: 0.8)
                }
            }

            // Back segments first, then front, so the strand in front overlaps.
            var segments: [(from: CGPoint, to: CGPoint, depth: CGFloat, u: CGFloat)] = []
            for strand in strands {
                for k in 1 ..< strand.count {
                    let depth = (strand[k - 1].depth + strand[k].depth) / 2
                    segments.append((strand[k - 1].point, strand[k].point, depth, strand[k].u))
                }
            }
            for segment in segments.sorted(by: { $0.depth < $1.depth }) {
                var path = Path()
                path.move(to: segment.from)
                path.addLine(to: segment.to)
                let color = VisualizerPalette.sample(colors, at: segment.u)
                var layer = ctx
                layer.opacity = 0.2 + 0.8 * Double(segment.depth)
                layer.stroke(path,
                             with: .color(segment.depth > 0.6 ? VisualizerPalette.lighten(color, amount: 0.3) : color),
                             style: StrokeStyle(lineWidth: 0.6 + 1.8 * segment.depth, lineCap: .round))
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

        for c in 0 ..< columns {
            let u = CGFloat(c) / CGFloat(columns)
            let level = min(1, sample(levels, at: u) + 0.4 * features.melodyBoost(at: u))
            let height = max(2, (size.height - 6) * level * (1 - u * 0.3))
            let color = VisualizerPalette.sample(colors, at: u)
            let fade = Double(1 - u * 0.5)

            for direction in [-1.0, 1.0] as [CGFloat] {
                let edge = direction < 0 ? notch.minX : notch.maxX
                let left = direction < 0
                    ? edge - 6 - CGFloat(c + 1) * step + (step - width)
                    : edge + 6 + CGFloat(c) * step
                // Extrude away from the notch so both sides look symmetric.
                let dx = direction * depthX
                let front = CGRect(x: left, y: floor - height, width: width, height: height)

                var top = Path()
                top.move(to: CGPoint(x: front.minX, y: front.minY))
                top.addLine(to: CGPoint(x: front.maxX, y: front.minY))
                top.addLine(to: CGPoint(x: front.maxX + dx, y: front.minY - depthY))
                top.addLine(to: CGPoint(x: front.minX + dx, y: front.minY - depthY))
                top.closeSubpath()

                let sideX = direction > 0 ? front.maxX : front.minX
                var side = Path()
                side.move(to: CGPoint(x: sideX, y: front.minY))
                side.addLine(to: CGPoint(x: sideX + dx, y: front.minY - depthY))
                side.addLine(to: CGPoint(x: sideX + dx, y: front.maxY - depthY))
                side.addLine(to: CGPoint(x: sideX, y: front.maxY))
                side.closeSubpath()

                var layer = ctx
                layer.opacity = fade
                layer.fill(side, with: .color(color.opacity(0.45)))
                layer.fill(Path(front), with: .linearGradient(
                    Gradient(colors: [color.opacity(0.85), color.opacity(0.35)]),
                    startPoint: CGPoint(x: front.midX, y: front.minY),
                    endPoint: CGPoint(x: front.midX, y: front.maxY)))
                layer.fill(top, with: .color(VisualizerPalette.lighten(color, amount: 0.45)))
            }
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

//
//  PlayerBackgroundView.swift
//  Perch
//
//  Animated backgrounds behind the open-notch music player. Every style is
//  drawn with Canvas at up to 30fps and reacts to VisualizerEngine levels.
//

import SwiftUI

/// Mutable animation state kept outside SwiftUI diffing.
private final class BackgroundState {
    typealias Hit = DrumHit

    /// `melody` is the lead-note pitch when the ripple was born; snare and
    /// hi-hat rings start from that spot on the player instead of the art.
    struct Ripple { var born: Double; var hit: Hit; var melody: CGFloat }
    struct Star { var x: CGFloat; var y: CGFloat; var z: CGFloat }

    var ripples: [Ripple] = []
    private let detector = DrumHitDetector()
    /// Fast-attack, slow-release envelope for the pulse glow.
    var pulse: CGFloat = 0
    var stars: [Star] = (0 ..< 90).map { _ in
        Star(x: .random(in: -1 ... 1), y: .random(in: -1 ... 1), z: .random(in: 0.1 ... 1))
    }
    var lastTime: Double = 0

    /// Spectrum bars: current heights plus peak caps that hold briefly, then fall.
    var bars: [CGFloat] = []
    var peaks: [CGFloat] = []
    private var peakHeld: [Double] = []
    private var lastPeakTime: Double = 0

    func updateBars(_ heights: [CGFloat], time: Double) {
        if peaks.count != heights.count {
            peaks = heights
            peakHeld = Array(repeating: time, count: heights.count)
        }
        let dt = lastPeakTime == 0 ? 0 : min(0.1, time - lastPeakTime)
        lastPeakTime = time
        for i in heights.indices {
            if heights[i] >= peaks[i] {
                peaks[i] = heights[i]
                peakHeld[i] = time
            } else if time - peakHeld[i] > 0.18 {
                // Fall at a steady, slow speed after a short hold.
                peaks[i] = max(heights[i], peaks[i] - CGFloat(dt) * 0.55)
            }
        }
        bars = heights
    }

    func detectHits(levels: [CGFloat], time: Double, melody: CGFloat) {
        for hit in detector.detect(levels: levels, time: time) {
            ripples.append(Ripple(born: time, hit: hit, melody: melody))
        }
        ripples.removeAll { time - $0.born > $0.hit.lifetime }
    }

    func updatePulse(bass: CGFloat) {
        pulse = max(bass, pulse * 0.9)
    }

    func advanceStars(bass: CGFloat, time: Double) {
        let dt = lastTime == 0 ? 0 : min(0.1, time - lastTime)
        lastTime = time
        for i in stars.indices {
            stars[i].z -= CGFloat(dt) * (0.15 + 0.9 * bass)
            // Respawn far away before a star gets so close it would fly off as a huge line.
            if stars[i].z <= 0.18 {
                stars[i] = Star(x: .random(in: -1 ... 1), y: .random(in: -1 ... 1), z: .random(in: 0.85 ... 1))
            }
        }
    }
}

private extension DrumHit {
    /// How long a ripple of this kind lives.
    var lifetime: Double { [1.4, 1.0, 0.6, 1.1][rawValue] }
}

struct PlayerBackgroundView: View {
    let style: PlayerBackgroundStyle
    var isActive: Bool
    var colors: [Color]
    /// How far the canvas extends past the player on each side, so the album
    /// art center can still be located.
    var bleed = EdgeInsets()

    @ObservedObject private var engine = VisualizerEngine.shared
    @State private var state = BackgroundState()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let levels = engine.levels(24)
            let bass = (levels.prefix(3).reduce(0, +)) / 3
            let features = engine.features
            let snapshot = prepare(levels: levels, bass: bass, time: time, features: features)

            Canvas { context, size in
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
                // The album art sits at the left of the player; effects radiate from its center.
                let playerHeight = size.height - bleed.top - bleed.bottom
                let origin = CGPoint(x: bleed.leading + playerHeight / 2, y: bleed.top + playerHeight / 2)

                switch style {
                case .none, .particles: break
                case .aurora: Self.drawAurora(&context, size, levels, bass, time, shading, features)
                case .bars: Self.drawBars(&context, size, snapshot.bars, snapshot.peaks, colors, bleed)
                case .ripples: Self.drawRipples(&context, size, snapshot.ripples, time, origin, playerHeight, colors)
                case .silk: Self.drawSilk(&context, size, levels, time, shading, features)
                case .warp: Self.drawWarp(&context, size, snapshot.stars, bass, colors, features, bleed)
                case .pulse: Self.drawPulse(&context, size, snapshot.pulse, origin, playerHeight, colors, features)
                }
            }
        }
        .runsVisualizerEngine(isActive)
        .allowsHitTesting(false)
    }

    private func prepare(levels: [CGFloat], bass: CGFloat, time: Double, features: MusicFeatures)
        -> (ripples: [BackgroundState.Ripple], stars: [BackgroundState.Star], pulse: CGFloat,
            bars: [CGFloat], peaks: [CGFloat]) {
        switch style {
        case .bars:
            state.updateBars(Self.barHeights(levels, features), time: time)
        case .ripples:
            state.detectHits(levels: levels, time: time, melody: features.melody)
        case .warp:
            state.advanceStars(bass: bass, time: time)
        case .pulse:
            state.updatePulse(bass: bass)
        default:
            break
        }
        return (state.ripples, state.stars, state.pulse, state.bars, state.peaks)
    }

    private static func sample(_ levels: [CGFloat], at position: CGFloat) -> CGFloat {
        guard levels.count > 1 else { return levels.first ?? 0 }
        let x = max(0, min(1, position)) * CGFloat(levels.count - 1)
        let i = Int(x)
        let t = x - CGFloat(i)
        return levels[i] * (1 - t) + levels[min(levels.count - 1, i + 1)] * t
    }

    // MARK: - Aurora: soft, blurred curtains of light swaying with the music

    private static func drawAurora(_ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [CGFloat],
                                   _ bass: CGFloat, _ time: Double, _ shading: GraphicsContext.Shading,
                                   _ features: MusicFeatures) {
        // Coarse, smooth version of the spectrum so the curtains bend gently
        // instead of jittering with every band.
        let coarse = (0 ..< 6).map { sample(levels, at: CGFloat($0) / 5) }

        for band in 0 ..< 3 {
            let k = CGFloat(band)
            var top: [CGPoint] = []
            var bottom: [CGPoint] = []
            var center: [CGPoint] = []
            let steps = 32
            for s in 0 ... steps {
                let u = CGFloat(s) / CGFloat(steps)
                let x = u * size.width
                let distance = abs(u - 0.5) * 2
                let level = sample(coarse, at: distance)
                // The curtains swell where the lead melody sits (low notes in the middle).
                let boost = features.melodyBoost(at: distance, width: 0.2)
                let wave = sin(u * .pi * 2 * 1.1 + CGFloat(time) * 0.35 * (k + 1) + k * 1.7)
                let y = size.height * (0.45 + 0.14 * k) + wave * size.height * 0.1 * (0.5 + level + boost)
                let thickness = size.height * (0.1 + 0.16 * level + 0.05 * bass + 0.14 * boost)
                top.append(CGPoint(x: x, y: y - thickness * 0.65))
                bottom.append(CGPoint(x: x, y: y + thickness * 0.35))
                center.append(CGPoint(x: x, y: y))
            }

            var curtain = Path()
            appendSmooth(&curtain, top, startNew: true)
            appendSmooth(&curtain, bottom.reversed(), startNew: false)
            curtain.closeSubpath()

            // Soft body.
            var glow = ctx
            glow.addFilter(.blur(radius: 16 - k * 3))
            glow.opacity = 0.5 - Double(k) * 0.1
            glow.fill(curtain, with: shading)

            // Brighter edge along the middle of the curtain.
            var edge = ctx
            edge.addFilter(.blur(radius: 2.5))
            edge.opacity = 0.25 + 0.35 * Double(min(1, bass + features.melodyStrength * 0.5))
            var line = Path()
            appendSmooth(&line, center, startNew: true)
            edge.stroke(line, with: shading, lineWidth: 1.4)
        }
    }

    /// Appends a smooth curve through `points` (quadratic segments between
    /// midpoints). With `startNew` false it continues from the current point
    /// with a straight line to the first point, so two curves can form one shape.
    private static func appendSmooth(_ path: inout Path, _ points: [CGPoint], startNew: Bool) {
        guard let first = points.first else { return }
        if startNew { path.move(to: first) } else { path.addLine(to: first) }
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

    // MARK: - Bars: thin bars fading upward, with slowly falling peak caps

    static let barCount = 28

    /// Bar heights 0...1, bass in the middle, lifted where the melody is.
    private static func barHeights(_ levels: [CGFloat], _ features: MusicFeatures) -> [CGFloat] {
        (0 ..< barCount).map { i in
            let u = abs(CGFloat(i) / CGFloat(barCount - 1) - 0.5) * 2
            return min(1, sample(levels, at: u) + 0.35 * features.melodyBoost(at: u))
        }
    }

    private static func drawBars(_ ctx: inout GraphicsContext, _ size: CGSize, _ bars: [CGFloat],
                                 _ peaks: [CGFloat], _ colors: [Color], _ bleed: EdgeInsets) {
        guard !bars.isEmpty else { return }
        // Lay the bars out over the visible player, not the whole bleed area.
        let left = bleed.leading - 10
        let width = max(1, size.width - bleed.leading - bleed.trailing + 20)
        let bottom = size.height - bleed.bottom + 10
        let maxHeight = bottom - (bleed.top - 6)
        let step = width / CGFloat(bars.count)
        let barWidth = max(2, step * 0.55)

        for (i, level) in bars.enumerated() {
            let x = left + CGFloat(i) * step + (step - barWidth) / 2
            let color = VisualizerPalette.sample(colors, at: CGFloat(i) / CGFloat(bars.count - 1))
            let height = max(3, level * maxHeight)
            let rect = CGRect(x: x, y: bottom - height, width: barWidth, height: height)

            // Strong at the bottom, fading out toward the top so tall bars dissolve
            // instead of being cut off.
            ctx.fill(
                Path(roundedRect: rect, cornerRadius: min(barWidth / 2, 3)),
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.75), color.opacity(0.03)]),
                    startPoint: CGPoint(x: rect.midX, y: bottom),
                    endPoint: CGPoint(x: rect.midX, y: bottom - maxHeight)))

            // Peak cap: lighter, thin, hovering at the recent maximum.
            if i < peaks.count, peaks[i] > 0.04 {
                let capY = bottom - peaks[i] * maxHeight - 4
                var cap = ctx
                cap.opacity = 0.35 + 0.6 * Double(1 - peaks[i] * 0.5)
                cap.fill(
                    Path(roundedRect: CGRect(x: x, y: capY, width: barWidth, height: 2.5), cornerRadius: 1.25),
                    with: .color(VisualizerPalette.lighten(color, amount: 0.45)))
            }
        }
    }

    // MARK: - Ripples: rings pushed out from the album art on drum hits
    //
    // Kick: thick, slow, wide ring in the first gradient color.
    // Snare: medium ring in the middle color.
    // Hi-hat: thin, quick, small ring in the last color.
    // Note attack (any instrument): medium ring from the melody spot, colored by pitch.

    private static func drawRipples(_ ctx: inout GraphicsContext, _ size: CGSize, _ ripples: [BackgroundState.Ripple],
                                    _ time: Double, _ origin: CGPoint, _ playerHeight: CGFloat,
                                    _ colors: [Color]) {
        for ripple in ripples {
            let hit = ripple.hit
            let age = CGFloat(time - ripple.born)
            let life = CGFloat(hit.lifetime)
            let progress = min(1, age / life)
            let reach: CGFloat = [0.95, 0.65, 0.35, 0.5][hit.rawValue] * size.width
            let startRadius = hit == .note ? playerHeight * 0.15 : size.height * 0.4
            let radius = startRadius + progress * reach
            let width: CGFloat = [4, 2.2, 1.2, 1.8][hit.rawValue] * (1 - progress * 0.6)
            let color = hit == .note
                ? VisualizerPalette.sample(colors, at: ripple.melody)
                : colors[max(0, min(colors.count - 1, [0, colors.count / 2, colors.count - 1][hit.rawValue]))]

            // Kicks come from the album art; everything else from the spot on the
            // player matching the melody's pitch (higher notes further right).
            let center = hit == .kick
                ? origin
                : CGPoint(x: origin.x + playerHeight * 0.7 + ripple.melody * 360, y: origin.y)

            var layer = ctx
            layer.opacity = Double(1 - progress) * [0.85, 0.7, 0.6, 0.65][hit.rawValue]
            layer.stroke(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(color), lineWidth: width)
        }
    }

    // MARK: - Silk: a few thin lines rippling across the player

    private static func drawSilk(_ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [CGFloat],
                                 _ time: Double, _ shading: GraphicsContext.Shading, _ features: MusicFeatures) {
        for line in 0 ..< 5 {
            let k = CGFloat(line)
            var path = Path()
            let steps = 80
            for s in 0 ... steps {
                let u = CGFloat(s) / CGFloat(steps)
                let distance = abs(u - 0.5) * 2
                let level = sample(levels, at: distance)
                // The lines ripple hardest where the melody is.
                let boost = features.melodyBoost(at: distance)
                let y = size.height * 0.55
                    + sin(u * .pi * 2 * (1.5 + k * 0.25) - CGFloat(time) * (1.2 + k * 0.3) + k)
                    * size.height * 0.22 * (0.25 + level + 0.8 * boost)
                let point = CGPoint(x: u * size.width, y: y)
                if s == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            var layer = ctx
            layer.opacity = 0.55 - Double(k) * 0.08
            layer.stroke(path, with: shading, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - Warp: stars streaking out of a vanishing point, faster on the bass

    private static func drawWarp(_ ctx: inout GraphicsContext, _ size: CGSize, _ stars: [BackgroundState.Star],
                                 _ bass: CGFloat, _ colors: [Color], _ features: MusicFeatures,
                                 _ bleed: EdgeInsets) {
        // Work in the visible player area, not the whole bleed canvas.
        let visible = CGRect(
            x: bleed.leading, y: bleed.top,
            width: max(1, size.width - bleed.leading - bleed.trailing),
            height: max(1, size.height - bleed.top - bleed.bottom)
        )
        // The vanishing point is fixed at the horizontal center of the open notch
        // (the player starts ~13pt inside its left edge). Moving it, even slightly,
        // makes every streak jump at once, so it stays put.
        let notchLeft = visible.minX - 13
        let center = CGPoint(x: notchLeft + openNotchSize.width / 2, y: visible.midY)
        let focal = CGSize(width: visible.width * 0.12, height: visible.height * 0.18)
        let streak = 0.03 + bass * 0.07
        let maxLength: CGFloat = 28 + 40 * bass

        func project(_ star: BackgroundState.Star, z: CGFloat) -> CGPoint {
            CGPoint(x: center.x + star.x / z * focal.width, y: center.y + star.y / z * focal.height)
        }

        for (i, star) in stars.enumerated() {
            let head = project(star, z: star.z)
            var tail = project(star, z: min(1, star.z + streak))
            // Cap the streak so near stars don't become long lines across the text.
            let dx = head.x - tail.x
            let dy = head.y - tail.y
            let length = (dx * dx + dy * dy).squareRoot()
            if length > maxLength {
                tail = CGPoint(x: head.x - dx / length * maxLength, y: head.y - dy / length * maxLength)
            }

            var path = Path()
            path.move(to: tail)
            path.addLine(to: head)
            // Fade in from the distance, fade out right before respawning.
            let nearness = 1 - star.z
            let fadeOut = min(1, (star.z - 0.18) / 0.15)
            var layer = ctx
            layer.opacity = Double(min(0.75, nearness * 1.1) * max(0, fadeOut))
            layer.stroke(path, with: .color(colors[i % colors.count]),
                         style: StrokeStyle(lineWidth: 0.6 + nearness * 1.4, lineCap: .round))
        }
    }

    // MARK: - Pulse: a soft glow behind the album art breathing with the beat

    private static func drawPulse(_ ctx: inout GraphicsContext, _ size: CGSize, _ pulse: CGFloat,
                                  _ origin: CGPoint, _ playerHeight: CGFloat, _ colors: [Color],
                                  _ features: MusicFeatures) {
        // A second, smaller glow floats along the player with the melody's pitch.
        if features.melodyStrength > 0.05 {
            let point = CGPoint(x: origin.x + playerHeight * 0.7 + features.melody * 360, y: origin.y)
            let radius = playerHeight * (0.5 + 0.6 * features.melodyStrength)
            let tint = colors[colors.count / 2]
            ctx.fill(
                Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: tint.opacity(0.45 * Double(features.melodyStrength)), location: 0),
                        .init(color: .clear, location: 1),
                    ]),
                    center: point, startRadius: 0, endRadius: radius))
        }

        let level = Double(pulse)
        let inner = colors.first ?? .white
        let outer = colors.last ?? inner

        // Wide ambient wash across the whole player.
        let wideRadius = size.width * (0.55 + 0.35 * pulse)
        ctx.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: outer.opacity(0.18 + 0.35 * level), location: 0),
                    .init(color: .clear, location: 1),
                ]),
                center: origin, startRadius: 0, endRadius: wideRadius))

        // Bright core right behind the album art.
        let coreRadius = size.height * (0.75 + 1.1 * pulse)
        ctx.fill(
            Path(ellipseIn: CGRect(x: origin.x - coreRadius, y: origin.y - coreRadius,
                                   width: coreRadius * 2, height: coreRadius * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: inner.opacity(0.45 + 0.55 * level), location: 0),
                    .init(color: inner.opacity(0.2 + 0.3 * level), location: 0.45),
                    .init(color: .clear, location: 1),
                ]),
                center: origin, startRadius: 0, endRadius: coreRadius))
    }
}

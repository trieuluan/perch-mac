//
//  FloatingParticlesView.swift
//  Perch
//
//  Glowing dust drifting upward with depth, tuned to the music:
//  - each particle listens to one frequency band, so it brightens and swells
//    when its part of the melody is playing (and takes that band's color)
//  - the bass sets how fast the field rises
//  - kick drums give everything a small upward push
//  - snares throw a burst of sparks from the spot matching the melody's pitch
//  - hi-hats make random particles twinkle
//  - note attacks from any instrument light up particles around their pitch
//  - particles near the lead melody's pitch glow brighter (low notes in the
//    middle, high notes toward the edges)
//  - quiet passages dim the whole field
//

import Defaults
import SwiftUI

private struct Particle {
    var x: CGFloat // -1...1
    var y: CGFloat // -1.3...1.3, negative is up
    var z: CGFloat // 0.5...3.5, bigger is further away
    var phase: CGFloat
    var band: Int // 0...23, which frequency band it follows
    var lift: CGFloat = 0 // extra upward speed from kicks, decays
    var twinkle: CGFloat = 0 // flash from hi-hats, decays
}

/// Short-lived spark thrown out of the album art on a snare hit.
private struct Spark {
    var x: CGFloat // canvas points relative to the art center
    var y: CGFloat
    var vx: CGFloat // points per second
    var vy: CGFloat
    var age: CGFloat = 0
    var band: Int
    /// Melody pitch when thrown, which sets where on the player it starts.
    var melody: CGFloat
}

/// Mutable particle state kept outside SwiftUI diffing.
private final class ParticleField {
    static let bandCount = 24
    static let sparkLife: CGFloat = 0.9

    var particles: [Particle] = (0 ..< 140).map { _ in ParticleField.makeParticle(y: .random(in: -1.3 ... 1.3)) }
    var sparks: [Spark] = []
    private let detector = DrumHitDetector()
    private var lastUpdate = Date()
    private(set) var loudness: CGFloat = 0

    private static func makeParticle(y: CGFloat) -> Particle {
        Particle(
            x: .random(in: -1 ... 1),
            y: y,
            z: .random(in: 0.5 ... 3.5),
            phase: .random(in: 0 ... (.pi * 2)),
            band: .random(in: 0 ..< bandCount)
        )
    }

    /// Advances the simulation one frame.
    func advance(levels: [CGFloat], melody: CGFloat, now: Date) {
        let dt = min(0.1, CGFloat(now.timeIntervalSince(lastUpdate)))
        lastUpdate = now
        let time = CGFloat(now.timeIntervalSinceReferenceDate)
        let bass = levels.mean(0 ..< 3)
        loudness = loudness * 0.9 + levels.mean(0 ..< levels.count) * 0.1

        for hit in detector.detect(levels: levels, time: now.timeIntervalSinceReferenceDate) {
            switch hit {
            case .kick:
                for i in particles.indices { particles[i].lift += 0.35 }
            case .snare:
                for _ in 0 ..< 10 {
                    let angle = CGFloat.random(in: -.pi * 0.9 ... .pi * 0.1) // mostly up and to the right
                    let speed = CGFloat.random(in: 60 ... 160)
                    sparks.append(Spark(x: 0, y: 0, vx: cos(angle) * speed, vy: sin(angle) * speed,
                                        band: .random(in: 6 ..< 13), melody: melody))
                }
            case .hat:
                for _ in 0 ..< 6 {
                    particles[Int.random(in: particles.indices)].twinkle = 1
                }
            case .note:
                // A note from any instrument lights up particles around its pitch.
                let near = particles.indices.filter { abs(abs(particles[$0].x) - melody) < 0.15 }
                for i in near.shuffled().prefix(8) {
                    particles[i].twinkle = max(particles[i].twinkle, 0.8)
                }
            }
        }

        let decay = exp(-dt * 4)
        for i in particles.indices {
            var p = particles[i]
            p.y -= (0.08 + 0.55 * bass + p.lift) * dt / p.z
            p.x += sin(time * 0.6 + p.phase) * 0.04 * dt
            p.lift *= decay
            p.twinkle *= exp(-dt * 6)
            if p.y < -1.3 {
                p = Self.makeParticle(y: 1.3)
            }
            particles[i] = p
        }

        for i in sparks.indices {
            sparks[i].x += sparks[i].vx * dt
            sparks[i].y += sparks[i].vy * dt
            sparks[i].vx *= decay
            sparks[i].vy = sparks[i].vy * decay + 20 * dt // a little gravity
            sparks[i].age += dt
        }
        sparks.removeAll { $0.age > Self.sparkLife }
    }
}

struct FloatingParticlesView: View {
    var isActive: Bool
    var colors: [Color]
    /// Distance from the canvas edges to the player, to find the album art.
    var bleed = EdgeInsets()

    @State private var field = ParticleField()
    @ObservedObject private var engine = VisualizerEngine.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let levels = engine.levels(ParticleField.bandCount)
            let features = engine.features
            let _ = field.advance(levels: levels, melody: features.melody, now: timeline.date)
            let particles = field.particles
            let sparks = field.sparks
            let bass = levels.mean(0 ..< 3)
            // Quiet passages dim the field; loud ones bring it fully up.
            let presence = Double(0.55 + 0.45 * min(1, field.loudness * 2.5))

            Canvas { context, size in
                // Spread particles over the visible player (plus a small margin), not the
                // whole bleed area, which mostly lies outside the notch.
                let visible = CGRect(
                    x: bleed.leading - 20, y: bleed.top - 30,
                    width: max(1, size.width - bleed.leading - bleed.trailing + 40),
                    height: max(1, size.height - bleed.top - bleed.bottom + 50)
                )
                for particle in particles {
                    let level = levels.indices.contains(particle.band) ? levels[particle.band] : 0
                    let scale = visible.height * 0.9 / (particle.z + 0.8)
                    let center = CGPoint(
                        x: visible.midX + particle.x * visible.width * 0.5 * min(1.25, 1.6 / (particle.z + 0.6)),
                        y: visible.midY + particle.y * visible.height * 0.5
                    )
                    let boost = features.melodyBoost(at: abs(particle.x))
                    let radius = max(1.1, scale * 0.016 * (0.75 + 0.9 * level + 0.6 * particle.twinkle + 0.8 * boost)
                        * (0.85 + 0.3 * bass))
                    var dot = context
                    let depth = 0.12 + 0.75 / Double(particle.z)
                    dot.opacity = min(1, depth * (0.55 + 0.45 * Double(level)) * presence
                        + Double(particle.twinkle) * 0.6 + Double(boost) * 0.45)
                    dot.fill(
                        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .color(Self.color(forBand: particle.band, in: colors))
                    )
                }

                let playerHeight = size.height - bleed.top - bleed.bottom
                let art = CGPoint(x: bleed.leading + playerHeight / 2, y: bleed.top + playerHeight / 2)
                for spark in sparks {
                    let life = Double(1 - spark.age / ParticleField.sparkLife)
                    let radius = 1 + 1.6 * CGFloat(life)
                    var dot = context
                    dot.opacity = life
                    let start = CGPoint(x: art.x + playerHeight * 0.7 + spark.melody * 360, y: art.y)
                    dot.fill(
                        Path(ellipseIn: CGRect(x: start.x + spark.x - radius, y: start.y + spark.y - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .color(Self.color(forBand: spark.band, in: colors))
                    )
                }
            }
        }
        .runsVisualizerEngine(isActive)
        .allowsHitTesting(false)
    }

    /// Low bands take the first gradient color, high bands the last.
    private static func color(forBand band: Int, in colors: [Color]) -> Color {
        guard colors.count > 1 else { return colors.first ?? .white }
        let position = CGFloat(band) / CGFloat(ParticleField.bandCount - 1)
        let index = Int((position * CGFloat(colors.count - 1)).rounded())
        return colors[max(0, min(colors.count - 1, index))]
    }
}

extension View {
    /// Animated background behind the music player (style picked in Settings).
    func perchPlayerBackground() -> some View {
        modifier(PlayerBackgroundModifier())
    }
}

private struct PlayerBackgroundModifier: ViewModifier {
    /// Let the effect spill past the player to the edges of the open notch
    /// (which clips it to its rounded shape), so it doesn't read as a box.
    private static let bleed = EdgeInsets(top: 70, leading: 40, bottom: 30, trailing: 300)

    @ObservedObject private var music = MusicManager.shared
    @Default(.playerBackground) private var style
    @Default(.visualizerColorMode) private var colorMode
    @Default(.visualizerGradient) private var gradient

    func body(content: Content) -> some View {
        content.background {
            Group {
                switch style {
                case .none:
                    EmptyView()
                case .particles:
                    FloatingParticlesView(
                        isActive: music.isPlaying,
                        colors: VisualizerPalette.colors(albumArt: music.avgColor),
                        bleed: Self.bleed
                    )
                default:
                    PlayerBackgroundView(
                        style: style,
                        isActive: music.isPlaying,
                        colors: VisualizerPalette.colors(albumArt: music.avgColor),
                        bleed: Self.bleed
                    )
                }
            }
            .padding(EdgeInsets(top: -Self.bleed.top, leading: -Self.bleed.leading,
                                bottom: -Self.bleed.bottom, trailing: -Self.bleed.trailing))
            // Keep the tab row and the camera housing clear: the effect fades in
            // just below them instead of outlining the physical notch.
            .mask {
                VStack(spacing: 0) {
                    Color.clear.frame(height: Self.bleed.top - 8)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 36)
                    Color.black
                }
                .padding(EdgeInsets(top: -Self.bleed.top, leading: -Self.bleed.leading,
                                    bottom: -Self.bleed.bottom, trailing: -Self.bleed.trailing))
            }
            .opacity(music.isPlaying ? style.opacity : 0)
            .animation(.smooth(duration: 0.6), value: music.isPlaying)
        }
    }
}

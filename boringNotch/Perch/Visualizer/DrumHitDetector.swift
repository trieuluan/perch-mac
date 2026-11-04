//
//  DrumHitDetector.swift
//  Perch
//
//  Simple onset detection on VisualizerEngine's 24 bands. Spots kick drums,
//  snares and hi-hats, plus note attacks from any instrument (a plucked
//  string, a piano key, a strummed chord) so effects still react to songs
//  with little or no percussion.
//

import CoreGraphics

enum DrumHit: Int, CaseIterable {
    case kick, snare, hat
    /// A note attack from any instrument, reported only when no drum hit
    /// happened in the same frame.
    case note

    static let drums: [DrumHit] = [.kick, .snare, .hat]

    /// Band range (of 24) each hit is listened for in.
    var bands: Range<Int> { [0 ..< 3, 6 ..< 13, 16 ..< 24, 0 ..< 24][rawValue] }
    /// Minimum jump in energy between frames to count as a drum hit.
    var rise: CGFloat { [0.12, 0.10, 0.09, 0][rawValue] }
    /// Minimum seconds between two hits of the same kind.
    var cooldown: Double { [0.22, 0.16, 0.10, 0.12][rawValue] }
}

final class DrumHitDetector {
    private var lastEnergy = [CGFloat](repeating: 0, count: DrumHit.allCases.count)
    private var average = [CGFloat](repeating: 0, count: DrumHit.allCases.count)
    private var lastHit = [Double](repeating: 0, count: DrumHit.allCases.count)
    private var previousLevels: [CGFloat] = []
    private var averageFlux: CGFloat = 0

    /// Call once per frame with the 24 engine bands.
    func detect(levels: [CGFloat], time: Double) -> [DrumHit] {
        guard levels.count >= 24 else { return [] }
        var hits: [DrumHit] = []

        // Drums: a sharp rise in their range that also clears the range's
        // running average, with a short cooldown.
        for hit in DrumHit.drums {
            let i = hit.rawValue
            let slice = levels[hit.bands]
            let energy = slice.reduce(0, +) / CGFloat(slice.count)
            if energy - lastEnergy[i] > hit.rise,
               energy > average[i] * 1.2 + 0.05,
               time - lastHit[i] > hit.cooldown {
                hits.append(hit)
                lastHit[i] = time
            }
            lastEnergy[i] = energy
            average[i] = average[i] * 0.92 + energy * 0.08
        }

        // Note attacks: spectral flux, i.e. how much energy appeared across all
        // bands since the last frame, compared with its own running average.
        if previousLevels.count == levels.count {
            var flux: CGFloat = 0
            for i in levels.indices { flux += max(0, levels[i] - previousLevels[i]) }
            flux /= CGFloat(levels.count)

            let note = DrumHit.note
            if hits.isEmpty,
               flux > averageFlux * 1.8 + 0.035,
               time - lastHit[note.rawValue] > note.cooldown {
                hits.append(note)
                lastHit[note.rawValue] = time
            }
            averageFlux = averageFlux * 0.9 + flux * 0.1
        }
        previousLevels = levels
        return hits
    }
}

extension Array where Element == CGFloat {
    /// Mean of a band range, or 0 when out of bounds.
    func mean(_ range: Range<Int>) -> CGFloat {
        let clamped = range.clamped(to: indices)
        guard !clamped.isEmpty else { return 0 }
        return self[clamped].reduce(0, +) / CGFloat(clamped.count)
    }
}

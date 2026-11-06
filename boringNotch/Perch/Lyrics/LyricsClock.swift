//
//  LyricsClock.swift
//  Perch
//
//  Where the song is right now, as the lyrics see it: the player's position
//  extrapolated between updates, plus a per-track offset the user can nudge
//  (music videos often start with an intro the synced lyrics don't have).
//

import SwiftUI

@MainActor
final class LyricsClock: ObservableObject {
    static let shared = LyricsClock()

    /// Seconds added to the song position; positive shows lines later.
    @Published private(set) var offset: Double = 0
    private var offsets: [String: Double] = [:]
    private var trackKey = ""

    private init() {}

    private var music: MusicManager { .shared }

    /// Song position used for lyrics at `date`.
    func position(at date: Date) -> Double {
        syncTrack()
        var elapsed = music.elapsedTime
        if music.isPlaying {
            elapsed += date.timeIntervalSince(music.timestampDate) * music.playbackRate
        }
        return max(0, elapsed) - offset
    }

    /// Index of the line being sung at `time`, or nil before the first line.
    func lineIndex(at time: Double) -> Int? {
        let lines = music.syncedLyrics
        guard let first = lines.first, time >= first.time else { return nil }
        var low = 0, high = lines.count - 1, found = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    /// How long line `index` stays on screen.
    func duration(ofLine index: Int) -> Double {
        let lines = music.syncedLyrics
        guard lines.indices.contains(index) else { return 0 }
        let next = index + 1 < lines.count ? lines[index + 1].time : max(lines[index].time + 4, music.songDuration)
        return max(0.5, next - lines[index].time)
    }

    func nudge(by seconds: Double) {
        syncTrack()
        offset = ((offset + seconds) * 10).rounded() / 10
        offsets[trackKey] = offset
    }

    func resetOffset() {
        syncTrack()
        offset = 0
        offsets[trackKey] = nil
    }

    /// Jumps the player to where line `index` starts.
    func seek(toLine index: Int) {
        let lines = music.syncedLyrics
        guard lines.indices.contains(index) else { return }
        music.seek(to: max(0, lines[index].time + offset))
    }

    /// Each track keeps its own offset for this session.
    private func syncTrack() {
        let key = "\(music.songTitle)|\(music.artistName)"
        guard key != trackKey else { return }
        trackKey = key
        let saved = offsets[key] ?? 0
        if saved != offset {
            // Not during a view update.
            DispatchQueue.main.async { self.offset = saved }
        }
    }
}

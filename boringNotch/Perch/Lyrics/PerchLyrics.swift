//
//  PerchLyrics.swift
//  Perch
//
//  Finds time-synced lyrics on LRCLIB (free, no account) for whatever is
//  playing and fills MusicManager's lyrics fields, replacing Boring Notch's
//  simpler lookup:
//
//  - keeps diacritics, so Vietnamese titles match;
//  - cleans YouTube-style titles ("Artist - Title (Official MV)", "A | B | MV");
//  - prefers synced lyrics whose length matches the track;
//  - parses LRC with several timestamps per line, 3-digit fractions and offsets;
//  - falls back to Apple Music's own (unsynced) lyrics;
//  - caches results per track.
//

import Defaults
import Foundation

extension Defaults.Keys {
    /// The current line under the closed notch while music plays.
    static let closedNotchLyrics = Key<Bool>("perchClosedNotchLyrics", default: true)
    /// Set once lyrics have been switched on for existing users.
    static let lyricsEnabledByPerch = Key<Bool>("perchLyricsEnabledByDefault", default: false)
}

@MainActor
enum PerchLyrics {
    typealias Line = (time: Double, text: String)

    struct Result {
        var plain: String
        var synced: [Line]
    }

    private static var cache: [String: Result] = [:]
    private static var currentKey = ""

    private static var observation: Defaults.Observation?

    /// Call once at launch. Boring Notch ships lyrics switched off; Perch turns
    /// them on once. Turning them on loads the current track right away.
    static func start() {
        if !Defaults[.lyricsEnabledByPerch] {
            Defaults[.lyricsEnabledByPerch] = true
            Defaults[.enableLyrics] = true
        }
        reloadCurrentTrack()
        observation = Defaults.observe(.enableLyrics, options: []) { _ in
            Task { @MainActor in reloadCurrentTrack() }
        }
    }

    private static func reloadCurrentTrack() {
        let music = MusicManager.shared
        // Before anything plays, the title is a placeholder.
        guard music.bundleIdentifier != nil else { return }
        currentKey = ""
        load(into: music, bundleIdentifier: music.bundleIdentifier, title: music.songTitle,
             artist: music.artistName, album: music.album, duration: music.songDuration)
    }

    /// Called when the track changes.
    static func load(into music: MusicManager, bundleIdentifier: String?, title: String, artist: String,
                     album: String, duration: Double) {
        guard Defaults[.enableLyrics], !title.isEmpty else {
            music.isFetchingLyrics = false
            music.currentLyrics = ""
            music.syncedLyrics = []
            currentKey = ""
            return
        }
        let key = "\(title)|\(artist)"
        guard key != currentKey else { return }
        currentKey = key

        if let cached = cache[key] {
            apply(cached, to: music)
            return
        }
        music.isFetchingLyrics = true
        music.currentLyrics = ""
        music.syncedLyrics = []

        Task {
            var result = await search(title: title, artist: artist, album: album, duration: duration)
            #if DEBUG
            if let demo = demoLyrics(title: title) { result = demo }
            #endif
            if result?.synced.isEmpty ?? true, bundleIdentifier?.contains("com.apple.Music") == true,
               let native = await appleMusicLyrics() {
                result = Result(plain: native, synced: [])
            }
            let final = result ?? Result(plain: "", synced: [])
            cache[key] = final
            // The track may have changed while we were waiting.
            guard currentKey == key else { return }
            apply(final, to: music)
        }
    }

    private static func apply(_ result: Result, to music: MusicManager) {
        music.syncedLyrics = result.synced
        music.currentLyrics = result.plain.isEmpty ? result.synced.map(\.text).joined(separator: "\n") : result.plain
        music.isFetchingLyrics = false
    }

    // MARK: - LRCLIB

    private struct Entry: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let plainLyrics: String?
        let syncedLyrics: String?
        let instrumental: Bool?
    }

    private static func search(title: String, artist: String, album: String, duration: Double) async -> Result? {
        let guesses = guesses(title: title, artist: artist)
        var best: (score: Double, entry: Entry)?
        for query in queries(for: guesses) {
            for entry in await fetch(query) {
                guard let score = score(entry, against: guesses, duration: duration) else { continue }
                if score > (best?.score ?? -.infinity) { best = (score, entry) }
            }
            // Same title, same artist, synced and the right length: done.
            if let best, best.score >= 15 { break }
        }
        guard let entry = best?.entry else { return nil }
        let synced = parseLRC(entry.syncedLyrics ?? "")
        let plain = (entry.plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !synced.isEmpty || !plain.isEmpty else { return nil }
        return Result(plain: plain, synced: synced)
    }

    /// Scores a search result, or returns nil when it isn't this song. Wrong
    /// lyrics are worse than none, so a result must have the same title and
    /// either a matching artist or the same length.
    private static func score(_ entry: Entry, against guesses: [Guess], duration: Double) -> Double? {
        guard entry.instrumental != true else { return nil }
        let hasSynced = !(entry.syncedLyrics ?? "").isEmpty
        guard hasSynced || !(entry.plainLyrics ?? "").isEmpty else { return nil }

        let lengthOff = duration > 0 ? entry.duration.map { abs($0 - duration) } : nil
        let entryTitle = normalize(cleanTitle(entry.trackName ?? ""))
        let entryArtist = normalize(entry.artistName ?? "")

        var best: Double?
        for guess in guesses {
            let title = titleSimilarity(entryTitle, normalize(cleanTitle(guess.title)))
            guard title > 0 else { continue }
            let artistMatches = guess.artists.contains { artist in
                let artist = normalize(artist)
                return !artist.isEmpty && (entryArtist.contains(artist) || artist.contains(entryArtist))
            }
            let sameLength = (lengthOff ?? .infinity) <= 3
            guard artistMatches || (title == 1 && sameLength) else { continue }

            var score = title * 6 + (artistMatches ? 4 : 0) + (hasSynced ? 3 : 1)
            if let off = lengthOff { score += off <= 3 ? 3 : off <= 10 ? 1 : 0 }
            best = max(best ?? score, score)
        }
        return best
    }

    /// 1 for the same title, 0.7 when one contains the other and they're close
    /// in length ("Chia Tay" is not "Chia Tay Quá Đã"), else 0.
    private static func titleSimilarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        guard long.contains(short), Double(short.count) / Double(long.count) >= 0.75 else { return 0 }
        return 0.7
    }

    /// Lowercase, no diacritics, letters and digits only: "Bâng Khuâng" → "bang khuang".
    private static func normalize(_ text: String) -> String {
        let folded = text.lowercased()
            .replacingOccurrences(of: "đ", with: "d")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static func fetch(_ query: [URLQueryItem]) async -> [Entry] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = query
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Perch (https://github.com/trieuluan/perch-mac)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    // MARK: - Queries

    private static let noise = [
        "official", "music video", "m/v", "mv", "lyric", "lyrics", "audio", "video", "visualizer",
        "visualiser", "karaoke", "4k", "hd", "hq", "remaster", "remastered", "live", "performance",
        "vietsub", "engsub", "loi bai hat", "lời bài hát",
    ]

    private static func isNoise(_ text: String) -> Bool {
        let lower = text.lowercased()
        return noise.contains { lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil
            || lower.contains($0) && $0.count > 3 }
    }

    /// "Song (Official MV) [4K]" → "Song"; "Song ft. X" → "Song".
    private static func cleanTitle(_ title: String) -> String {
        var text = title
        // Bracketed tags like (Official MV), [Lyrics], 【MV】.
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#, #"【[^】]*】"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+(ft\.?|feat\.?|featuring|x)\s+.*$"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    /// YouTube channel names: "Artist - Topic", "ArtistVEVO", "Artist Official".
    private static func cleanArtist(_ artist: String) -> String {
        artist
            .replacingOccurrences(of: #"\s*-\s*Topic$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"VEVO$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(Official|Official Channel|Music)$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    /// One reading of the now-playing title: which part is the song, who sings it.
    private struct Guess {
        let title: String
        let artists: [String]
    }

    /// "JustaTee x Binz", "A, B & C", "A ft. B" → each artist.
    private static func splitArtists(_ text: String) -> [String] {
        text.replacingOccurrences(
            of: #"\s+(x|X|ft\.?|feat\.?|featuring|vs\.?|và|and|with)\s+|[,&;/+]"#, with: "|",
            options: .regularExpression)
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Possible (title, artists) readings, most likely first. Web players often
    /// report the channel as the artist and pack "Artist - Song (Official MV)"
    /// into the title, in either order.
    private static func guesses(title: String, artist: String) -> [Guess] {
        let channel = cleanArtist(artist)
        var result: [Guess] = []
        func add(_ title: String, _ artists: String) {
            let names = splitArtists(artists) + (channel.isEmpty ? [] : [channel])
            if !cleanTitle(title).isEmpty { result.append(Guess(title: title, artists: names)) }
        }
        let dashParts = title.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        let pipeParts = title.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isNoise($0) }

        if dashParts.count == 2 {
            add(dashParts[1], dashParts[0]) // "Artist - Song"
            add(dashParts[0], dashParts[1]) // "Song - Artist"
        }
        if pipeParts.count >= 2 {
            add(pipeParts[1], pipeParts[0])
            add(pipeParts[0], pipeParts[1])
        }
        add(title, channel)
        return result
    }

    private static func queries(for guesses: [Guess]) -> [[URLQueryItem]] {
        var result: [[URLQueryItem]] = []
        func add(_ items: [URLQueryItem]) {
            if !result.contains(items) { result.append(items) }
        }
        for guess in guesses {
            var items = [URLQueryItem(name: "track_name", value: cleanTitle(guess.title))]
            if let first = guess.artists.first { items.append(URLQueryItem(name: "artist_name", value: first)) }
            add(items)
        }
        // Free-text on the likeliest title alone; scoring filters what comes back.
        if let first = guesses.first { add([URLQueryItem(name: "q", value: cleanTitle(first.title))]) }
        return Array(result.prefix(5))
    }

    // MARK: - LRC

    /// Lines like "[01:02.34][02:10.50] text" and an optional "[offset:+250]" tag.
    static func parseLRC(_ lrc: String) -> [Line] {
        guard !lrc.isEmpty,
              let stamp = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
        else { return [] }
        var offset = 0.0
        if let match = lrc.range(of: #"\[offset:\s*([+-]?\d+)\]"#, options: .regularExpression) {
            let digits = lrc[match].filter { $0.isNumber || $0 == "-" || $0 == "+" }
            offset = (Double(digits) ?? 0) / 1000
        }
        var lines: [Line] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let ns = line as NSString
            let matches = stamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.upperBound).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound {
                    let digits = ns.substring(with: match.range(at: 3))
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                // Keep empty lines too: they mark instrumental breaks.
                lines.append((minutes * 60 + seconds + fraction - offset, text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    #if DEBUG
    /// Debug builds only: lyrics for the README demo track, which LRCLIB doesn't
    /// have. Put an LRC file at ~/Library/Containers/com.trieuluan.perch/Data/demo-lyrics.lrc
    /// whose first line is "[ti:<track title>]".
    private static func demoLyrics(title: String) -> Result? {
        let path = NSHomeDirectory() + "/demo-lyrics.lrc"
        guard let lrc = try? String(contentsOfFile: path, encoding: .utf8),
              lrc.hasPrefix("[ti:\(title)]") else { return nil }
        let synced = parseLRC(lrc)
        return synced.isEmpty ? nil : Result(plain: "", synced: synced)
    }
    #endif

    // MARK: - Apple Music

    private static func appleMusicLyrics() async -> String? {
        let script = """
        tell application "Music"
            if it is running then
                try
                    set l to lyrics of current track
                    if l is not missing value then return l
                end try
            end if
            return ""
        end tell
        """
        guard let result = try? await AppleScriptHelper.execute(script),
              let text = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}

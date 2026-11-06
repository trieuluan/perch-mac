//
//  LyricsPage.swift
//  Perch
//
//  The player's second page: the lyrics around the line being sung, karaoke
//  style. The current line is bright and kept in the middle, long lines wrap
//  to two lines, and clicking a line jumps there. Timing buttons (to fix
//  lyrics that run early or late, common with music videos) appear on hover.
//

import AppKit
import SwiftUI

struct LyricsPage: View {
    @ObservedObject private var music = MusicManager.shared
    @State private var hovering = false

    var body: some View {
        content
            .padding(.leading, 5)
            .padding(.trailing, 14) // room for the page dots
            .overlay(alignment: .bottomTrailing) {
                if hovering && !music.syncedLyrics.isEmpty {
                    LyricsTimingControls()
                        .transition(.opacity)
                }
            }
            .onHover { inside in
                withAnimation(.smooth(duration: 0.2)) { hovering = inside }
            }
    }

    @ViewBuilder
    private var content: some View {
        if music.isFetchingLyrics {
            placeholder(String(localized: "Looking for lyrics…"), symbol: "magnifyingglass")
        } else if !music.syncedLyrics.isEmpty {
            SyncedLyricsList()
        } else if !music.currentLyrics.isEmpty {
            // Lyrics without timestamps: scroll through them by hand.
            ScrollView(.vertical, showsIndicators: false) {
                Text(music.currentLyrics)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        } else if music.bundleIdentifier == nil || music.isPlayerIdle {
            placeholder(String(localized: "Play a song to see its lyrics"), symbol: "music.note")
        } else {
            placeholder(String(localized: "No lyrics found for this song"), symbol: "text.page.slash")
        }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18))
            Text(text)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.gray)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SyncedLyricsList: View {
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var clock = LyricsClock.shared
    @State private var current: Int?
    @State private var hovering = false
    @State private var lastManualScroll: Date = .distantPast
    @State private var scrollMonitor: Any?

    /// After the user scrolls by hand, wait this long before following the song again.
    private static let followDelay: TimeInterval = 4

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        // Room so the first and last lines can sit in the middle.
                        Color.clear.frame(height: geo.size.height / 2 - 12)
                        ForEach(Array(music.syncedLyrics.enumerated()), id: \.offset) { index, line in
                            row(index: index, text: line.text)
                                .id(index)
                        }
                        Color.clear.frame(height: geo.size.height / 2 - 12)
                    }
                }
                // Scrollable by hand; scrolling here doesn't close the notch.
                .mask(LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                            .init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom))
                .background {
                    TimelineView(.periodic(from: .now, by: 0.2)) { context in
                        let index = clock.lineIndex(at: clock.position(at: context.date))
                        let following = context.date.timeIntervalSince(lastManualScroll) > Self.followDelay
                        Color.clear.onChange(of: FollowState(index: index, following: following), initial: true) { _, state in
                            withAnimation(.smooth(duration: 0.45)) {
                                current = state.index
                                if state.following {
                                    proxy.scrollTo(state.index ?? 0, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onHover { inside in
            hovering = inside
            PerchGestureGuard.pointerInScrollableArea = inside
        }
        .onAppear {
            // Note when the user scrolls the lyrics, to pause following the song.
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                if hovering, abs(event.scrollingDeltaY) > 0.5 { lastManualScroll = Date() }
                return event
            }
        }
        .onDisappear {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
            PerchGestureGuard.pointerInScrollableArea = false
        }
    }

    private func row(index: Int, text: String) -> some View {
        let isCurrent = index == current
        let isPast = current.map { index < $0 } ?? false
        return Text(text.isEmpty ? "♪" : text)
            .font(.system(size: 12, weight: isCurrent ? .bold : .medium))
            .foregroundStyle(isCurrent ? .white : .white.opacity(isPast ? 0.28 : 0.45))
            // The line being sung is always shown in full; the others stay short.
            .lineLimit(isCurrent ? nil : 2)
            .fixedSize(horizontal: false, vertical: isCurrent)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { clock.seek(toLine: index) }
    }
}

/// − +1.0s + : nudges the lyrics later or earlier for this song.
private struct LyricsTimingControls: View {
    @ObservedObject private var clock = LyricsClock.shared

    var body: some View {
        HStack(spacing: 2) {
            button("minus", by: -0.5, help: String(localized: "Show lyrics earlier"))
            Text(clock.offset == 0 ? "0s" : String(format: "%+.1fs", clock.offset))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(clock.offset == 0 ? .gray : .white)
                .frame(width: 38)
                .contentShape(Rectangle())
                .onTapGesture { clock.resetOffset() }
                .help(String(localized: "Lyrics timing. Click to reset."))
            button("plus", by: 0.5, help: String(localized: "Show lyrics later"))
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.75)))
        .padding(.bottom, 2)
    }

    private func button(_ symbol: String, by seconds: Double, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.white.opacity(0.12)))
            .contentShape(Circle())
            .onTapGesture { clock.nudge(by: seconds) }
            .help(help)
    }
}

private struct FollowState: Equatable {
    let index: Int?
    let following: Bool
}

/// While the pointer is over content that scrolls vertically (the lyrics),
/// two-finger swipes scroll it instead of opening or closing the notch.
@MainActor
enum PerchGestureGuard {
    static var pointerInScrollableArea = false
}

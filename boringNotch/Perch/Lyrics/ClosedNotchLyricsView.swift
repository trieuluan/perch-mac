//
//  ClosedNotchLyricsView.swift
//  Perch
//
//  The current lyric line under the closed notch, following the song. A line
//  wider than the notch scrolls sideways while it is sung, so it ends on its
//  last word instead of being cut off.
//

import Defaults
import SwiftUI

struct ClosedNotchLyricsView: View {
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var clock = LyricsClock.shared
    let width: CGFloat

    @State private var textWidth: CGFloat = 0

    private var available: CGFloat { max(0, width - 24) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let time = clock.position(at: context.date)
            let index = clock.lineIndex(at: time)
            let text = index.map { music.syncedLyrics[$0].text } ?? ""
            let overflow = max(0, textWidth - available)

            ZStack(alignment: overflow > 0 ? .leading : .center) {
                if !text.isEmpty {
                    Text(text)
                        .fixedSize()
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: LyricWidthKey.self, value: geo.size.width)
                        })
                        .offset(x: -overflow * scrollProgress(index: index, time: time))
                        .id(index)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: available, height: 18, alignment: overflow > 0 ? .leading : .center)
            .clipped()
            .mask(edgeFade(active: overflow > 0))
            .animation(.smooth(duration: 0.35), value: index)
            .onPreferenceChange(LyricWidthKey.self) { textWidth = $0 }
        }
        .padding(.bottom, 6)
    }

    /// 0 at the start of the line, 1 a little before the next one: holds the
    /// first words briefly, then glides to the end.
    private func scrollProgress(index: Int?, time: Double) -> CGFloat {
        guard let index else { return 0 }
        let start = music.syncedLyrics[index].time
        let duration = clock.duration(ofLine: index)
        let hold = min(0.8, duration * 0.15)
        let progress = (time - start - hold) / max(0.1, duration - 2 * hold)
        return CGFloat(min(1, max(0, progress)))
    }

    private func edgeFade(active: Bool) -> some View {
        LinearGradient(
            stops: active
                ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                   .init(color: .black, location: 0.94), .init(color: .clear, location: 1)]
                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
            startPoint: .leading, endPoint: .trailing)
    }

    private var tint: Color {
        Defaults[.playerColorTinting]
            ? Color(nsColor: music.avgColor).ensureMinimumBrightness(factor: 0.75)
            : .white.opacity(0.85)
    }
}

private struct LyricWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

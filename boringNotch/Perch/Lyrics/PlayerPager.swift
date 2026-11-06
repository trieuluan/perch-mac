//
//  PlayerPager.swift
//  Perch
//
//  The area beside the album art has two pages, playback controls and lyrics.
//  A two-finger swipe moves between them; pages snap into place with a haptic
//  tick, like the calendar's day picker. Dots show the page and can be clicked.
//

import Defaults
import SwiftUI

extension Defaults.Keys {
    /// 0 = controls, 1 = lyrics. Remembered between openings of the notch.
    static let playerPage = Key<Int>("perchPlayerPage", default: 0)
}

struct PlayerPager<Controls: View>: View {
    @ViewBuilder let controls: () -> Controls

    @Default(.enableLyrics) private var lyricsEnabled
    @Default(.playerPage) private var savedPage
    @State private var page: Int?
    @State private var haptics = false

    var body: some View {
        if lyricsEnabled {
            pager
        } else {
            controls()
        }
    }

    private var pager: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    controls()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(0)
                    LyricsPage()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(1)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $page)
            .scrollClipDisabled(false)
        }
        .overlay(alignment: .topTrailing) { dots }
        .sensoryFeedback(.alignment, trigger: haptics)
        .onAppear { page = savedPage }
        .onChange(of: page) { _, newValue in
            guard let newValue, newValue != savedPage else { return }
            savedPage = newValue
            if Defaults[.enableHaptics] { haptics.toggle() }
        }
    }

    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< 2, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity((page ?? savedPage) == index ? 0.9 : 0.25))
                    .frame(width: (page ?? savedPage) == index ? 10 : 5, height: 5)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture {
                        withAnimation(.smooth(duration: 0.35)) { page = index }
                    }
            }
        }
        .animation(.smooth(duration: 0.25), value: page)
        .padding(.top, 4)
        .padding(.trailing, 2)
        .help(String(localized: "Swipe with two fingers to switch between controls and lyrics"))
    }
}

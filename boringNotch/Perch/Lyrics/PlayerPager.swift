//
//  PlayerPager.swift
//  Perch
//
//  The area beside the album art has two pages, playback controls and lyrics.
//  A two-finger swipe moves between them; pages snap into place with a haptic
//  tick, like the calendar's day picker. Dots show the page and can be clicked.
//

import AppKit
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
    @State private var swipe = SwipeHaptics()

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
            .onHover { swipe.hovering = $0 }
            .onAppear { swipe.start(width: { geo.size.width }) }
            .onDisappear { swipe.stop() }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $page)
            .scrollClipDisabled(false)
        }
        .overlay(alignment: .topTrailing) { dots }
        .onAppear { page = savedPage }
        .onChange(of: page) { _, newValue in
            guard let newValue, newValue != savedPage else { return }
            savedPage = newValue
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

/// Ticks the trackpad once per swipe, as soon as the fingers have moved far
/// enough to change page. Trackpads only play haptics while touched, so this
/// reads the swipe itself instead of waiting for the page to settle.
@MainActor
private final class SwipeHaptics {
    var hovering = false
    private var monitor: Any?
    private var travelled: CGFloat = 0
    private var ticked = false

    func start(width: @escaping () -> CGFloat) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, width: width()) }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent, width: CGFloat) {
        switch event.phase {
        case .began, .mayBegin:
            travelled = 0
            ticked = false
        case .changed:
            guard hovering, !ticked, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
            travelled += event.scrollingDeltaX
            // The pager snaps to the other page past about a third of its width.
            if abs(travelled) > max(40, width / 3) {
                ticked = true
                if Defaults[.enableHaptics] {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
        default:
            break
        }
    }
}

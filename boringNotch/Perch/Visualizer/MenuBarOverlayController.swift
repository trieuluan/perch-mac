//
//  MenuBarOverlayController.swift
//  Perch
//
//  A transparent, click-through window laid over the menu bar of the notched
//  (or main) screen, hosting MenuBarOverlayView. It sits above menu bar items
//  but below the notch window, joins every Space, and stays out of
//  full-screen apps.
//

import AppKit
import Combine
import Defaults
import SwiftUI

/// Whether the overlay window is actually on screen. It isn't while a
/// full-screen app hides the menu bar, the display sleeps or the Mac is locked,
/// and the overlay stops drawing (and stops the audio tap) until it is again.
@MainActor
final class MenuBarOverlayVisibility: ObservableObject {
    static let shared = MenuBarOverlayVisibility()
    @Published fileprivate(set) var isVisible = true
    private init() {}
}

@MainActor
final class MenuBarOverlayController {
    static let shared = MenuBarOverlayController()

    private var window: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var occlusionObserver: NSObjectProtocol?

    private init() {}

    /// Call once at launch.
    func setup() {
        Defaults.publisher(.menuBarOverlay)
            .map(\.newValue)
            .receive(on: RunLoop.main)
            .sink { [weak self] style in
                MainActor.assumeIsolated { self?.update(style: style) }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil else { return }
                    self.tearDown()
                    self.update(style: Defaults[.menuBarOverlay])
                }
            }
            .store(in: &cancellables)
    }

    private func update(style: MenuBarOverlayStyle) {
        if style == .none {
            tearDown()
        } else if window == nil {
            createWindow()
        }
    }

    private func tearDown() {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        window?.orderOut(nil)
        window = nil
    }

    private func createWindow() {
        guard let screen = NSScreen.screens.first(where: { $0.auxiliaryTopRightArea != nil }) ?? NSScreen.main
        else { return }

        let barHeight = max(
            screen.safeAreaInsets.top,
            screen.frame.maxY - screen.visibleFrame.maxY,
            NSStatusBar.system.thickness
        )
        let frame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - barHeight,
            width: screen.frame.width,
            height: barHeight
        )

        // Notch gap in window coordinates; without a notch, a zero-width gap at the center.
        let notch: NotchGap
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = NotchGap(minX: left.maxX - screen.frame.minX, maxX: right.minX - screen.frame.minX)
        } else {
            notch = NotchGap(minX: frame.width / 2, maxX: frame.width / 2)
        }

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Above status items (25), below Perch's notch window (27).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: MenuBarOverlayView(notch: notch))
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        window = panel

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            MainActor.assumeIsolated {
                MenuBarOverlayVisibility.shared.isVisible = panel?.occlusionState.contains(.visible) ?? false
            }
        }
        MenuBarOverlayVisibility.shared.isVisible = panel.occlusionState.contains(.visible)
    }
}

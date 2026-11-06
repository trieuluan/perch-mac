//
//  InputSourceMonitor.swift
//  Perch
//
//  Shows the keyboard input source (e.g. ABC ↔ Vietnamese Telex) and Caps Lock
//  in the notch when they change, since their menu bar indicators are small
//  and often hidden behind the notch.
//
//  Limitation: third-party Vietnamese typing apps (EVKey, OpenKey, Unikey)
//  switch modes inside a single input source, so macOS reports no change.
//

import AppKit
import Carbon
import Defaults

extension Defaults.Keys {
    static let inputSourceAlerts = Key<Bool>("perchInputSourceAlerts", default: true)
    static let capsLockAlerts = Key<Bool>("perchCapsLockAlerts", default: true)
}

@MainActor
final class InputSourceMonitor {
    static let shared = InputSourceMonitor()

    private var observer: NSObjectProtocol?
    private var capsTimer: Timer?
    private var capsLockOn = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    private var lastSourceID: String?

    private init() {}

    /// Call once at launch.
    func start() {
        guard observer == nil else { return }
        lastSourceID = Self.currentSource()?.id

        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputSourceChanged() }
        }

        // Caps Lock has no change notification without extra permissions;
        // reading the modifier flags a few times a second is cheap.
        capsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCapsLock() }
        }
        capsTimer?.tolerance = 0.1
    }

    private func inputSourceChanged() {
        guard let source = Self.currentSource(), source.id != lastSourceID else { return }
        lastSourceID = source.id
        guard Defaults[.inputSourceAlerts] else { return }
        PerchLiveActivity.shared.show(.init(symbol: "keyboard", tint: .purple, text: source.name), for: 1.6)
    }

    private func checkCapsLock() {
        let on = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        guard on != capsLockOn else { return }
        capsLockOn = on
        guard Defaults[.capsLockAlerts] else { return }
        PerchLiveActivity.shared.show(
            on ? .init(symbol: "capslock.fill", tint: .yellow, text: String(localized: "Caps Lock on"))
               : .init(symbol: "capslock", tint: .gray, text: String(localized: "Caps Lock off")),
            for: 1.4)
    }

    private static func currentSource() -> (id: String, name: String)? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        func string(_ key: CFString) -> String? {
            guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        }
        guard let id = string(kTISPropertyInputSourceID) else { return nil }
        return (id, string(kTISPropertyLocalizedName) ?? id)
    }
}

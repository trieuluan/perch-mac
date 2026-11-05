//
//  MenuBarOverflowManager.swift
//  Perch
//
//  Finds menu bar icons that macOS hides behind the notch when the menu bar is
//  too crowded, so Perch can show them inside the open notch.
//

import AppKit
import Defaults

extension Defaults.Keys {
    static let menuBarOverflow = Key<Bool>("perchMenuBarOverflow", default: true)
}

struct MenuBarOverflowItem: Identifiable {
    /// Owning app and its item index, when Accessibility exposes the item.
    let pid: pid_t?
    let axIndex: Int?
    /// The item's status window, when it could be matched.
    let windowID: CGWindowID?
    let title: String
    let frame: CGRect
    let appName: String?
    /// The owning app's icon, used when there's no real image.
    let appIcon: NSImage?
    /// What the item really looks like in the menu bar (needs Screen Recording).
    var image: NSImage?
    /// A readable name for built-in macOS items Accessibility doesn't expose
    /// (e.g. "Screen Mirroring"), from their status window's name.
    var systemName: String? = nil

    /// What to call the item in the list.
    var displayName: String {
        appName ?? systemName ?? String(localized: "Menu item")
    }

    var id: String {
        if let windowID { return "w\(windowID)" }
        return "\(pid ?? 0)-\(axIndex ?? 0)"
    }
}

@MainActor
final class MenuBarOverflowManager: ObservableObject {
    static let shared = MenuBarOverflowManager()

    enum State {
        case idle
        case loading
        case needsPermission
        case loaded
    }

    @Published private(set) var hiddenItems: [MenuBarOverflowItem] = []
    @Published private(set) var state: State = .idle
    /// False until Perch has Screen Recording access; items then show app icons.
    @Published private(set) var showsRealIcons = MenuBarItemWindows.canCapture
    /// Set briefly when an item couldn't be opened from Perch.
    @Published private(set) var unreachableItem: MenuBarOverflowItem?

    private init() {}

    func refresh() async {
        if state != .loaded { state = .loading }

        guard let data = await XPCHelperClient.shared.menuBarItemsData(),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let geometry = Self.notchGeometry()
        else {
            hiddenItems = []
            state = .needsPermission
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let axItems = raw.compactMap(Self.parse)
        let ownFrames = axItems.filter { $0.pid == ownPID }.map(\.frame)

        // Every status window behind the notch, minus Perch's own items.
        var windows = MenuBarItemWindows.all(in: geometry.band).filter { window in
            geometry.isHidden(window.frame)
                && !window.name.hasPrefix("Perch")
                && !ownFrames.contains { Self.sameSpot($0, window.frame) }
        }

        // Items Accessibility knows about, matched to their windows.
        var items: [MenuBarOverflowItem] = axItems
            .filter { $0.pid != ownPID && geometry.isHidden($0.frame) }
            .map { item in
                guard let match = windows.firstIndex(where: { Self.sameSpot($0.frame, item.frame) }) else { return item }
                let window = windows.remove(at: match)
                return MenuBarOverflowItem(pid: item.pid, axIndex: item.axIndex, windowID: window.id, title: item.title,
                                           frame: item.frame, appName: item.appName, appIcon: item.appIcon)
            }

        // Windows nobody claimed: items Accessibility doesn't expose.
        items += windows.map { window in
            MenuBarOverflowItem(pid: nil, axIndex: nil, windowID: window.id, title: "", frame: window.frame,
                                appName: nil, appIcon: nil, systemName: Self.systemItemName(window.name))
        }

        items.sort { $0.frame.minX < $1.frame.minX }
        hiddenItems = items
        state = .loaded

        await loadImages()
    }

    /// Asks for Screen Recording access so real icons can be shown.
    func requestRealIcons() {
        MenuBarItemWindows.requestCaptureAccess()
    }

    /// Opens the item's menu with AXPress, falling back to activating its app.
    func open(_ item: MenuBarOverflowItem) async {
        if let pid = item.pid, let index = item.axIndex,
           await XPCHelperClient.shared.pressMenuBarItem(pid: pid, index: index) {
            return
        }
        guard item.axIndex != nil else {
            // Accessibility doesn't expose this item, and a click can't reach an
            // item the notch hides, so explain instead of doing nothing.
            unreachableItem = item
            try? await Task.sleep(for: .seconds(6))
            if unreachableItem?.id == item.id { unreachableItem = nil }
            return
        }
        if let pid = item.pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    // MARK: - Helpers

    /// Readable names for macOS's own menu bar items, keyed by (part of) their
    /// status window name. Third-party items show up as "Item-0" and stay unnamed.
    private static func systemItemName(_ windowName: String) -> String? {
        let known: [(String, String)] = [
            ("ScreenMirroring", "Screen Mirroring"), ("AirPlay", "Screen Mirroring"),
            ("Display", "Display"), ("Sound", "Sound"), ("NowPlaying", "Now Playing"),
            ("WiFi", "Wi-Fi"), ("Bluetooth", "Bluetooth"), ("Battery", "Battery"),
            ("FocusModes", "Focus"), ("vpn", "VPN"), ("Siri", "Siri"), ("Spotlight", "Spotlight"),
            ("KeyboardBrightness", "Keyboard Brightness"), ("AccessibilityShortcuts", "Accessibility Shortcuts"),
            ("UserSwitcher", "Fast User Switching"), ("TimeMachine", "Time Machine"),
            ("TextInput", "Input Sources"), ("Hearing", "Hearing"), ("StageManager", "Stage Manager"),
            ("BentoBox", "Control Center"), ("Clock", "Clock"),
        ]
        return known.first { windowName.localizedCaseInsensitiveContains($0.0) }?.1
    }

    private func loadImages() async {
        showsRealIcons = MenuBarItemWindows.canCapture
        guard showsRealIcons else { return }

        let windows = hiddenItems.compactMap { item -> MenuBarItemWindow? in
            guard let id = item.windowID else { return nil }
            return MenuBarItemWindow(id: id, frame: item.frame, ownerPID: 0, name: "")
        }
        let images = await MenuBarItemWindows.images(for: windows)
        hiddenItems = hiddenItems.map { item in
            var item = item
            if let id = item.windowID { item.image = images[id] }
            return item
        }
    }

    /// Accessibility reports the icon's own frame (e.g. 24×24, inset), while the
    /// window list reports the whole item slot (e.g. 38×39). They are the same
    /// item when the icon's center falls inside the slot.
    private static func sameSpot(_ icon: CGRect, _ slot: CGRect) -> Bool {
        slot.insetBy(dx: -1, dy: -1).contains(CGPoint(x: icon.midX, y: icon.midY))
    }

    private static func parse(_ dict: [String: Any]) -> MenuBarOverflowItem? {
        guard let pid = (dict["pid"] as? NSNumber)?.int32Value,
              let index = (dict["index"] as? NSNumber)?.intValue,
              let x = (dict["x"] as? NSNumber)?.doubleValue,
              let y = (dict["y"] as? NSNumber)?.doubleValue,
              let width = (dict["width"] as? NSNumber)?.doubleValue,
              let height = (dict["height"] as? NSNumber)?.doubleValue
        else { return nil }

        let app = NSRunningApplication(processIdentifier: pid)
        return MenuBarOverflowItem(
            pid: pid,
            axIndex: index,
            windowID: nil,
            title: dict["title"] as? String ?? "",
            frame: CGRect(x: x, y: y, width: width, height: height),
            appName: app?.localizedName,
            appIcon: app?.icon
        )
    }

    /// The notched screen's menu bar band and its visible area right of the
    /// notch, in top-left global coordinates (like Accessibility and window frames).
    private struct NotchGeometry {
        let band: CGRect
        let visibleMinX: CGFloat

        /// Hidden = in the menu bar, but left of what's visible right of the notch.
        func isHidden(_ frame: CGRect) -> Bool {
            band.contains(CGPoint(x: frame.midX, y: frame.midY)) && frame.minX < visibleMinX - 0.5
        }
    }

    private static func notchGeometry() -> NotchGeometry? {
        guard let primary = NSScreen.screens.first,
              let screen = NSScreen.screens.first(where: { $0.auxiliaryTopRightArea != nil }),
              let visibleRight = screen.auxiliaryTopRightArea
        else { return nil }
        let bandTop = primary.frame.height - visibleRight.maxY
        return NotchGeometry(
            band: CGRect(x: screen.frame.minX, y: bandTop, width: screen.frame.width, height: visibleRight.height),
            visibleMinX: visibleRight.minX
        )
    }
}

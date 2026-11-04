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
    let pid: pid_t
    let index: Int
    let title: String
    let frame: CGRect
    let appName: String
    let icon: NSImage?

    var id: String { "\(pid)-\(index)" }
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

    private init() {}

    func refresh() async {
        if state != .loaded { state = .loading }

        guard let data = await XPCHelperClient.shared.menuBarItemsData(),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            hiddenItems = []
            state = .needsPermission
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        hiddenItems = raw
            .compactMap(Self.parse)
            .filter { $0.pid != ownPID && Self.isHiddenByNotch($0.frame) }
            .sorted { $0.frame.minX < $1.frame.minX }
        state = .loaded
    }

    /// Opens the item's menu. Falls back to activating the owning app if the
    /// item doesn't respond to AXPress.
    func open(_ item: MenuBarOverflowItem) async {
        let pressed = await XPCHelperClient.shared.pressMenuBarItem(pid: item.pid, index: item.index)
        if !pressed {
            NSRunningApplication(processIdentifier: item.pid)?.activate()
        }
    }

    // MARK: - Helpers

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
            index: index,
            title: dict["title"] as? String ?? "",
            frame: CGRect(x: x, y: y, width: width, height: height),
            appName: app?.localizedName ?? "Unknown",
            icon: app?.icon
        )
    }

    /// `frame` is in Accessibility coordinates (top-left origin of the primary screen).
    /// An item counts as hidden when it sits in the notched screen's menu bar but
    /// left of the visible area to the right of the notch.
    private static func isHiddenByNotch(_ frame: CGRect) -> Bool {
        guard let primary = NSScreen.screens.first,
              let screen = NSScreen.screens.first(where: { $0.auxiliaryTopRightArea != nil }),
              let visibleRight = screen.auxiliaryTopRightArea
        else { return false }

        // Convert the menu bar band of the notched screen to top-left coordinates.
        let bandTop = primary.frame.height - visibleRight.maxY
        let band = CGRect(
            x: screen.frame.minX,
            y: bandTop,
            width: screen.frame.width,
            height: visibleRight.height
        )
        guard band.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }

        return frame.minX < visibleRight.minX - 0.5
    }
}

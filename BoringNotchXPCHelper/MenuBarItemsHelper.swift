//
//  MenuBarItemsHelper.swift
//  BoringNotchXPCHelper
//
//  Perch: reads other apps' menu bar (status) items through the Accessibility API.
//  This lives in the helper because the main app is sandboxed and cannot use AX
//  to inspect or drive other processes.
//

import AppKit
import ApplicationServices

extension BoringNotchXPCHelper {

    @objc func menuBarItems(with reply: @escaping (Data?) -> Void) {
        guard AXIsProcessTrusted() else {
            reply(nil)
            return
        }

        var result: [[String: Any]] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy != .prohibited || app.bundleIdentifier == "com.apple.controlcenter" else { continue }
            let pid = app.processIdentifier
            for (index, item) in Self.extrasMenuBarItems(for: pid).enumerated() {
                guard let frame = Self.frame(of: item), frame.width > 0 else { continue }
                result.append([
                    "pid": Int(pid),
                    "index": index,
                    "title": Self.label(of: item) ?? "",
                    "x": frame.origin.x,
                    "y": frame.origin.y,
                    "width": frame.width,
                    "height": frame.height,
                ])
            }
        }
        reply(try? JSONSerialization.data(withJSONObject: result))
    }

    @objc func pressMenuBarItem(_ pid: Int32, index: Int, with reply: @escaping (Bool) -> Void) {
        let items = Self.extrasMenuBarItems(for: pid)
        guard AXIsProcessTrusted(), items.indices.contains(index) else {
            reply(false)
            return
        }
        reply(AXUIElementPerformAction(items[index], kAXPressAction as CFString) == .success)
    }

    // MARK: - AX helpers

    private static func extrasMenuBarItems(for pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        // Keep a hung app from stalling the whole scan.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return [] }
        return items
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func label(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String, !text.isEmpty {
                return text
            }
        }
        return nil
    }
}

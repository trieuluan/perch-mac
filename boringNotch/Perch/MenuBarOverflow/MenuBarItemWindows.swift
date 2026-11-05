//
//  MenuBarItemWindows.swift
//  Perch
//
//  Every menu bar (status) item is its own small window at the status-window
//  level. On macOS 26 they are all owned by Control Center, so the window list
//  alone can't say which app an item belongs to, but it does show every item,
//  including ones Accessibility doesn't expose. ScreenCaptureKit can then
//  capture each item's real image, even while the notch hides it.
//

import AppKit
import ScreenCaptureKit

struct MenuBarItemWindow {
    let id: CGWindowID
    /// Top-left global coordinates, like Accessibility frames.
    let frame: CGRect
    let ownerPID: pid_t
    let name: String
}

enum MenuBarItemWindows {
    private static let statusLevel = Int(CGWindowLevelForKey(.statusWindow))

    /// All status-item windows in the menu bar of the given band (top-left coordinates).
    static func all(in band: CGRect) -> [MenuBarItemWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == statusLevel,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width > 0, frame.width < 200,
                  band.contains(CGPoint(x: frame.midX, y: frame.midY))
            else { return nil }
            return MenuBarItemWindow(
                id: id,
                frame: frame,
                ownerPID: info[kCGWindowOwnerPID as String] as? pid_t ?? 0,
                name: info[kCGWindowName as String] as? String ?? ""
            )
        }
    }

    // MARK: - Images

    /// Whether Perch may capture other windows (Screen Recording access).
    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for Screen Recording access (shows the system prompt once,
    /// then System Settings).
    static func requestCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Captures each window's current image. Returns only the ones that worked.
    static func images(for windows: [MenuBarItemWindow]) async -> [CGWindowID: NSImage] {
        guard canCapture, !windows.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [:] }

        let scale = NSScreen.screens.first(where: { $0.auxiliaryTopRightArea != nil })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        var result: [CGWindowID: NSImage] = [:]

        for window in windows {
            guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else { continue }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(window.frame.width * scale))
            config.height = max(1, Int(window.frame.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                  let trimmed = trimmed(cgImage)
            else { continue }
            result[window.id] = NSImage(
                cgImage: trimmed,
                size: CGSize(width: CGFloat(trimmed.width) / scale, height: CGFloat(trimmed.height) / scale))
        }
        return result
    }

    /// Crops the empty padding around the icon so it can be shown larger.
    /// Returns nil when nothing was drawn at all.
    private static func trimmed(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where data[(y * width + x) * 4 + 3] > 12 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // A little breathing room around the glyph.
        let pad = 2
        let rect = CGRect(
            x: max(0, minX - pad), y: max(0, minY - pad),
            width: min(width, maxX + pad + 1) - max(0, minX - pad),
            height: min(height, maxY + pad + 1) - max(0, minY - pad)
        )
        return image.cropping(to: rect) ?? image
    }
}

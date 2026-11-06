//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Perch: menu bar items of other apps, read via Accessibility (performed by the helper).
    // Keep in sync with BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift.
    /// Replies with a JSON array of `{pid, index, title, x, y, width, height}` (top-left global coordinates).
    func menuBarItems(with reply: @escaping (Data?) -> Void)
    /// Performs AXPress on the `index`-th menu bar item of the app with `pid`.
    func pressMenuBarItem(_ pid: Int32, index: Int, with reply: @escaping (Bool) -> Void)
    // Perch: name of the process using the most CPU right now (sampled over ~0.5s).
    func topCPUProcessName(with reply: @escaping (String?) -> Void)
}


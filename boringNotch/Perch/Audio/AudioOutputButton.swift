//
//  AudioOutputButton.swift
//  Perch
//
//  Music player control that picks where audio plays (Mac speakers, AirPods,
//  Bluetooth speakers, displays, AirPlay).
//
//  The player's controls are rendered with drawingGroup(), which can't host
//  AppKit-backed views like SwiftUI's Menu (they show as a yellow placeholder).
//  So this is a plain SwiftUI button that pops up a native NSMenu at the cursor.
//

import AppKit
import SwiftUI

struct AudioOutputButton: View {
    @ObservedObject private var manager = AudioOutputManager.shared

    var body: some View {
        HoverButton(icon: manager.current?.symbol ?? "airplayaudio", scale: .medium) {
            AudioOutputMenu.shared.show()
        }
        .help(manager.current.map { String(localized: "Playing on \($0.name)") } ?? String(localized: "Audio output"))
    }
}

/// Builds and pops up the device list as a native menu.
@MainActor
private final class AudioOutputMenu: NSObject {
    static let shared = AudioOutputMenu()

    func show() {
        let manager = AudioOutputManager.shared
        let menu = NSMenu()
        for device in manager.devices {
            let item = NSMenuItem(title: device.name, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.state = device.id == manager.currentID ? .on : .off
            item.image = NSImage(systemSymbolName: device.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        if manager.devices.isEmpty {
            menu.addItem(NSMenuItem(title: String(localized: "No audio outputs"), action: nil, keyEquivalent: ""))
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioOutputDevice else { return }
        AudioOutputManager.shared.select(device)
    }
}

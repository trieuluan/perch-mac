//
//  BluetoothBatteryHelper.swift
//  BoringNotchXPCHelper
//
//  Perch: reads Bluetooth battery levels (AirPods left/right/case, or a single
//  level for other devices) from System Information. There's no public API for
//  this, and the sandboxed app can't run system_profiler, so the helper does.
//

import Foundation

extension BoringNotchXPCHelper {

    @objc func bluetoothBattery(forDeviceNamed name: String, with reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            // Right after connecting, the levels may not be published yet.
            for attempt in 0 ..< 3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 1.5) }
                if let summary = Self.batterySummary(forDeviceNamed: name) {
                    reply(summary)
                    return
                }
            }
            reply(nil)
        }
    }

    private static func batterySummary(forDeviceNamed name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = json["SPBluetoothDataType"] as? [[String: Any]]
        else { return nil }

        for section in sections {
            for list in [section["device_connected"], section["devices_list"]] {
                guard let entries = list as? [[String: Any]] else { continue }
                for entry in entries {
                    guard let (deviceName, info) = entry.first,
                          deviceName == name, let info = info as? [String: Any]
                    else { continue }
                    return summary(from: info)
                }
            }
        }
        return nil
    }

    private static func summary(from info: [String: Any]) -> String? {
        let parts: [(String, String)] = [
            ("L", "device_batteryLevelLeft"),
            ("R", "device_batteryLevelRight"),
            ("Case", "device_batteryLevelCase"),
        ]
        let split = parts.compactMap { label, key in (info[key] as? String).map { "\(label) \($0)" } }
        if !split.isEmpty { return split.joined(separator: " · ") }
        return info["device_batteryLevelMain"] as? String ?? info["device_batteryLevel"] as? String
    }
}

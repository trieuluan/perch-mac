//
//  ProcessStatsHelper.swift
//  BoringNotchXPCHelper
//
//  Perch: finds the process using the most CPU. Lives in the helper because the
//  sandboxed app can't read other processes' resource usage.
//

import AppKit
import Darwin

extension BoringNotchXPCHelper {

    @objc func topCPUProcessName(with reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let before = Self.cpuTimes()
            Thread.sleep(forTimeInterval: 0.5)
            let after = Self.cpuTimes()

            let ownPID = getpid()
            let top = after
                .filter { $0.key != ownPID }
                .map { (pid: $0.key, delta: $0.value &- (before[$0.key] ?? $0.value)) }
                .max { $0.delta < $1.delta }
            guard let top, top.delta > 0 else {
                reply(nil)
                return
            }
            // Prefer the app's display name; fall back to the process name.
            if let app = NSRunningApplication(processIdentifier: top.pid), let name = app.localizedName {
                reply(name)
                return
            }
            var buffer = [CChar](repeating: 0, count: 256)
            reply(proc_name(top.pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil)
        }
    }

    /// Total user + system CPU time per process, in mach time units.
    private static func cpuTimes() -> [pid_t: UInt64] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [:] }

        var result: [pid_t: UInt64] = [:]
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            if status == 0 { result[pid] = info.ri_user_time &+ info.ri_system_time }
        }
        return result
    }
}

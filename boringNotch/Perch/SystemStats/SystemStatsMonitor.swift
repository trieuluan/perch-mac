//
//  SystemStatsMonitor.swift
//  Perch
//
//  Samples CPU, memory and network use every couple of seconds with public
//  Mach / BSD APIs that work inside the sandbox, keeps a short history for
//  sparklines, and raises an alert in the notch when the Mac stays overloaded.
//

import Darwin
import Defaults
import Foundation
import IOKit.ps

extension Defaults.Keys {
    static let systemStatsTab = Key<Bool>("perchSystemStatsTab", default: true)
    static let systemStatsAlerts = Key<Bool>("perchSystemStatsAlerts", default: true)
}

@MainActor
final class SystemStatsMonitor: ObservableObject {
    static let shared = SystemStatsMonitor()

    static let historyLength = 40
    static let interval: TimeInterval = 2

    enum MemoryPressure { case normal, warning, critical }

    /// 0...1 across all cores.
    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var memoryPressure: MemoryPressure = .normal
    @Published private(set) var memoryHistory: [Double] = []
    /// Bytes per second.
    @Published private(set) var download: Double = 0
    @Published private(set) var upload: Double = 0
    @Published private(set) var networkHistory: [Double] = []
    /// Minutes of battery left while unplugged, if macOS has an estimate.
    @Published private(set) var batteryMinutesLeft: Int?

    private var timer: Timer?
    private var previousTicks: [UInt32]?
    private var previousNetwork: (bytesIn: UInt64, bytesOut: UInt64, time: Date)?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var highCPUSince: Date?
    private var lastAlert: Date = .distantPast

    private init() {}

    /// Call once at launch. Sampling is cheap enough to run all the time,
    /// which overload alerts need anyway.
    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer?.tolerance = 0.5

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let event = source?.data else { return }
                self.memoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
                if self.memoryPressure == .critical { self.alertMemory() }
            }
        }
        source.resume()
        pressureSource = source
    }

    // MARK: - Sampling

    private func sample() {
        if let usage = Self.cpuUsage(previous: &previousTicks) {
            cpu = usage
            Self.append(usage, to: &cpuHistory)
        }

        if let used = Self.memoryUsed() {
            memoryUsed = used
            Self.append(Double(used) / Double(max(1, memoryTotal)), to: &memoryHistory)
        }

        let now = Date()
        if let bytes = Self.networkBytes() {
            if let previous = previousNetwork {
                let seconds = max(0.1, now.timeIntervalSince(previous.time))
                // Counters are 32-bit per interface on some systems and can wrap.
                download = bytes.bytesIn >= previous.bytesIn ? Double(bytes.bytesIn - previous.bytesIn) / seconds : 0
                upload = bytes.bytesOut >= previous.bytesOut ? Double(bytes.bytesOut - previous.bytesOut) / seconds : 0
                Self.append(download + upload, to: &networkHistory)
            }
            previousNetwork = (bytes.bytesIn, bytes.bytesOut, now)
        }

        let estimate = IOPSGetTimeRemainingEstimate()
        batteryMinutesLeft = estimate > 0 ? Int(estimate / 60) : nil

        checkCPUAlert(now: now)
    }

    private static func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }

    // MARK: - Alerts

    private func checkCPUAlert(now: Date) {
        guard cpu > 0.85 else {
            highCPUSince = nil
            return
        }
        if highCPUSince == nil { highCPUSince = now }
        guard let since = highCPUSince, now.timeIntervalSince(since) >= 20 else { return }
        highCPUSince = nil
        guard Defaults[.systemStatsAlerts], now.timeIntervalSince(lastAlert) > 300 else { return }
        lastAlert = now

        let percent = Int((cpu * 100).rounded())
        Task {
            let top = await XPCHelperClient.shared.topCPUProcessName()
            PerchLiveActivity.shared.show(
                .init(symbol: "cpu", tint: .orange,
                      text: top.map { "CPU \(percent)% · \($0)" } ?? "CPU \(percent)%"))
        }
    }

    private func alertMemory() {
        let now = Date()
        guard Defaults[.systemStatsAlerts], now.timeIntervalSince(lastAlert) > 300 else { return }
        lastAlert = now
        PerchLiveActivity.shared.show(
            .init(symbol: "memorychip", tint: .red, text: String(localized: "Memory is almost full")))
    }

    // MARK: - Readers

    /// Overall CPU use since the previous call, from per-core tick counters.
    private static func cpuUsage(previous: inout [UInt32]?) -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let ticks = (0 ..< Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { previous = ticks }
        guard let old = previous, old.count == ticks.count else { return nil }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for core in 0 ..< Int(count) {
            for state in 0 ..< states {
                let i = core * states + state
                let delta = UInt64(ticks[i] &- old[i])
                total += delta
                if state != Int(CPU_STATE_IDLE) { busy += delta }
            }
        }
        return total > 0 ? Double(busy) / Double(total) : nil
    }

    /// Active + wired + compressed memory, which is what Activity Monitor calls "used".
    private static func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let used = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return used * page
    }

    /// Total bytes in/out across physical and VPN interfaces (loopback excluded).
    private static func networkBytes() -> (bytesIn: UInt64, bytesOut: UInt64)? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard !name.hasPrefix("lo") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            bytesIn += UInt64(stats.ifi_ibytes)
            bytesOut += UInt64(stats.ifi_obytes)
        }
        return (bytesIn, bytesOut)
    }
}

// MARK: - Formatting

enum SystemStatsFormat {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }
}

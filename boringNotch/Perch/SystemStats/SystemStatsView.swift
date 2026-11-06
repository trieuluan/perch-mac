//
//  SystemStatsView.swift
//  Perch
//
//  Notch tab with CPU, memory, network and battery at a glance.
//

import SwiftUI

struct SystemStatsView: View {
    @ObservedObject private var stats = SystemStatsMonitor.shared
    @ObservedObject private var battery = BatteryStatusViewModel.shared

    var body: some View {
        HStack(spacing: 8) {
            StatCard(
                title: "CPU", symbol: "cpu",
                value: "\(Int((stats.cpu * 100).rounded()))%",
                detail: nil,
                history: stats.cpuHistory, maxValue: 1,
                tint: Self.loadTint(stats.cpu))
            StatCard(
                title: String(localized: "Memory"), symbol: "memorychip",
                value: SystemStatsFormat.bytes(stats.memoryUsed),
                detail: String(localized: "of \(SystemStatsFormat.bytes(stats.memoryTotal))"),
                history: stats.memoryHistory, maxValue: 1,
                tint: stats.memoryPressure == .critical ? .red : stats.memoryPressure == .warning ? .orange : .teal)
            StatCard(
                title: String(localized: "Network"), symbol: "arrow.up.arrow.down",
                value: "↓ \(SystemStatsFormat.rate(stats.download))",
                detail: "↑ \(SystemStatsFormat.rate(stats.upload))",
                history: stats.networkHistory, maxValue: max(1, stats.networkHistory.max() ?? 1),
                tint: .blue)
            StatCard(
                title: String(localized: "Battery"), symbol: battery.isCharging ? "battery.100.bolt" : "battery.75",
                value: "\(Int(battery.levelBattery))%",
                detail: batteryDetail,
                history: [], maxValue: 1,
                tint: battery.levelBattery <= 20 && !battery.isPluggedIn ? .red : .green)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var batteryDetail: String {
        if battery.isCharging, battery.timeToFullCharge > 0 {
            return String(localized: "Full in \(Self.duration(battery.timeToFullCharge))")
        }
        if battery.isPluggedIn { return String(localized: "Plugged in") }
        if let minutes = stats.batteryMinutesLeft { return String(localized: "\(Self.duration(minutes)) left") }
        return String(localized: "Health \(Int(battery.maxCapacity))%")
    }

    private static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private static func loadTint(_ value: Double) -> Color {
        value > 0.85 ? .red : value > 0.6 ? .orange : .green
    }
}

private struct StatCard: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String?
    let history: [Double]
    let maxValue: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            Sparkline(values: history, maxValue: maxValue, tint: tint)
                .frame(height: 26)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }
}

/// Filled line chart of recent samples, newest on the right.
private struct Sparkline: View {
    let values: [Double]
    let maxValue: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                let points = values.enumerated().map { i, v in
                    CGPoint(
                        x: geo.size.width * CGFloat(i) / CGFloat(SystemStatsMonitor.historyLength - 1)
                            + geo.size.width * CGFloat(SystemStatsMonitor.historyLength - values.count)
                            / CGFloat(SystemStatsMonitor.historyLength - 1),
                        y: geo.size.height * (1 - CGFloat(min(1, v / max(maxValue, 0.0001)))))
                }
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            } else {
                // Battery (no history) or not enough samples yet: a simple level bar.
                Capsule().fill(Color.white.opacity(0.08))
                    .frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

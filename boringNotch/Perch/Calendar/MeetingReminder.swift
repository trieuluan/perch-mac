//
//  MeetingReminder.swift
//  Perch
//
//  Announces upcoming calendar events in the closed notch ("In 5 min · Standup",
//  then at one minute and at the start), announces reminders when they fall
//  due, and exposes the next meeting so the open notch can offer a Join button
//  for Meet / Zoom / Teams / Webex / Slack links.
//

import AppKit
import Defaults
import EventKit
import SwiftUI

extension Defaults.Keys {
    static let meetingAlerts = Key<Bool>("perchMeetingAlerts", default: true)
    /// Minutes before an event starts to show the first alert.
    static let meetingAlertLead = Key<Int>("perchMeetingAlertLead", default: 5)
}

@MainActor
final class MeetingReminder: ObservableObject {
    static let shared = MeetingReminder()

    /// The event to show a Join pill for: starting within `joinWindow` or in progress.
    @Published private(set) var nextMeeting: EventModel?
    private var preview: EventModel?

    private let service = CalendarService()
    private var upcoming: [EventModel] = []
    private var lastFetch: Date = .distantPast
    private var announced: Set<String> = []
    private var timer: Timer?
    private var storeObserver: NSObjectProtocol?

    private static let joinWindow: TimeInterval = 10 * 60

    private init() {}

    /// Call once at launch.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 2
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastFetch = .distantPast }
        }
        Task {
            // Don't announce events that were already under way at launch.
            await refresh()
            markPastStagesAnnounced()
            tick()
        }
    }

    // MARK: - Loop

    private func tick() {
        Task {
            if Date().timeIntervalSince(lastFetch) > 60 { await refresh() }
            announceDue()
            updateNextMeeting()
        }
    }

    private func refresh() async {
        lastFetch = Date()
        let now = Date()
        let ids = Array(CalendarManager.shared.selectedCalendarIDs)
        upcoming = await service.events(from: now.addingTimeInterval(-6 * 3600),
                                        to: now.addingTimeInterval(3 * 3600),
                                        calendars: ids)
            .filter(Self.isRelevant)
    }

    private static func isRelevant(_ event: EventModel) -> Bool {
        switch event.type {
        case .event(let attendance): return !event.isAllDay && attendance != .declined
        case .reminder(let completed): return !completed
        case .birthday: return false
        }
    }

    // MARK: - Alerts

    private enum Stage: String, CaseIterable { case lead, oneMinute, start }

    private func fireDate(_ stage: Stage, for event: EventModel) -> Date? {
        if event.type.isReminder { return stage == .start ? event.start : nil }
        switch stage {
        case .lead: return event.start.addingTimeInterval(-Double(Defaults[.meetingAlertLead]) * 60)
        case .oneMinute: return Defaults[.meetingAlertLead] > 1 ? event.start.addingTimeInterval(-60) : nil
        case .start: return event.start
        }
    }

    private func key(_ stage: Stage, _ event: EventModel) -> String {
        "\(event.id)|\(event.start.timeIntervalSince1970)|\(stage.rawValue)"
    }

    private func markPastStagesAnnounced() {
        let now = Date()
        for event in upcoming {
            for stage in Stage.allCases where (fireDate(stage, for: event) ?? .distantFuture) <= now {
                announced.insert(key(stage, event))
            }
        }
    }

    private func announceDue() {
        let now = Date()
        // Latest stage that has come due for each event; earlier ones are skipped
        // (e.g. waking the Mac 30 seconds before a meeting shows only "Starting").
        for event in upcoming {
            let due = Stage.allCases.filter { stage in
                guard let date = fireDate(stage, for: event) else { return false }
                // Ignore stages long past (missed while asleep).
                return date <= now && now.timeIntervalSince(date) < 90
            }
            guard let stage = due.last else { continue }
            let newKeys = due.map { key($0, event) }.filter { !announced.contains($0) }
            guard !newKeys.isEmpty else { continue }
            announced.formUnion(due.map { key($0, event) })
            if Defaults[.meetingAlerts], newKeys.contains(key(stage, event)) {
                announce(event, stage: stage)
            }
        }
    }

    private func announce(_ event: EventModel, stage: Stage) {
        let title = Self.short(event.title)
        let text: String
        let symbol: String
        if event.type.isReminder {
            symbol = "checklist"
            text = String(localized: "Due: \(title)")
        } else {
            symbol = MeetingLink.find(in: event) != nil ? "video.fill" : "calendar"
            switch stage {
            case .start:
                text = String(localized: "Starting: \(title)")
            default:
                let minutes = max(1, Int((event.start.timeIntervalSinceNow / 60).rounded()))
                text = String(localized: "In \(minutes) min · \(title)")
            }
        }
        PerchLiveActivity.shared.show(
            .init(symbol: symbol, tint: Color(nsColor: event.calendar.color), text: text),
            for: stage == .start ? 6 : 5)
    }

    private static func short(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 28 ? String(trimmed.prefix(26)) + "…" : trimmed
    }

    // MARK: - Join pill

    private func updateNextMeeting() {
        let now = Date()
        if let preview, preview.end > now {
            setNextMeeting(preview)
            return
        }
        preview = nil
        let candidate = upcoming
            .filter { $0.type.isEvent && $0.end > now && $0.start.timeIntervalSince(now) <= Self.joinWindow }
            // Prefer meetings with a link, then the soonest.
            .sorted { a, b in
                let la = MeetingLink.find(in: a) != nil, lb = MeetingLink.find(in: b) != nil
                return la != lb ? la : a.start < b.start
            }
            .first
        setNextMeeting(candidate)
    }

    private func setNextMeeting(_ event: EventModel?) {
        guard event != nextMeeting else { return }
        withAnimation(.smooth) { nextMeeting = event }
    }

    // MARK: - Preview (Settings)

    /// A sample meeting five minutes from now: shows the alert and the Join pill.
    func showPreview() {
        let start = Date().addingTimeInterval(5 * 60)
        let sample = EventModel(
            id: "perch-preview", start: start, end: start.addingTimeInterval(30 * 60),
            title: String(localized: "Daily standup"), location: nil,
            notes: "https://meet.google.com/abc-defg-hij", url: nil, isAllDay: false,
            type: .event(.accepted),
            calendar: CalendarModel(id: "perch-preview", account: "", title: "", color: .systemBlue,
                                    isSubscribed: false, isReminder: false),
            participants: [], timeZone: nil, hasRecurrenceRules: false, priority: nil)
        preview = sample
        announce(sample, stage: .lead)
        setNextMeeting(sample)
        // Keep the pill for a minute, enough to open the notch and look.
        Task {
            try? await Task.sleep(for: .seconds(60))
            if preview?.id == sample.id { preview = nil; updateNextMeeting() }
        }
    }
}

// MARK: - Meeting links

enum MeetingLink {
    enum Service { case meet, zoom, teams, webex, slack, facetime, other }

    static func find(in event: EventModel) -> (url: URL, service: Service)? {
        var candidates: [URL] = []
        if let url = event.url { candidates.append(url) }
        for text in [event.location, event.notes].compactMap({ $0 }) {
            candidates += urls(in: text)
        }
        for url in candidates {
            if let service = service(for: url) { return (url, service) }
        }
        return nil
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func urls(in text: String) -> [URL] {
        guard let detector else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
    }

    private static func service(for url: URL) -> Service? {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host == "meet.google.com" { return .meet }
        if host.hasSuffix("zoom.us") || host.hasSuffix("zoom.com"), path.contains("/j/") || path.contains("/my/") || path.contains("/w/") { return .zoom }
        if host.hasPrefix("teams.microsoft.com") || host == "teams.live.com" || host.hasSuffix("teams.microsoft.us") { return .teams }
        if host.hasSuffix("webex.com") { return .webex }
        if host == "app.slack.com", path.contains("huddle") { return .slack }
        if host == "facetime.apple.com" { return .facetime }
        if url.scheme == "zoommtg" || url.scheme == "msteams" { return .other }
        return nil
    }

    /// Opens the meeting, in the native app for Zoom and Teams when installed.
    static func open(_ link: (url: URL, service: Service)) {
        NSWorkspace.shared.open(nativeURL(for: link) ?? link.url)
    }

    private static func nativeURL(for link: (url: URL, service: Service)) -> URL? {
        switch link.service {
        case .zoom:
            guard appInstalled(scheme: "zoommtg"),
                  let components = URLComponents(url: link.url, resolvingAgainstBaseURL: false),
                  let range = link.url.path.range(of: "/j/") else { return nil }
            let number = link.url.path[range.upperBound...].prefix { $0.isNumber }
            guard !number.isEmpty else { return nil }
            var native = URLComponents()
            native.scheme = "zoommtg"
            native.host = components.host
            native.path = "/join"
            native.queryItems = [URLQueryItem(name: "action", value: "join"),
                                 URLQueryItem(name: "confno", value: String(number))]
                + (components.queryItems?.filter { $0.name == "pwd" } ?? [])
            return native.url
        case .teams:
            guard appInstalled(scheme: "msteams") else { return nil }
            return URL(string: link.url.absoluteString.replacingOccurrences(of: "https://", with: "msteams://"))
        default:
            return nil
        }
    }

    private static func appInstalled(scheme: String) -> Bool {
        guard let probe = URL(string: "\(scheme)://") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    static func name(of service: Service) -> String {
        switch service {
        case .meet: return "Google Meet"
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .webex: return "Webex"
        case .slack: return "Slack"
        case .facetime: return "FaceTime"
        case .other: return ""
        }
    }
}

// MARK: - Join pill (open notch header)

struct MeetingJoinPill: View {
    @ObservedObject private var reminder = MeetingReminder.shared

    var body: some View {
        if let event = reminder.nextMeeting {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                pill(for: event, now: context.date)
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    private func pill(for event: EventModel, now: Date) -> some View {
        let link = MeetingLink.find(in: event)
        let tint = Color(nsColor: event.calendar.color)
        return Button {
            if let link {
                MeetingLink.open(link)
            } else if let url = event.calendarAppURL() {
                NSWorkspace.shared.open(url)
            }
        } label: {
            // The header beside the notch is narrow (gear, battery), so the pill
            // is just an icon and the time; the title is in the tooltip.
            HStack(spacing: 4) {
                Image(systemName: link != nil ? "video.fill" : "calendar")
                    .font(.system(size: 10, weight: .semibold))
                Text(timeLabel(event, now: now))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(link != nil ? Color.green.opacity(0.85) : tint.opacity(0.6)))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help([link != nil ? String(localized: "Join") : String(localized: "Open"),
               event.title, link.map { MeetingLink.name(of: $0.service) }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
    }

    private func timeLabel(_ event: EventModel, now: Date) -> String {
        let seconds = event.start.timeIntervalSince(now)
        if seconds <= 30 { return String(localized: "Now") }
        return String(localized: "\(max(1, Int((seconds / 60).rounded()))) min")
    }
}

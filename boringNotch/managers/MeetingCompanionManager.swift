//
//  MeetingCompanionManager.swift
//  boringNotch
//
//  Lightweight calendar meeting companion for upcoming/in-progress video calls.
//

import AppKit
import Combine
import Defaults
@preconcurrency import EventKit
import Foundation

struct MeetingCompanionSnapshot: Equatable {
    enum State: Equatable {
        case none
        case upcoming(minutesUntilStart: Int)
        case live(minutesRemaining: Int)
    }

    let title: String
    let start: Date
    let end: Date
    let joinURL: URL?
    let calendarURL: URL?
    let location: String?
    let state: State
    let capturedAt: Date

    var isActive: Bool {
        state != .none
    }

    var statusText: String {
        switch state {
        case .none:
            return "No meeting"
        case .upcoming(let minutes):
            if minutes <= 0 { return "Starting now" }
            return "In \(minutes)m"
        case .live(let remaining):
            if remaining <= 0 { return "Live now" }
            return "\(remaining)m left"
        }
    }

    var compactTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Meeting" : trimmed
    }

    static let empty = MeetingCompanionSnapshot(
        title: "",
        start: .distantFuture,
        end: .distantFuture,
        joinURL: nil,
        calendarURL: nil,
        location: nil,
        state: .none,
        capturedAt: Date()
    )
}

@MainActor
final class MeetingCompanionManager: ObservableObject {
    static let shared = MeetingCompanionManager()

    @Published private(set) var snapshot: MeetingCompanionSnapshot = .empty
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var lastError: String?

    private let store = EKEventStore()
    private var timer: Timer?
    private var settingsCancellables: Set<AnyCancellable> = []

    private init() {
        Defaults.publisher(.meetingCompanionEnabled)
            .sink { [weak self] change in
                Task { @MainActor in
                    change.newValue ? self?.start() : self?.stop()
                }
            }
            .store(in: &settingsCancellables)

        if Defaults[.meetingCompanionEnabled] {
            start()
        }
    }

    func start() {
        guard timer == nil else {
            refreshNow()
            return
        }
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        snapshot = .empty
    }

    func requestAccess() {
        Task { @MainActor in
            do {
                let granted: Bool
                if #available(macOS 14.0, *) {
                    granted = try await store.requestFullAccessToEvents()
                } else {
                    granted = try await store.requestAccess(to: .event)
                }
                authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                if granted { refreshNow() }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func refreshNow() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard Defaults[.meetingCompanionEnabled] else { return }
        guard hasCalendarAccess else {
            snapshot = .empty
            return
        }

        let now = Date()
        let lead = max(1, Defaults[.meetingCompanionLeadTimeMinutes])
        let start = now.addingTimeInterval(-10 * 60)
        let end = now.addingTimeInterval(TimeInterval(lead + 60) * 60)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .filter { $0.endDate > now }
            .filter { event in
                event.startDate <= now.addingTimeInterval(TimeInterval(lead) * 60) || event.startDate <= now
            }
            .filter { event in
                Self.extractJoinURL(from: event) != nil || event.hasAttendees || (event.location?.isEmpty == false)
            }
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate { return lhs.title < rhs.title }
                return lhs.startDate < rhs.startDate
            }

        guard let event = events.first else {
            snapshot = .empty
            return
        }

        let state: MeetingCompanionSnapshot.State
        if event.startDate <= now && event.endDate > now {
            let remaining = max(0, Int(ceil(event.endDate.timeIntervalSince(now) / 60)))
            state = .live(minutesRemaining: remaining)
        } else {
            let minutes = max(0, Int(ceil(event.startDate.timeIntervalSince(now) / 60)))
            state = .upcoming(minutesUntilStart: minutes)
        }

        snapshot = MeetingCompanionSnapshot(
            title: event.title ?? "Meeting",
            start: event.startDate,
            end: event.endDate,
            joinURL: Self.extractJoinURL(from: event),
            calendarURL: calendarURL(for: event),
            location: event.location,
            state: state,
            capturedAt: now
        )
    }

    func joinMeeting() {
        if let url = snapshot.joinURL {
            NSWorkspace.shared.open(url)
        } else if let url = snapshot.calendarURL {
            NSWorkspace.shared.open(url)
        }
    }

    func openCalendarEvent() {
        guard let url = snapshot.calendarURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var hasCalendarAccess: Bool {
        if #available(macOS 14.0, *) {
            return authorizationStatus == .fullAccess
        }
        return authorizationStatus == .authorized
    }

    private func calendarURL(for event: EKEvent) -> URL? {
        guard let id = event.eventIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "ical://ekevent/\(id)?method=show&options=more")
    }

    private static func extractJoinURL(from event: EKEvent) -> URL? {
        if let url = event.url, isMeetingURL(url) { return url }
        let haystack = [event.location, event.notes, event.url?.absoluteString]
            .compactMap { $0 }
            .joined(separator: "\n")
        return firstMeetingURL(in: haystack)
    }

    private static func firstMeetingURL(in text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let pattern = #"https?://[^\s<>\"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        for match in matches {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            var raw = String(text[swiftRange])
            raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: ").,;]\n\t "))
            guard let url = URL(string: raw), isMeetingURL(url) else { continue }
            return url
        }
        return nil
    }

    private static func isMeetingURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        return host.contains("zoom.us")
            || host.contains("meet.google.com")
            || host.contains("teams.microsoft.com")
            || host.contains("join.skype.com")
            || host.contains("webex.com")
            || host.contains("whereby.com")
            || path.contains("/meet/")
    }
}

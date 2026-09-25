import EventKit
import SwiftUI

/// Settings → Meetings → Choose calendars…: every calendar on this Mac by
/// name, grouped by account, each with a switch. Switching one off keeps it
/// out of Today's "up next" and out of naming recordings.
struct CalendarPickerSheet: View {
    @Environment(MeetingsAppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [MeetingCalendars.Group] = []
    private let upcoming = UpcomingMeetings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Calendars").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            content
        }
        .frame(width: 460, height: 520)
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch upcoming.access {
        case .granted:
            Form {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                            row(calendar)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .unknown:
            message("Dictator Meetings needs calendar access to list your calendars.") {
                Button("Connect Calendar") {
                    Task {
                        await upcoming.requestAccess(settings: state.settings)
                        await reload()
                    }
                }
            }
        case .denied:
            message("Calendar access is off for Dictator Meetings in System Settings → Privacy & Security → Calendars.") {
                Button("Open Settings") { upcoming.openCalendarPrivacySettings() }
            }
        case .off:
            message("Turn on “Match meetings to calendar events” to choose calendars.") { EmptyView() }
        }
    }

    private func row(_ calendar: EKCalendar) -> some View {
        Toggle(isOn: Binding(
            get: { !state.settings.meetingExcludedCalendarIDs.contains(calendar.calendarIdentifier) },
            set: { setIncluded($0, calendar.calendarIdentifier) }
        )) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(cgColor: calendar.cgColor))
                    .frame(width: 10, height: 10)
                Text(calendar.title)
            }
        }
    }

    private func message(_ text: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setIncluded(_ included: Bool, _ id: String) {
        var excluded = state.settings.meetingExcludedCalendarIDs.filter { $0 != id }
        if !included { excluded.append(id) }
        state.settings.meetingExcludedCalendarIDs = excluded
        state.save()
        Task { await upcoming.refresh(settings: state.settings) }
    }

    private func reload() async {
        await upcoming.refresh(settings: state.settings)
        groups = upcoming.access == .granted ? MeetingCalendars.grouped(in: upcoming.store) : []
    }
}

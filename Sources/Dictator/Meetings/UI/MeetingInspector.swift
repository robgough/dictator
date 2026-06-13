import SwiftUI

/// Trailing Details inspector for a finished meeting. Consolidates the
/// per-meeting metadata and actions that used to be scattered across the
/// transcript and notes headers into one stable pane:
///
///   • About    — date, duration, how it was captured, where the audio lives.
///   • Speakers — the canonical home for renaming / recolouring / merging
///                speakers (reuses `EditableSpeakerChip` from TranscriptView).
///   • Notes    — the on-demand notes generation control (`NotesGenerationControls`).
///   • Actions  — re-process the recording.
///
/// Hosted via `.inspector(isPresented:)` on `MeetingDetailView`, and only
/// offered for non-live, non-processing meetings (see `MeetingDetailView`) so
/// it never squeezes the live-recording layout. Everything here drives the
/// same `session` methods the old inline controls did — this is a re-housing,
/// not new behaviour. The pane is chrome, so it reads quietly; the reading
/// surfaces stay in the detail pane.
struct MeetingInspector: View {
    @Environment(AppState.self) private var state
    @Bindable var session: MeetingSession
    /// Captured screen keyframes, loaded from the meeting's local folder. nil
    /// until the `.task` reads `index.json` (and stays nil when none exist).
    @State private var screenshotIndex: MeetingScreenshotIndex?

    private var meta: MeetingMeta { session.meta }

    /// The "Context" section: which app hosted the call and the calendar
    /// event the recording matched — subject, attendees, companies.
    @ViewBuilder
    private var contextSection: some View {
        if meta.sourceApp != nil || meta.calendar != nil {
            Section("Context") {
                if let app = meta.sourceApp {
                    LabeledContent("App", value: app.name)
                }
                if let calendar = meta.calendar {
                    LabeledContent("Event") {
                        Text(calendar.title)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Scheduled", value: Self.scheduledSpan(calendar))
                    if !calendar.attendees.isEmpty {
                        LabeledContent("Attendees") {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(Array(calendar.attendees.enumerated()), id: \.offset) { _, attendee in
                                    Text(attendee.name ?? attendee.email ?? "—")
                                        .help(attendee.email ?? "")
                                }
                            }
                        }
                    }
                    let companies = calendar.companyDomains
                    if !companies.isEmpty {
                        LabeledContent("Companies", value: companies.joined(separator: ", "))
                    }
                }
            }
        }
    }

    private static func scheduledSpan(_ calendar: MeetingCalendarContext) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: calendar.startDate))–\(f.string(from: calendar.endDate))"
    }

    var body: some View {
        Form {
            aboutSection
            contextSection
            screenshotsSection
            speakersSection
            notesSection
            actionsSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: session.id) {
            screenshotIndex = (meta.screenshotCount ?? 0) > 0
                ? MeetingStorage.readScreenshotIndex(for: session.id)
                : nil
        }
    }

    /// Captured shared-screen keyframes as a horizontal thumbnail strip. Each
    /// opens full-size on click; the timestamp is the offset into the recording.
    @ViewBuilder
    private var screenshotsSection: some View {
        if let index = screenshotIndex, !index.screenshots.isEmpty {
            Section("Shared screens") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(index.screenshots) { shot in
                            ScreenshotThumbnail(
                                url: MeetingStorage.screenshotsFolder(for: session.id)
                                    .appendingPathComponent(shot.filename),
                                offsetSeconds: shot.offsetSeconds
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Date", value: Self.dateFormatter.string(from: meta.createdAt))
            if meta.durationSeconds > 0 {
                LabeledContent("Length", value: Self.formatDuration(meta.durationSeconds))
            }
            LabeledContent("Captured") {
                Text(captureDescription)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Audio") {
                Text(audioStatus.text)
                    .foregroundStyle(audioStatus.muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .multilineTextAlignment(.trailing)
            }
            Label("Notes and the transcript sync to your Macs; the audio stays on the Mac that recorded it.", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "Live recording" / "Listen-only recording" / "Imported from foo.m4a".
    private var captureDescription: String {
        switch meta.source {
        case .fileImport:
            if let name = meta.sourceFilename { return "Imported from \(name)" }
            return "Imported audio file"
        case .live:
            // A live capture with no mic track means the user listened but
            // didn't speak — surface it so the missing "Me" reads as intentional.
            return meta.audioFiles.mic == nil ? "Listen-only recording" : "Live recording"
        }
    }

    /// Where the recording lives now — drives a quiet hint about whether the
    /// meeting can still be re-processed or played.
    private var audioStatus: (text: String, muted: Bool) {
        let micRef = meta.audioFiles.mic
        let sysRef = meta.audioFiles.system
        // No references at all → the retention sweep pruned the audio (or it was
        // never kept); the transcript remains.
        if micRef == nil, sysRef == nil {
            return ("Removed — transcript kept", true)
        }
        // References exist; check whether the files are actually on this Mac
        // (they stay on the recording Mac and don't sync).
        let fm = FileManager.default
        let micHere = micRef != nil && fm.fileExists(atPath: MeetingStorage.micURL(for: meta.id).path)
        let sysHere = sysRef != nil && fm.fileExists(atPath: MeetingStorage.systemURL(for: meta.id).path)
        if micHere || sysHere { return ("On this Mac", false) }
        return ("On the Mac that recorded it", true)
    }

    // MARK: - Speakers

    @ViewBuilder
    private var speakersSection: some View {
        if !meta.speakers.isEmpty {
            Section {
                ForEach(meta.speakers, id: \.id) { speaker in
                    HStack {
                        EditableSpeakerChip(speaker: speaker, session: session, allSpeakers: meta.speakers)
                        Spacer(minLength: 0)
                    }
                }
                Text("Click a speaker to rename or recolour them; right-click to merge two speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Speakers")
            }
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        Section("Notes") {
            LabeledContent("Status") {
                Text(notesStatus)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                NotesGenerationControls(session: session)
                Spacer(minLength: 0)
            }
            Text("Notes are written on demand. Use the menu to pick a style or tune the run for this meeting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var notesStatus: String {
        if case .summarising = session.state { return "Writing…" }
        if meta.notes?.isFinal == true || meta.summary != nil {
            return "Written"
        }
        if meta.notes != nil { return "Live draft — not final yet" }
        return "Not generated yet"
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        if hasAnyAudioOnDisk {
            Section("Recording") {
                Button {
                    Task { await session.runProcessor(parakeetModelID: state.settings.parakeetModelID) }
                } label: {
                    Label("Re-process", systemImage: "arrow.clockwise")
                }
                .disabled(session.state.isProcessing)
                .help("Re-run transcription and diarization from the recorded audio. Useful after a fix that improved transcript quality.")
            }
        }
    }

    /// True when at least one audio track is still present on disk — pruned
    /// meetings can't be re-transcribed, so Re-process is hidden for them.
    private var hasAnyAudioOnDisk: Bool {
        let fm = FileManager.default
        let micPresent = meta.audioFiles.mic != nil
            && fm.fileExists(atPath: MeetingStorage.micURL(for: meta.id).path)
        let sysPresent = meta.audioFiles.system != nil
            && fm.fileExists(atPath: MeetingStorage.systemURL(for: meta.id).path)
        return micPresent || sysPresent
    }

    // MARK: - Formatters

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// One screen keyframe in the inspector filmstrip: a thumbnail with its
/// timeline offset, opening the full HEIC in the system viewer on click. Loads
/// the image lazily off the main actor so a strip of them doesn't stutter the
/// inspector.
private struct ScreenshotThumbnail: View {
    let url: URL
    let offsetSeconds: Double

    @State private var thumbnail: NSImage?

    private static let thumbHeight: CGFloat = 64

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.12))
                        .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                }
            }
            .frame(width: Self.thumbHeight * 16 / 9, height: Self.thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.25)))

            Text(Self.timestamp(offsetSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .help("Captured at \(Self.timestamp(offsetSeconds)) — click to open full size")
        .task(id: url) {
            // NSImage loads (and decodes) on a background queue; hand the ready
            // image back to the main actor for display.
            let loaded = await Task.detached(priority: .utility) {
                NSImage(contentsOf: url)
            }.value
            thumbnail = loaded
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

import SwiftUI
import AppKit

/// The three steps between a finished recording and notes you can send:
/// who spoke, the notes, and sending them. Shown along the top of the Notes
/// tab until the notes exist, and as the send bar just after they're written.
struct ReviewStepper: View {
    enum Step: Int { case speakers = 1, notes, send }
    let current: Step

    var body: some View {
        HStack(spacing: 10) {
            step(.speakers, "Who spoke")
            connector
            step(.notes, "Notes")
            connector
            step(.send, "Send")
        }
        .font(.callout)
    }

    private func step(_ step: Step, _ title: String) -> some View {
        let done = step.rawValue < current.rawValue
        let active = step == current
        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(active ? Color.accentColor : (done ? Color.green : Color.clear))
                    .overlay(Circle().strokeBorder(active || done ? Color.clear : Color.secondary.opacity(0.6), lineWidth: 1.5))
                if done {
                    Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue)").font(.caption.weight(.semibold))
                        .foregroundStyle(active ? .white : .secondary)
                }
            }
            .frame(width: 20, height: 20)
            Text(title)
                .fontWeight(active ? .semibold : .regular)
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    private var connector: some View {
        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 26, height: 1)
    }
}

/// Step one: who was talking. Each voice gets the longest thing it said and a
/// play button, so a guessed name can be checked by ear before the notes are
/// written with it — names in the notes come from here.
struct SpeakerReview: View {
    @Bindable var session: MeetingSession
    let transcript: MeetingTranscript?
    /// Plays the recording from a time, staying on this tab. Nil when this
    /// Mac doesn't have the audio.
    let onPlay: ((Double) -> Void)?
    let onDone: () -> Void

    @State private var renamingID: String?
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Who was talking?")
                    .font(.title3.weight(.semibold))
                Text(intro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(session.meta.speakers, id: \.id) { speaker in
                row(speaker)
            }
            HStack {
                if needsCheck > 0 {
                    Text(needsCheck == 1 ? "1 name still to check" : "\(needsCheck) names still to check")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onDone) {
                    HStack(spacing: 6) {
                        Text(needsCheck > 0 ? "Skip to the notes" : "Next: the notes")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(needsCheck > 0 ? .gray : .accentColor)
                .controlSize(.large)
            }
            .padding(.top, 4)
        }
    }

    private var intro: String {
        let count = session.meta.speakers.count
        return "\(count == 1 ? "One voice" : "\(count) voices"). The notes will use these names, so it's worth a moment."
    }

    private var needsCheck: Int {
        session.meta.speakers.filter(Self.needsCheck).count
    }

    static func needsCheck(_ speaker: MeetingMeta.Speaker) -> Bool {
        guard !speaker.isMe else { return false }
        return speaker.nameInferred || isPlaceholder(speaker.displayName)
    }

    static func isPlaceholder(_ name: String) -> Bool {
        name == "Other" || name == "Them" || name.hasPrefix("Speaker ")
    }

    @ViewBuilder
    private func row(_ speaker: MeetingMeta.Speaker) -> some View {
        let sample = longestSegment(for: speaker.id)
        let unsure = Self.needsCheck(speaker)
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(Color(meetingHex: speaker.colorHex) ?? .accentColor)
                .frame(width: 34, height: 34)
                .overlay(Text(initials(speaker.displayName)).font(.caption.weight(.bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                if renamingID == speaker.id {
                    HStack(spacing: 6) {
                        TextField("Name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit { commitRename(speaker.id) }
                        if !suggestions.isEmpty {
                            Menu("Suggestions") {
                                ForEach(suggestions, id: \.self) { name in
                                    Button(name) { draftName = name; commitRename(speaker.id) }
                                }
                            }
                            .fixedSize()
                        }
                        Button("Save") { commitRename(speaker.id) }
                        Button("Cancel") { renamingID = nil }
                            .buttonStyle(.link)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(speaker.isMe ? "You" : speaker.displayName)
                            .font(.body.weight(.semibold))
                        if unsure && !Self.isPlaceholder(speaker.displayName) {
                            Text("guessed")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                        }
                    }
                }
                if let sample {
                    Text("“\(sample.text)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let sample, let onPlay {
                Button { onPlay(sample.start) } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.bordered)
                .help("Hear this voice")
            }
            if renamingID != speaker.id {
                if speaker.isMe {
                    confirmed
                } else if unsure {
                    HStack(spacing: 6) {
                        if !Self.isPlaceholder(speaker.displayName) {
                            Button("That's right") { session.confirmSpeaker(id: speaker.id) }
                        }
                        Button(Self.isPlaceholder(speaker.displayName) ? "Name…" : "Someone else…") {
                            draftName = Self.isPlaceholder(speaker.displayName) ? "" : speaker.displayName
                            renamingID = speaker.id
                        }
                    }
                } else {
                    Menu {
                        Button("Rename…") {
                            draftName = speaker.displayName
                            renamingID = speaker.id
                        }
                    } label: {
                        confirmed
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .padding(14)
        .notesSurface()
    }

    private var confirmed: some View {
        Label("Confirmed", systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.green)
    }

    private func commitRename(_ id: String) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { session.renameSpeaker(id: id, to: name) }
        renamingID = nil
    }

    /// Calendar attendees who aren't already a speaker here — the likeliest
    /// names for an unnamed voice.
    private var suggestions: [String] {
        let taken = Set(session.meta.speakers.map { $0.displayName.lowercased() })
        return (session.meta.calendar?.attendees ?? [])
            .compactMap { $0.name }
            .filter { !$0.isEmpty && !taken.contains($0.lowercased()) }
    }

    private func longestSegment(for speakerID: String) -> MeetingTranscriptSegment? {
        transcript?.segments
            .filter { $0.speakerId == speakerID && !$0.text.isEmpty }
            .max { ($0.end - $0.start) < ($1.end - $1.start) }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// Step three, shown once just after the notes are written: get them to the
/// people who were there.
struct SendBar: View {
    let title: String
    let markdown: String
    let onDismiss: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Notes written").font(.body.weight(.semibold))
                Text("Send them while the meeting's still fresh.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("# \(title)\n\n\(markdown)", forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy notes", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            ShareLink(item: "\(title)\n\n\(markdown)", subject: Text(title)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Done")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: MeetingMetrics.cardCornerRadius, style: .continuous).fill(Color.green.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: MeetingMetrics.cardCornerRadius, style: .continuous).strokeBorder(Color.green.opacity(0.3)))
    }
}

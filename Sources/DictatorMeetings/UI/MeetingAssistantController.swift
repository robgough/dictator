import Foundation
import Observation

/// One message in a meeting's assistant conversation.
struct MeetingChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    let role: Role
    var text: String
    var date = Date()
    /// A complete rewrite of the notes the assistant proposed, when it was
    /// asked to change them. Applied only when the user says so.
    var proposedNotes: String?
    var applied = false
}

/// The meeting assistant: a conversation about one meeting, beside it.
///
/// It used to be one question and one answer in a sheet, forgotten when the
/// sheet closed. Now it's a thread, saved with the meeting, so a follow-up
/// ("and what did Tom say about that?") has the question before it, and the
/// conversation is still there next time. The model reads the meeting fresh
/// on every turn — notes, the user's pad, and the transcript, whole or the
/// parts that bear on the question — which is what lets a question go past
/// what the notes happened to keep.
///
/// Every provider (Dictator's model over the socket, a local model, Apple's,
/// a cloud one) takes a single system + user pair, so the conversation so far
/// travels in the user message. Owned by `MeetingDetailView`, and registered
/// with `MeetingsAppState.meetingAssistant` so ⌘⌥A can reach it.
@MainActor
@Observable
final class MeetingAssistantController {
    @ObservationIgnored private(set) weak var session: MeetingSession?

    private(set) var messages: [MeetingChatMessage] = []
    var draft = ""
    var isRunning = false
    var errorText: String?
    var isListening = false
    var isTranscribing = false
    /// Bumped to ask the meeting view to show the Ask panel.
    private(set) var openRequests = 0
    /// Bumped to put the cursor in the message box.
    private(set) var focusRequests = 0

    @ObservationIgnored private var recorder: AudioRecorder?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    func bind(session: MeetingSession) {
        guard self.session !== session else { return }
        runTask?.cancel()
        self.session = session
        messages = MeetingStorage.readAssistantChat(for: session.id)
        draft = ""
        errorText = nil
        isRunning = false
    }

    /// Whether there's a meeting to talk about and a model to talk with.
    var canRun: Bool {
        guard let session else { return false }
        let hasContent = session.meta.notes != nil || session.meta.durationSeconds > 0
        return hasContent && ProviderRegistry.shared.provider(for: .final) != nil
    }

    var providerName: String? { ProviderRegistry.shared.provider(for: .final)?.displayName }

    // MARK: - Entry points

    /// Show the conversation and put the cursor in the box (the Assistant
    /// button on the notes).
    func present() {
        openRequests += 1
        focusRequests += 1
    }

    func send(_ text: String? = nil) {
        let question = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isRunning else { return }
        draft = ""
        messages.append(MeetingChatMessage(role: .user, text: question))
        persist()
        run()
    }

    func apply(_ message: MeetingChatMessage) {
        guard let notes = message.proposedNotes, let session,
              let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        session.updateNotesMarkdown(notes)
        messages[index].applied = true
        persist()
    }

    func clear() {
        runTask?.cancel()
        isRunning = false
        messages = []
        errorText = nil
        persist()
    }

    /// ⌘⌥A (Assistant ▸ Ask About This Meeting). A menu command fires once,
    /// so it toggles: open and listen, then stop and send.
    func toggleFromCommand() {
        if isListening {
            stopListening(thenSend: true)
        } else if !isRunning, !isTranscribing, canRun {
            present()
            startListening()
        }
    }

    /// The composer's mic button: dictate into the box, send by hand.
    func toggleListening() {
        isListening ? stopListening(thenSend: false) : startListening()
    }

    /// Stop the microphone when the panel goes away.
    func teardown() {
        _ = recorder?.stop()
        recorder = nil
        isListening = false
    }

    // MARK: - Voice

    private func startListening() {
        let r = AudioRecorder()
        r.onStartFailed = { [weak self] _ in
            self?.errorText = "Couldn't access the microphone. Check Privacy & Security → Microphone."
            self?.isListening = false
            self?.recorder = nil
        }
        recorder = r
        errorText = nil
        isListening = true
        r.start()
    }

    private func stopListening(thenSend: Bool) {
        guard let r = recorder else { return }
        isListening = false
        recorder = nil
        let samples = r.stop()
        guard samples.count > 1600 else { return }   // < ~0.1s → nothing useful
        isTranscribing = true
        // Parakeet only: Meetings never ships the Whisper path.
        let modelID = MeetingsAppState.shared.settings.parakeetModelID
        let asr: any ASREngine = ParakeetServiceHolder.shared
        Task {
            do {
                try await asr.ensureLoaded(modelID: modelID)
                let text = try await asr.transcribe(samples: samples, modelID: modelID)
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { draft = draft.isEmpty ? t : draft + " " + t }
            } catch {
                errorText = "Couldn't transcribe: \(error.localizedDescription)"
            }
            isTranscribing = false
            if thenSend { send() }
        }
    }

    // MARK: - The model call

    private func run() {
        guard let session else { return }
        guard let provider = ProviderRegistry.shared.provider(for: .final) else {
            errorText = ProviderRegistry.shared.requirementMessage
                ?? "Pick a model for the final notes on the Providers tab to use the assistant."
            return
        }
        isRunning = true
        errorText = nil
        let meta = session.meta
        let pad = session.padText
        let history = messages
        let userName = MeetingsAppState.shared.settings.userName
        let maxReply = provider.isLocal ? min(provider.maxOutputTokens, 3_000) : provider.replyCap
        let budget = max(6_000, (provider.contextWindowTokens - maxReply) * 3 - 3_000)
        runTask = Task {
            let transcript = await Task.detached { MeetingStorage.readTranscript(for: meta.id) }.value
            let prompt = MeetingChatPrompt.build(
                meta: meta, transcript: transcript, pad: pad, history: history,
                userName: userName, budgetCharacters: budget)
            do {
                try await provider.prepare()
                let reply = try await provider.complete(
                    system: prompt.system, user: prompt.user,
                    maxTokens: maxReply, temperature: 0.3,
                    cancellation: { Task.isCancelled })
                guard !Task.isCancelled else { return }
                let parsed = MeetingChatPrompt.parse(reply)
                messages.append(MeetingChatMessage(role: .assistant, text: parsed.text, proposedNotes: parsed.notes))
                persist()
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
            isRunning = false
        }
    }

    private func persist() {
        guard let id = session?.id else { return }
        MeetingStorage.writeAssistantChat(messages, for: id)
    }
}

/// What the model is given for one turn of the meeting conversation.
enum MeetingChatPrompt {
    static func build(
        meta: MeetingMeta,
        transcript: MeetingTranscript?,
        pad: String,
        history: [MeetingChatMessage],
        userName: String,
        budgetCharacters: Int
    ) -> (system: String, user: String) {
        let me = userName.isEmpty ? "the user" : userName
        let system = """
        You are \(me)'s assistant for one meeting they recorded, "\(meta.title)". Everything you \
        know about it is below: the notes, their own pad, and the transcript.

        Answer from the meeting. When you point at something said, give its time like [12:34]. \
        If the meeting doesn't say, say so plainly — never fill a gap with what meetings like this \
        usually contain. Be brief: a sentence or a few bullets unless you're asked for more. \
        Plain Markdown.

        If \(me) asks you to change, add to or rewrite the notes, say in one sentence what you \
        changed, then give the COMPLETE revised notes between <notes> and </notes>. Do that only \
        for a change to the notes. Drafting something from the meeting — an email, a message, a \
        summary for someone — is not a change to the notes: just write it.
        """

        let names = Dictionary(meta.speakers.map { ($0.id, $0.isMe ? "\($0.displayName) (\(me))" : $0.displayName) },
                               uniquingKeysWith: { a, _ in a })
        var header = "MEETING: \(meta.title) — \(meta.createdAt.formatted(date: .complete, time: .shortened))"
        if meta.durationSeconds > 0 { header += ", \(Int((meta.durationSeconds / 60).rounded())) minutes" }
        let people = meta.speakers.filter { !$0.isMe }.map(\.displayName)
        if !people.isEmpty { header += "\nWith: \(people.joined(separator: ", "))" }

        var sections = [header]
        if let notes = meta.notes, !notes.markdown.isEmpty {
            sections.append(notes.isFinal
                ? "NOTES:\n\(notes.markdown)"
                : "ROUGH NOTES (written live during the call; speakers are only \"Me\" and \"Them\"):\n\(notes.markdown)")
        }
        let padText = pad.trimmingCharacters(in: .whitespacesAndNewlines)
        if !padText.isEmpty { sections.append("\(me.uppercased())'S OWN NOTES (treat as fact):\n\(padText)") }

        let conversation = history.dropLast().suffix(8).map { message -> String in
            let who = message.role == .user ? "User" : "Assistant"
            var text = message.text
            if text.count > 1500 { text = String(text.prefix(1500)) + "…" }
            if message.proposedNotes != nil { text += " [proposed revised notes\(message.applied ? ", applied" : "")]" }
            return "\(who): \(text)"
        }
        let question = history.last?.text ?? ""

        var tail = ""
        if !conversation.isEmpty { tail += "CONVERSATION SO FAR:\n\(conversation.joined(separator: "\n"))\n\n" }
        tail += "QUESTION: \(question)"

        let used = sections.joined(separator: "\n\n").count + tail.count + system.count
        if let transcript, !transcript.segments.isEmpty {
            let lines = transcript.segments.map { seg in
                (seg.start, "[\(clock(seg.start))] \(names[seg.speakerId] ?? seg.speakerId): \(seg.text)")
            }
            let focus = history.filter { $0.role == .user }.suffix(2).map(\.text).joined(separator: " ")
            sections.append(transcriptSection(lines, focus: focus, budget: budgetCharacters - used))
        }
        return (system, sections.joined(separator: "\n\n") + "\n\n" + tail)
    }

    /// The whole transcript when it fits; otherwise the lines that share the
    /// most words with the question, each with the line either side, in
    /// time order, with "…" where lines were left out.
    static func transcriptSection(_ lines: [(Double, String)], focus: String, budget: Int) -> String {
        let total = lines.reduce(0) { $0 + $1.1.count + 1 }
        if total <= budget {
            return "TRANSCRIPT:\n" + lines.map(\.1).joined(separator: "\n")
        }
        let terms = Set(focus.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 })
        let scored = lines.enumerated().map { index, line -> (Int, Int) in
            let lower = line.1.lowercased()
            return (index, terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) })
        }
        var chosen = Set<Int>()
        var size = 0
        for (index, score) in scored.sorted(by: { $0.1 > $1.1 }) where score > 0 {
            for i in max(0, index - 1)...min(lines.count - 1, index + 1) where !chosen.contains(i) {
                let cost = lines[i].1.count + 1
                guard size + cost <= budget else { continue }
                chosen.insert(i)
                size += cost
            }
            if size >= budget { break }
        }
        // Nothing matched (a question like "how did it go?"): the opening,
        // where agendas are set, and the close, where things get agreed.
        if chosen.isEmpty {
            var i = 0, j = lines.count - 1
            while i <= j {
                let cost = lines[i].1.count + lines[j].1.count + 2
                guard size + cost <= budget else { break }
                chosen.insert(i); chosen.insert(j)
                size += cost
                i += 1; j -= 1
            }
        }
        var out: [String] = []
        var last = -1
        for i in chosen.sorted() {
            if last >= 0, i != last + 1 { out.append("…") }
            out.append(lines[i].1)
            last = i
        }
        return "TRANSCRIPT (the parts most relevant to the question; … marks lines left out):\n" + out.joined(separator: "\n")
    }

    /// Splits a reply into what to show and, if present, proposed notes. An
    /// unterminated `<notes>` (the reply ran out) is left as text rather than
    /// offered as a rewrite — applying half the notes would lose the rest.
    static func parse(_ reply: String) -> (text: String, notes: String?) {
        guard let open = reply.range(of: "<notes>"),
              let close = reply.range(of: "</notes>", range: open.upperBound..<reply.endIndex)
        else { return (reply.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
        let notes = String(reply[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        var text = String(reply[..<open.lowerBound]) + String(reply[close.upperBound...])
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "Here are the revised notes." }
        return (text, notes.isEmpty ? nil : notes)
    }

    private static func clock(_ seconds: Double) -> String {
        let t = Int(seconds)
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

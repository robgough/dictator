import Foundation

/// Fictional content used wherever the app has to show "the user's own stuff"
/// without showing the *actual* user's stuff: developer-only screenshot mode
/// (`ScreenshotRunner`) and the user-facing Demo mode (`DemoMode`).
///
/// One cast, one set of facts, one place to change them — the two features
/// would otherwise drift apart and a marketing shot would stop matching what a
/// recording shows. Nothing here is ever written to a real store: screenshot
/// mode runs against a throwaway data root, and Demo mode is a read-side
/// overlay (see `DemoMode`).
///
/// The cast: **Sam Okafor** (the user), **Priya Natarajan** (a colleague),
/// **Tom Reilly** (a colleague), **Northwind** (a client), **Lumenfield** (the
/// product), `lumenfield.example` (the domain). No real names, no real domains
/// — `.example` is reserved by RFC 2606 and can never resolve.
@MainActor
enum DemoFixtures {

    static let userName = "Sam Okafor"

    // MARK: - Settings

    /// The settings a demo/screenshot surface should show: the fictional user
    /// name and the five-mode line-up the marketing shots are built around.
    /// Everything else is left at defaults.
    static func settings() -> DictatorSettings {
        var settings = DictatorSettings.defaults
        settings.userName = userName
        settings.hudStyle = .island
        settings.hasCompletedOnboarding = true
        settings.preloadModelsOnLaunch = false
        settings.modes = modes()
        settings.defaultModeID = DictationMode.standardID
        return settings
    }

    static func modes() -> [DictationMode] {
        [
            DictationMode(id: DictationMode.quickID, name: "Quick", isLocked: true, style: .raw),
            DictationMode(id: DictationMode.standardID, name: "Clean", style: .clean),
            DictationMode(id: DictationMode.polishedID, name: "Polished", style: .polished),
            DictationMode(
                id: DictationMode.messagesID,
                name: "Messages",
                appBundleIDs: [
                    "com.tinyspeck.slackmacgap",
                    "org.whispersystems.signal-desktop",
                    "com.apple.MobileSMS",
                ],
                style: .messages
            ),
            DictationMode(
                id: UUID(uuidString: "2C1F9A64-0F2C-4C3E-9B10-9D6B7E5A4C21")!,
                name: "Email",
                appBundleIDs: ["com.apple.mail"],
                style: .polished,
                extraInstructions: "Always use British spelling."
            ),
        ]
    }

    // MARK: - Dictation history

    /// Seven dictations spread over the last few days, newest first — mixed
    /// styles, mixed lengths, one clipboard-only fallback, one with a
    /// dictionary correction, so every branch of the History row renders.
    ///
    /// Timestamps are relative to "now" at the moment the fixtures are built,
    /// so they stay inside the store's 7-day window and read as recent
    /// whenever they're shown.
    static func historyRecords(now: Date = Date()) -> [DictationRecord] {
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        return [
            record(
                timestamp: at(9),
                raw: "so the northwind migration is basically done we just need to point their staging environment at the new api and run the import overnight",
                style: "Clean",
                stages: [
                    DictationStage(
                        name: "Format",
                        text: "So the Northwind migration is basically done. We just need to point their staging environment at the new API and run the import overnight."
                    )
                ],
                final: "So the Northwind migration is basically done. We just need to point their staging environment at the new API and run the import overnight. ",
                pasted: true
            ),
            record(
                timestamp: at(52),
                raw: "hi priya thanks for the notes I've had a look through and the only thing I'd push back on is the timeline for the second phase it feels tight given we still have the lumenfield export to finish can we talk it through tomorrow",
                style: "Polished",
                stages: [
                    DictationStage(
                        name: "Format",
                        text: "Hi Priya, thanks for the notes. I've had a look through and the only thing I'd push back on is the timeline for the second phase. It feels tight given we still have the Lumenfield export to finish. Can we talk it through tomorrow?"
                    ),
                    DictationStage(
                        name: "Polish",
                        text: "Hi Priya, thanks for the notes. I've read through them, and the only thing I'd push back on is the timeline for the second phase — it feels tight given we still have the Lumenfield export to finish. Could we talk it through tomorrow?"
                    ),
                ],
                final: "Hi Priya, thanks for the notes. I've read through them, and the only thing I'd push back on is the timeline for the second phase — it feels tight given we still have the Lumenfield export to finish. Could we talk it through tomorrow? ",
                pasted: true
            ),
            record(
                timestamp: at(3 * 60 + 20),
                raw: "on my way five minutes",
                style: "Messages",
                stages: [DictationStage(name: "Messages", text: "on my way, five minutes")],
                final: "on my way, five minutes",
                pasted: true
            ),
            record(
                timestamp: at(26 * 60),
                raw: "reminder to send tom the revised estimate before standup",
                style: "Raw",
                stages: nil,
                final: "reminder to send tom the revised estimate before standup ",
                pasted: true
            ),
            record(
                timestamp: at(29 * 60),
                raw: "three things came out of the review new paragraph first the importer needs a dry run mode new paragraph second we should log every skipped row rather than silently dropping it new paragraph third tom wants a summary email at the end of each run",
                style: "Polished",
                stages: [
                    DictationStage(
                        name: "Format",
                        text: "Three things came out of the review.\n\nFirst, the importer needs a dry-run mode.\n\nSecond, we should log every skipped row rather than silently dropping it.\n\nThird, Tom wants a summary email at the end of each run."
                    ),
                    DictationStage(
                        name: "Paragraphs",
                        text: "Three things came out of the review.\n\nFirst, the importer needs a dry-run mode.\n\nSecond, we should log every skipped row rather than silently dropping it.\n\nThird, Tom wants a summary email at the end of each run."
                    ),
                ],
                final: "Three things came out of the review.\n\nFirst, the importer needs a dry-run mode.\n\nSecond, we should log every skipped row rather than silently dropping it.\n\nThird, Tom wants a summary email at the end of each run. ",
                pasted: true
            ),
            record(
                timestamp: at(2 * 24 * 60 + 15),
                raw: "the lumen field dashboard is loading in about a second now which is good enough to ship",
                style: "Clean",
                stages: [
                    DictationStage(
                        name: "Format",
                        text: "The lumen field dashboard is loading in about a second now, which is good enough to ship."
                    )
                ],
                dictionaryCorrected: "The Lumenfield dashboard is loading in about a second now, which is good enough to ship.",
                final: "The Lumenfield dashboard is loading in about a second now, which is good enough to ship. ",
                pasted: true
            ),
            record(
                timestamp: at(3 * 24 * 60 + 40),
                raw: "can you check whether the northwind contract renews in march or april I keep seeing both dates",
                style: "Clean",
                stages: [
                    DictationStage(
                        name: "Format",
                        text: "Can you check whether the Northwind contract renews in March or April? I keep seeing both dates."
                    )
                ],
                final: "Can you check whether the Northwind contract renews in March or April? I keep seeing both dates. ",
                pasted: false,
                note: "Accessibility not granted — copied to the clipboard instead",
                // One fixture carries a window-vision read so the History pane's
                // "from screen" badge appears in screenshots and demos.
                visionTermCount: 3
            ),
        ]
    }

    /// Keeps the seven records above readable — `DictationRecord` has no
    /// memberwise defaults of its own (every field is a `let`, and the legacy
    /// pre-styles fields have to be filled in for old History rows to render).
    private static func record(
        timestamp: Date,
        raw: String,
        style: String,
        stages: [DictationStage]?,
        dictionaryCorrected: String? = nil,
        final: String,
        pasted: Bool,
        note: String? = nil,
        inputDevice: String = "MacBook Pro Microphone",
        visionTermCount: Int? = nil
    ) -> DictationRecord {
        DictationRecord(
            id: UUID(),
            timestamp: timestamp,
            raw: raw,
            style: style,
            stages: stages,
            // Mirrors what Pipeline writes: the first accepted stage lands in
            // the legacy `formatted` field, later ones in `tidied`.
            formatted: stages?.first?.text,
            dictionaryCorrected: dictionaryCorrected,
            tidied: stages?.dropFirst().first?.text,
            restructured: nil,
            final: final,
            pasted: pasted,
            inputDevice: inputDevice,
            note: note,
            appBundleID: nil,
            deliveredToJournal: false,
            visionTermCount: visionTermCount
        )
    }

    // MARK: - Assistant conversations

    /// Three threads, newest first: a drafted reply, an in-place tighten, and
    /// a summary. One DRAFT, one REPLACE, one DRAFT — the shapes a user
    /// actually accumulates, shown in the result window and in the chat
    /// sidebar alongside typed chats.
    static func assistantThreads(now: Date = Date()) -> [ChatThread] {
        [
            ChatThread.assistant(turns: [draftReplyTurn(now: now)]),
            ChatThread.assistant(
                turns: [ConversationTurn(
                    id: UUID(),
                    timestamp: now.addingTimeInterval(-95 * 60),
                    instruction: "Tighten this paragraph — it's twice as long as it needs to be.",
                    selection: """
                    What we're proposing here is essentially a phased approach, whereby the \
                    first phase would focus primarily on getting the data migrated across, \
                    and then the second phase, once that is complete and signed off, would \
                    look at bringing the reporting side of things over as well.
                    """,
                    mode: .replace,
                    reply: """
                    We propose two phases: migrate the data first, then move reporting across \
                    once that's signed off.
                    """
                )]
            ),
            ChatThread.assistant(
                turns: [ConversationTurn(
                    id: UUID(),
                    timestamp: now.addingTimeInterval(-27 * 60 * 60),
                    instruction: "Summarise these notes into three bullets I can send to Tom.",
                    selection: """
                    Northwind call — they're happy with the import speed, unhappy that skipped \
                    rows aren't reported anywhere. Priya walked them through the new dashboard, \
                    went well. They asked again about SSO; said we'd come back with a date. \
                    Renewal paperwork is with their legal team.
                    """,
                    mode: .draft,
                    reply: """
                    - Northwind are happy with import speed, but want skipped rows reported \
                    rather than silently dropped.
                    - The new dashboard demo went well.
                    - Two open items: an SSO date, and renewal paperwork sitting with their legal team.
                    """
                )]
            ),
        ]
    }

    /// The one-turn drafted-email thread the marketing screenshot is built
    /// around. Kept separate so `ScreenshotRunner` can seed exactly this
    /// thread without the other two.
    static func draftReplyTurn(now: Date = Date()) -> ConversationTurn {
        ConversationTurn(
            id: UUID(),
            timestamp: now.addingTimeInterval(-40),
            instruction: "Draft a polite reply saying I can't make Thursday and suggesting Tuesday instead.",
            selection: """
            Hi Sam — are you free Thursday at 3pm to walk through the Q3 roadmap \
            before we take it to the wider team?
            """,
            mode: .draft,
            reply: """
            Hi Priya,

            Thanks for pulling this together. Thursday afternoon is out for me \
            unfortunately — I'm tied up with the Northwind renewal until the \
            evening.

            Could we do Tuesday instead? I'm free any time after 10am, and that \
            still leaves us a clear week before the wider review.

            Cheers,
            Sam
            """
        )
    }

    // MARK: - Assistant memory

    /// The same shape `AssistantMemory` parses out of `assistant-memory.md`:
    /// one short fact per line, oldest first.
    static let memoryLines: [String] = [
        "Signs off emails with \u{201C}Cheers, Sam\u{201D}.",
        "Prefers British spelling.",
        "Works with Priya Natarajan on the Q3 roadmap.",
        "Northwind is a client, not a colleague — keep replies to them formal.",
        "Keeps drafts under 150 words unless asked for more.",
    ]

    // MARK: - Dictionary

    /// Seven rules of the kind people actually add: product and client names
    /// the transcriber mangles, a colleague's name, and two acronyms.
    static func vocabulary() -> [VocabularyEntry] {
        [
            VocabularyEntry(pattern: "lumen field", replacement: "Lumenfield"),
            VocabularyEntry(pattern: "north wind", replacement: "Northwind"),
            VocabularyEntry(pattern: "pre a natarajan", replacement: "Priya Natarajan"),
            VocabularyEntry(pattern: "tom riley", replacement: "Tom Reilly"),
            VocabularyEntry(pattern: "ess ess oh", replacement: "SSO", caseSensitive: false),
            VocabularyEntry(pattern: "see ess vee", replacement: "CSV"),
            VocabularyEntry(pattern: "q three", replacement: "Q3"),
        ]
    }

    // MARK: - Scratchpad

    static let scratchpadNote = """
    # Before the Northwind call

    - Import runs clean on staging — 40k rows, 90 seconds
    - Still need a dry-run mode before they'll sign it off
    - Priya has the roadmap deck; ask her to send it Monday
    - Open question: SSO date. Don't commit to one on the call.

    Follow up with Tom about the revised estimate.
    """

    // MARK: - Journal

    /// Where the journal fixtures live: relative, so it resolves under the
    /// synced folder. The shipping default is `~/Documents/…`, which would
    /// escape a screenshot run's throwaway data root and land in the real
    /// journal.
    static let journalPathTemplate = "Journal/{yyyy}/{MM}/{yyyy}-{MM}-{dd}.md"

    /// A week and a bit of entries, `(days ago, hour, minute, text)`, oldest
    /// first so they append in order. Today carries three so the page has a
    /// shape; the rest exist to put dots on the calendar.
    static let journalEntries: [(daysAgo: Int, hour: Int, minute: Int, text: String)] = [
        (11, 21, 40, "First week with the new team structure. Tom seems relieved to have fewer meetings; Priya less so."),
        (9, 7, 55, "Northwind want a pilot before they commit to the renewal. Fair. I'd want the same."),
        (6, 22, 10, "Couldn't switch off tonight. Wrote the pilot plan three times in my head and none of them were better than the one on paper."),
        (4, 13, 5, "Priya suggested moving the onboarding work into Q4 so the pilot gets our best people. She's right, and I should have seen it first."),
        (2, 18, 30, "Lumenfield demo went well. Tom ran it, not me, and it was better for it."),
        (1, 8, 20, "Short one. Northwind call moved to Thursday. More time to get the import dry-run finished."),
        (0, 8, 14, "Slept badly again. The Northwind renewal is taking up more room in my head than it deserves. Talk to Priya before Thursday about what we can actually promise."),
        (0, 12, 47, "Walked to the river at lunch instead of eating at my desk. Two ideas came out of it: a shorter Lumenfield trial, and letting Tom own the pilot outright. I keep saying I'll let go of things."),
        (0, 18, 5, "Good day in the end. The dry-run works, and Priya has the deck. Remember this the next time I spend a whole night worrying about a call."),
    ]

    // MARK: - Chat

    /// A chat that shows the two things the window is for: a tool reading the
    /// user's own data, and a file made from it.
    static let chatUserMessage = "What have I written about Northwind lately? Turn it into a short note I can take into Thursday's call."

    static let chatJournalResult = """
    4 entries mention Northwind:
    - today 08:14: Slept badly again. The Northwind renewal is taking up more room…
    - yesterday 08:20: Northwind call moved to Thursday…
    - 6 days ago 22:10: Couldn't switch off tonight. Wrote the pilot plan three times…
    - 9 days ago 07:55: Northwind want a pilot before they commit to the renewal…
    """

    static let chatNoteName = "northwind-thursday.md"

    static let chatNote = """
    # Northwind — Thursday

    - They want a pilot before committing to the renewal
    - Import dry-run now works; show it rather than describe it
    - Tom owns the pilot; Priya has the roadmap deck
    - Onboarding work moves to Q4 so the pilot gets the best people
    - Don't promise an SSO date
    """

    static let chatReply = """
    You've mentioned Northwind four times in the last ten days. The short version: they want a pilot before they'll renew, the call moved to Thursday, and since then the import dry-run has started working.

    I've saved the note above as **northwind-thursday.md**. One thing it doesn't cover: you haven't written down what the pilot would cost them — worth deciding before the call.
    """
}

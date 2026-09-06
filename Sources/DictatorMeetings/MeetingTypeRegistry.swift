import Foundation

/// Resolves a persisted `MeetingTypeID` to its full `MeetingTypeDefinition` —
/// the built-ins that ship with the app plus the user's custom types from
/// settings. The single place that knows what an id *means*; meta.json only
/// ever stores the id, so a deleted custom type degrades gracefully here
/// (unknown id → the unbiased "Other" definition) instead of breaking decode.
///
/// Built-ins are expressed in the same ALL-CAPS template format users write
/// custom types in — read-only in the editor but duplicable, so "start from
/// Team meeting and tweak it" is the natural on-ramp. Every concrete type
/// states its full section list explicitly (a retro gets WHAT WENT WELL /
/// WHAT DIDN'T GO WELL / WHAT TO CHANGE, a stand-up gets an UPDATES round,
/// …), with the per-section guidance carried over from the prose addenda the
/// retired `MeetingType` enum hand-tuned. Only Auto-detect (prose by nature
/// — it's the "decide yourself" instruction) and Other (deliberately empty)
/// have no sections.
@MainActor
enum MeetingTypeRegistry {

    // MARK: - Lookup

    /// Every selectable type, built-ins first, customs in user order.
    static func all(settings: MeetingsSettings) -> [MeetingTypeDefinition] {
        builtIns + settings.customMeetingTypes
    }

    /// Resolve an id to its definition. Unknown ids (a custom type the user
    /// has since deleted, or one synced from a newer install) fall back to
    /// the unbiased "Other" — the conservative prompt, never a decode error.
    static func definition(for id: MeetingTypeID, settings: MeetingsSettings) -> MeetingTypeDefinition {
        all(settings: settings).first { $0.id == id.rawValue } ?? builtIn(.other)
    }

    /// Display name for an id. Unknown ids are humanised from the raw slug
    /// ("eng-sync" → "Eng sync") rather than mislabelled "Other" — notes
    /// written for a since-deleted type were still written for *that* type.
    static func displayName(for id: MeetingTypeID, settings: MeetingsSettings) -> String {
        if let def = all(settings: settings).first(where: { $0.id == id.rawValue }) {
            return def.displayName
        }
        let words = id.rawValue.split(whereSeparator: { $0 == "-" || $0 == "_" }).joined(separator: " ")
        guard let first = words.first else { return id.rawValue }
        return first.uppercased() + words.dropFirst()
    }

    /// Types the auto-detector may choose between: every concrete shape,
    /// excluding `.auto` (the thing being resolved) and `.other` (a
    /// deliberate "don't bias" choice the model shouldn't reach for).
    static func detectionCandidates(settings: MeetingsSettings) -> [MeetingTypeDefinition] {
        all(settings: settings).filter { $0.id != MeetingTypeID.auto.rawValue && $0.id != MeetingTypeID.other.rawValue }
    }

    static func builtIn(_ id: MeetingTypeID) -> MeetingTypeDefinition {
        builtIns.first { $0.id == id.rawValue } ?? builtIns.last!
    }

    // MARK: - Built-in definitions

    static let builtIns: [MeetingTypeDefinition] = [
        MeetingTypeDefinition(
            id: MeetingTypeID.auto.rawValue,
            displayName: "Auto-detect",
            detail: "Let the model decide from the transcript",
            template: """
            First identify the kind of recording from the transcript — a stand-up, 1-on-1, retrospective, planning, interview, client call, brainstorm, talk / lecture, a conversation you're only listening in on (podcast, panel, discussion), or a general team meeting — then write the notes in the structure that kind typically calls for, adapting the emphasis and choosing topic sections that fit the content. Keep the section format from the system prompt.
            """,
            isBuiltIn: true
        ),
        MeetingTypeDefinition(
            id: MeetingTypeID.oneOnOne.rawValue,
            displayName: "1-on-1",
            detail: "A 1:1 between two people",
            template: """
            This is a 1-on-1 between two people.

            SUMMARY
            A short factual recap of what the two covered, not advice.

            DISCUSSION
            Emphasise the concrete commitments either side made and anything raised that needs follow-up — career, blockers, feedback, personal context that affects work. Note the tone if it shifted noticeably.

            DECISIONS
            Usually brief and personal — capture them precisely. Omit the section if none.

            ACTION ITEMS
            Attribute each action item to whichever of the two committed to it.
            """,
            detectionKeyword: "one-on-one",
            isBuiltIn: true
        ),
        MeetingTypeDefinition(
            id: MeetingTypeID.standup.rawValue,
            displayName: "Stand-up",
            detail: "A quick status round: what each person did, is doing, and any blockers",
            template: """
            This is a stand-up. Keep it terse; stand-ups are short by design.

            SUMMARY

            UPDATES
            One `-` bullet per named person: what they shipped or finished since last time, what they're working on next, and any blockers they raised. Use the speaker's exact display name from their `[Name · mm:ss]` prefix.

            DISCUSSION
            Anything discussed beyond the status round. Omit the section when the meeting was just the round.

            DECISIONS
            Decisions are rare in stand-ups — include the section only when the team genuinely agreed something.

            ACTION ITEMS
            Group action items by owner.
            """,
            detectionKeyword: "standup",
            isBuiltIn: true
        ),
        MeetingTypeDefinition(
            id: MeetingTypeID.teamMeeting.rawValue,
            displayName: "Team meeting",
            detail: "A general team or group meeting",
            template: """
            This is a general team meeting.

            SUMMARY

            UPDATES
            When the meeting includes a round of status updates: one `-` bullet per person who gave an update — what they shipped or finished, what they're working on, and any blocker they raised, e.g. `- Sarah: auth migration ~80% done; blocked on flag gating`. Use the speaker's exact display name from their `[Name · mm:ss]` prefix. Omit the section when there's no status round.

            DISCUSSION
            NEVER write a bullet that just names a topic — every bullet must carry the substance of what was said about it: the positions taken, the specifics given, where it landed. BAD: `- Discussed the release date.` GOOD: `- Release slipped to June 12 — the auth migration is the blocker and the staging rollback ate two days.` Don't repeat a point that already lives in Updates or Learnings — each point appears once, in whichever section fits it best.

            LEARNINGS
            The new information the team came away with, as plain `-` bullets — results of things tried, metrics and figures reported, customer or user feedback relayed, gotchas and warnings shared, announcements. Each bullet a concrete, standalone fact with the specifics exactly as stated. Omit the section when nothing new was shared.

            DECISIONS
            Only what the team actually agreed, not topics merely discussed.

            ACTION ITEMS
            Attribute each action item to the member who took it on.

            OPEN QUESTIONS
            Questions raised but not resolved, and items explicitly deferred to a later meeting. Omit the section when there are none.
            """,
            detectionKeyword: "team-meeting",
            isBuiltIn: true
        ),
        MeetingTypeDefinition(
            id: MeetingTypeID.planning.rawValue,
            displayName: "Planning",
            detail: "Scoping work: deliverables, dates, owners",
            template: """
            This is a planning meeting.

            SUMMARY

            SCOPE
            What was agreed in and what was agreed out, as plain `-` bullets. Omit the section when scope wasn't discussed.

            DISCUSSION
            The options weighed and commitments made — deliverables, dates, owners assigned to each workstream.

            RISKS & DEPENDENCIES
            Any dependencies or risks flagged. Omit the section when none were raised.

            DECISIONS
            The concrete scope and date agreements.

            ACTION ITEMS
            Every action item must carry an owner and a deliverable — never leave a planning action unowned if the transcript names someone.
            """,
            detectionKeyword: "planning",
            isBuiltIn: true
        ),
        MeetingTypeDefinition(
            id: MeetingTypeID.retrospective.rawValue,
            displayName: "Retrospective",
            detail: "What went well, what didn't, what to change",
            template: """
            This is a retrospective.

            SUMMARY

            WHAT WENT WELL
            One `-` bullet per thing that worked, with the specifics as stated.

            WHAT DIDN'T GO WELL
            One `-` bullet per problem or frustration raised, with the specifics as stated.

            WHAT TO CHANGE
            The concrete process changes the team agreed to try.

            ACTION ITEMS
            The experiments or follow-ups carried into the next iteration — attribute them to the named owner where the transcript provides one.
            """,
            detectionKeyword: "retrospective",
            isBuiltIn: true
        ),
        MeetingTypeDefinition(
            id: MeetingTypeID.interview.rawValue,
            displayName: "Interview",
            detail: "A job interview (interviewer and candidate)",
            template: """
            This is a job interview.

            SUMMARY

            COMPANY
            The checkable facts stated about the company, the role, and the process, as plain `-` bullets, each exactly as stated: what the product does, customers and traction, team size and org structure, funding / revenue / financial figures, tech stack, ways of working, compensation and benefits, location and remote policy, interview process and timeline.

            CANDIDATE
            The checkable facts and signals about the candidate, as plain `-` bullets: background and tenure (companies, roles, dates), team sizes they led or worked in, who they reported to, technologies and products they name, scale and performance figures they cite, motivations, compensation expectations and notice period — plus concrete fit signals (positive or negative) raised in the conversation.

            DISCUSSION
            The substance that isn't a Company or Candidate fact: how the conversation flowed, themes, the questions asked and how they were answered.

            QUOTES
            Two or three short VERBATIM lines from the transcript that capture how the person thinks or talks — each bullet the exact words in double quotes, speaker named at the end (e.g. `- "We rebuilt the whole pipeline in a weekend." — Sanah [23:14]`). Never paraphrase inside quotation marks; omit the section if nothing stands out.

            OPEN QUESTIONS
            Anything left unanswered or that needs verifying. Omit the section when there are none.

            DECISIONS
            Usually "advance" / "do not advance" / "another round" — only when the transcript makes that explicit.

            ACTION ITEMS
            The owner is whoever owns the next step exactly as named — interviewer, recruiter, or candidate — and include stated process commitments ("they'll hear back by Friday").
            """,
            detectionKeyword: "interview",
            isBuiltIn: true,
            coach: MeetingTypeDefinition.CoachConfig(
                checklist: [
                    "Explain the role and the process",
                    "Ask for concrete examples, not opinions",
                    "Leave time for their questions",
                    "Tell them when they'll hear back",
                ],
                rubric: "A good interviewer talks far less than the candidate, asks open questions that pull concrete examples, never interrupts an answer, covers the must-ask areas, and closes with clear next steps and a timeline.",
                armedNudges: ["dominating", "monologue", "interrupting", "askQuestion"]
            )
        ),
        MeetingTypeDefinition(
            id: MeetingTypeID.clientCall.rawValue,
            displayName: "Client call",
            detail: "A call with a customer or client",
            template: """
            This is a client call. Record the specific facts stated, exactly as given — budgets and prices, team sizes and org structure on the client's side, named products, systems and vendors, volumes and metrics, dates and deadlines.

            SUMMARY

            CLIENT ASKS
            The client's stated needs, concerns and asks, as plain `-` bullets, each with what was agreed in response.

            DISCUSSION
            The rest of the substance — context shared, options explored, commitments either side made.

            DECISIONS
            Concrete agreements: scope, price, timeline, deliverables.

            ACTION ITEMS
            Attribute action items to their owner — when the transcript clearly puts a follow-up on the team's side ("we'll send the proposal", "I'll get back to you"), record that owner exactly as named.

            OPEN QUESTIONS
            Anything the team still owes the client an answer on. Omit the section when there are none.
            """,
            detectionKeyword: "client-call",
            isBuiltIn: true,
            coach: MeetingTypeDefinition.CoachConfig(
                checklist: [
                    "Understand what problem they're trying to solve",
                    "Ask about timeline",
                    "Ask about budget",
                    "Understand who makes the decision",
                    "Agree the next step before ending",
                ],
                rubric: "A good client call is discovery-led: the client talks more than you, you ask open questions about their problem, timeline, budget, and decision process, and the call ends with an explicitly agreed next step.",
                armedNudges: ["dominating", "monologue", "interrupting", "askQuestion"]
            )
        ),
        MeetingTypeDefinition(
            id: MeetingTypeID.brainstorm.rawValue,
            displayName: "Brainstorm",
            detail: "Open idea generation around a problem",
            template: """
            This is a brainstorm.

            SUMMARY
            The question or problem explored.

            IDEAS
            The directions the ideas clustered around — one `-` bullet per direction with the strongest ideas under it, not every idea individually.

            DECISIONS
            Anything the group explicitly committed to pursue or ruled out. Often none — that's fine, omit the section.

            ACTION ITEMS
            Concrete next steps named in the meeting (write up the top three, prototype direction X, schedule a follow-up) with their owner.
            """,
            detectionKeyword: "brainstorm",
            isBuiltIn: true
        ),
        MeetingTypeDefinition(
            id: MeetingTypeID.lecture.rawValue,
            displayName: "Talk / lecture",
            detail: "A talk or lecture by a single presenter",
            template: """
            This is a talk or lecture by a single presenter.

            SUMMARY

            KEY POINTS
            The main thesis and the supporting points in roughly the order presented, plus any examples or anecdotes that carried the argument.

            DECISIONS
            Usually empty — talks teach rather than commit. Include the section only when the speaker explicitly announces a decision.

            ACTION ITEMS
            Usually empty. Include the section only when the speaker explicitly assigns work to attendees.
            """,
            detectionKeyword: "lecture",
            isBuiltIn: true
        ),
        MeetingTypeDefinition(
            id: MeetingTypeID.conversation.rawValue,
            displayName: "Conversation / podcast",
            detail: "A discussion you're only listening to (podcast, panel, recorded chat)",
            template: """
            This is a conversation you're listening in on rather than taking part in — a podcast, panel, interview, or recorded discussion between other people. You're an observer, not a participant: there's usually no "Me", and no action items for you. Record specific figures, names and stats exactly as stated, not rounded or generalised.

            SUMMARY

            DISCUSSION
            The substance — the main topics, the key points each speaker made (attributed by name where the transcript names them), where they agreed or disagreed, and any notable facts, recommendations or stories.

            TAKEAWAYS
            The conclusions or takeaways the speakers landed on. Omit the section when the conversation didn't conclude anything.

            DECISIONS
            Omit unless a speaker explicitly states a decision of their own.

            ACTION ITEMS
            Omit unless a speaker explicitly states a concrete next step of their own — never invent action items for the listener.
            """,
            detectionKeyword: "conversation",
            isBuiltIn: true
        ),
        MeetingTypeDefinition(
            id: MeetingTypeID.other.rawValue,
            displayName: "Other",
            detail: "No structure bias",
            template: "",
            isBuiltIn: true
        ),
    ]
}

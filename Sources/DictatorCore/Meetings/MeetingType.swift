import Foundation

/// Identifies the conversational shape of a meeting so the summary prompt
/// can emphasise the right structure (per-person updates for a stand-up,
/// what-went-well / what-didn't for a retro, etc.). One per-meeting setting
/// on `MeetingMeta`, with `.auto` as the install-wide default.
///
/// `.auto` is two things at once: a saved-default that lets the model
/// decide from the transcript, and the fall-through value when the user
/// hasn't explicitly picked a type for the meeting. Every other case is a
/// deliberate user choice — the prompt addendum then steers the LLM toward
/// the format people expect for that meeting shape.
public enum MeetingType: String, Codable, CaseIterable, Sendable {
    case auto
    case oneOnOne
    case standup
    case teamMeeting
    case planning
    case retrospective
    case interview
    case clientCall
    case brainstorm
    case lecture
    case other

    public var displayName: String {
        switch self {
        case .auto:           return "Auto-detect"
        case .oneOnOne:       return "1-on-1"
        case .standup:        return "Stand-up"
        case .teamMeeting:    return "Team meeting"
        case .planning:       return "Planning"
        case .retrospective:  return "Retrospective"
        case .interview:      return "Interview"
        case .clientCall:     return "Client call"
        case .brainstorm:     return "Brainstorm"
        case .lecture:        return "Talk / lecture"
        case .other:          return "Other"
        }
    }

    /// Appended under the built-in meeting summary prompt to steer the
    /// model toward the structure people expect for this meeting shape.
    /// Empty string means "no addendum" — used only by `.other`, which is
    /// a deliberate user choice not to bias the prompt.
    public var promptAddendum: String {
        switch self {
        case .auto:
            return """
            First identify the meeting type from the transcript (stand-up, 1-on-1, retrospective, planning, interview, client call, brainstorm, talk / lecture, or general team meeting), then summarise in the structure that meeting type typically calls for. Keep the JSON shape unchanged — only the emphasis inside `decisions`, `actionItems`, and `narrative` adapts.
            """
        case .oneOnOne:
            return """
            This is a 1-on-1 between two people. Emphasise concrete commitments either side made, anything raised that needs follow-up (career, blockers, feedback, personal context that affects work), and the tone if it shifted noticeably. Decisions are usually brief and personal — capture them precisely. Action items should be attributed to whichever of the two people committed to them. The narrative should read as a short factual recap of what the two people covered, not as advice.
            """
        case .standup:
            return """
            This is a stand-up. Structure the narrative around what each named participant said in their turn: what they shipped or finished since the last stand-up, what they're working on next, and any blockers they raised. Group action items by owner where possible. Decisions are rare in stand-ups — leave that array empty unless the team genuinely agreed something. Keep it terse — stand-ups are short by design.
            """
        case .teamMeeting:
            return """
            This is a general team meeting. Capture the topics covered in the narrative in roughly the order they came up. Pull out decisions the team actually agreed (not topics merely discussed), and attribute action items to the team member who took them on. Mention any unresolved questions or items explicitly deferred to a later meeting.
            """
        case .planning:
            return """
            This is a planning meeting. Emphasise the scope agreed (what's in, what's out), commitments to deliverables and dates, owners assigned to each workstream, and any dependencies or risks the team flagged. Decisions should list the concrete scope and date agreements. Action items must carry an owner and a deliverable — never leave a planning action unowned if the transcript names someone.
            """
        case .retrospective:
            return """
            This is a retrospective. Structure the narrative around three buckets: what went well, what didn't, and what the team agreed to change. Decisions should list the concrete process changes the team agreed to try. Action items are the experiments or follow-ups carried forward to the next iteration — attribute them to the named owner where the transcript provides one.
            """
        case .interview:
            return """
            This is an interview. The narrative should summarise the candidate's responses grouped by topic (background, technical depth, collaboration style, motivation, questions they asked), surface concrete signals about fit (positive or negative) the interviewer raised, and note any follow-ups the interviewer committed to (sending a take-home, scheduling another round, looping in another team member). Decisions usually capture "advance the candidate" / "do not advance" / "needs another round" when the transcript makes that explicit. Action items go to the named interviewer or recruiter who owns the next step.
            """
        case .clientCall:
            return """
            This is a client call. Capture the client's stated needs, concerns, and asks; what was agreed in response; commitments either side made; and any open questions the team still owes the client an answer to. Decisions list concrete agreements (scope, price, timeline, deliverables). Action items should attribute owners — when the transcript clearly puts a follow-up on the team's side ("we'll send the proposal", "I'll get back to you"), record that owner exactly as named.
            """
        case .brainstorm:
            return """
            This is a brainstorm. The narrative should describe the question or problem the group explored and the broad directions the ideas clustered around — not every idea individually. Decisions should list anything the group explicitly committed to pursue or definitively ruled out (often empty for pure brainstorms — that's fine). Action items capture concrete next steps named in the meeting (write up the top three, prototype direction X, schedule a follow-up) with their owner.
            """
        case .lecture:
            return """
            This is a talk or lecture by a single presenter. The narrative should summarise the main thesis, the supporting points the speaker made in roughly the order presented, and any examples or anecdotes that carried the argument. Decisions and action items are usually empty — talks teach rather than commit. Only populate them if the speaker explicitly announces a decision or assigns work to attendees.
            """
        case .other:
            return ""
        }
    }
}

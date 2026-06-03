import Foundation

/// Identifies the conversational shape of a meeting so the notes prompt can
/// emphasise the right structure (per-person updates for a stand-up,
/// what-went-well / what-didn't for a retro, key points each speaker made for
/// a podcast you're listening to, etc.). One per-meeting setting on
/// `MeetingMeta`, with `.auto` as the install-wide default.
///
/// `.auto` is two things at once: a saved-default that lets the model decide
/// from the transcript, and the fall-through value when the user hasn't
/// explicitly picked a type for the meeting. Every other case is a deliberate
/// user choice — the prompt addendum then steers the LLM toward the format
/// people expect for that shape.
///
/// The addenda speak in terms of the markdown notes the model produces — the
/// `## Summary`, `## Discussion`, `## Decisions` and `## Action items`
/// sections defined by the built-in notes prompt — not any intermediate
/// structured shape.
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
    case conversation
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
        case .conversation:   return "Conversation / podcast"
        case .other:          return "Other"
        }
    }

    /// Appended under the built-in meeting notes prompt to steer the model
    /// toward the structure people expect for this shape. Speaks in terms of
    /// the markdown sections, not any JSON shape. Empty string means "no
    /// addendum" — used only by `.other`, a deliberate choice not to bias.
    public var promptAddendum: String {
        switch self {
        case .auto:
            return """
            First identify the kind of recording from the transcript — a stand-up, 1-on-1, retrospective, planning, interview, client call, brainstorm, talk / lecture, a conversation you're only listening in on (podcast, panel, discussion), or a general team meeting — then write the notes in the structure that kind typically calls for, adapting the emphasis within the Summary, Discussion, Decisions and Action items sections. Keep the section format from the system prompt.
            """
        case .oneOnOne:
            return """
            This is a 1-on-1 between two people. In the Discussion, emphasise the concrete commitments either side made and anything raised that needs follow-up (career, blockers, feedback, personal context that affects work); note the tone if it shifted noticeably. Decisions are usually brief and personal — capture them precisely. Attribute each action item to whichever of the two committed to it. Keep the Summary a short factual recap of what the two covered, not advice.
            """
        case .standup:
            return """
            This is a stand-up. Structure the Discussion by participant: what each named person shipped or finished since last time, what they're working on next, and any blockers they raised. Group action items by owner. Decisions are rare in stand-ups — omit the Decisions section unless the team genuinely agreed something. Keep it terse; stand-ups are short by design.
            """
        case .teamMeeting:
            return """
            This is a general team meeting. In the Discussion, capture the topics covered in roughly the order they came up. Put into Decisions only what the team actually agreed (not topics merely discussed), and attribute each action item to the member who took it on. Note any unresolved questions or items explicitly deferred to a later meeting.
            """
        case .planning:
            return """
            This is a planning meeting. Emphasise the scope agreed (what's in, what's out), commitments to deliverables and dates, owners assigned to each workstream, and any dependencies or risks flagged. Decisions should list the concrete scope and date agreements. Every action item must carry an owner and a deliverable — never leave a planning action unowned if the transcript names someone.
            """
        case .retrospective:
            return """
            This is a retrospective. Organise the Discussion into what went well, what didn't, and what the team agreed to change. Decisions should list the concrete process changes the team agreed to try. Action items are the experiments or follow-ups carried into the next iteration — attribute them to the named owner where the transcript provides one.
            """
        case .interview:
            return """
            This is a job interview. In the Discussion, summarise the candidate's responses grouped by topic (background, technical depth, collaboration, motivation, questions they asked) and surface concrete fit signals (positive or negative) the interviewer raised. Decisions usually capture "advance" / "do not advance" / "another round" when the transcript makes that explicit. Action items go to the named interviewer or recruiter who owns the next step (take-home, scheduling, looping someone in).
            """
        case .clientCall:
            return """
            This is a client call. Capture the client's stated needs, concerns and asks; what was agreed in response; commitments either side made; and any open questions the team still owes the client. Decisions list concrete agreements (scope, price, timeline, deliverables). Attribute action items to their owner — when the transcript clearly puts a follow-up on the team's side ("we'll send the proposal", "I'll get back to you"), record that owner exactly as named.
            """
        case .brainstorm:
            return """
            This is a brainstorm. In the Summary and Discussion, describe the question or problem explored and the directions the ideas clustered around — not every idea individually. Decisions list anything the group explicitly committed to pursue or ruled out (often none — that's fine, omit the section). Action items capture concrete next steps named in the meeting (write up the top three, prototype direction X, schedule a follow-up) with their owner.
            """
        case .lecture:
            return """
            This is a talk or lecture by a single presenter. In the Discussion, summarise the main thesis and the supporting points in roughly the order presented, plus any examples or anecdotes that carried the argument. Decisions and Action items are usually empty — talks teach rather than commit; omit those sections unless the speaker explicitly announces a decision or assigns work to attendees.
            """
        case .conversation:
            return """
            This is a conversation you're listening in on rather than taking part in — a podcast, panel, interview, or recorded discussion between other people. You're an observer, not a participant: there's usually no "Me", and no action items for you. In the Summary and Discussion, capture the substance — the main topics, the key points each speaker made (attributed by name where the transcript names them), where they agreed or disagreed, the conclusions or takeaways, and any notable facts, recommendations or stories. Omit the Decisions and Action items sections unless a speaker explicitly states a decision or a concrete next step of their own; never invent action items for the listener.
            """
        case .other:
            return ""
        }
    }
}

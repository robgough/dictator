import Foundation
import MLXLMCommon

/// The tools available for one turn, and which of them the model is actually
/// shown.
///
/// Those are different things once an MCP server is involved. Every tool's JSON
/// schema is re-sent on **every round** of a turn — there is no prompt cache —
/// and a turn with a tool call is two or three rounds. So a server exposing ~69
/// tools pays for all of them, repeatedly, whether or not any are relevant.
///
/// Measured on a 62-tool list, chained question needing two different tools:
///
/// | | all 62 in context | `find_tools` alone | index + `find_tools` |
/// |---|---|---|---|
/// | Qwen 3.5 9B  | 15.2s | **fails** | 4.8s |
/// | Qwen 3.5 4B  |  4.6s | **fails** | 1.9s |
/// | Gemma 4 12B  | 14.2s | 7.1s (5 rounds) | 7.7s |
/// | Gemma 4 E4B  |  4.2s | **fails** | 2.2s |
///
/// All four pass with everything in context — accuracy is not the problem,
/// prefill is. Deferring wins everywhere, by 2-3×.
///
/// **The index is what makes deferring work**, and its cost is the reason this
/// scales. A name-and-description line is ~15 tokens no matter how elaborate
/// the tool's schema is, so the index grows with the *number* of tools while
/// the full list grows with their *complexity*. On the deliberately simple
/// schemas in `scratch/tool-call-check` the measured split is 3,440 → 1,055
/// prompt tokens; against real MCP schemas (nested objects, enums, per-property
/// descriptions) the full-list side is several times larger while the index
/// side barely moves. On Gemma 4 12B's 32K window that difference is the whole
/// ballgame.
struct ChatToolset {
    /// Everything that could be called this turn.
    private(set) var catalogue: [ChatTool]
    /// What the model is shown. Grows as `find_tools` loads schemas.
    private(set) var advertised: [ChatTool]
    /// True when the catalogue was too big to send whole.
    let isDeferred: Bool

    /// Above this many tools, defer.
    ///
    /// Deferring is not free: it costs an extra round trip (~1-1.5s) plus the
    /// index itself. Sending everything costs roughly 0.09s per tool per round
    /// on a 9B — measured between the 2-tool and 62-tool runs — and a tool turn
    /// pays it two or three times. Break-even lands around 20-30 tools, so 24
    /// sits in the middle of it. Below that, sending everything is simpler and
    /// no slower; above it, deferring wins by a growing margin.
    static let deferAboveToolCount = 24

    init(builtIns: [ChatTool], remote: [ChatTool]) {
        let all = builtIns + remote
        self.catalogue = all
        if all.count > Self.deferAboveToolCount {
            self.isDeferred = true
            self.advertised = builtIns + [Self.findToolsTool]
        } else {
            self.isDeferred = false
            self.advertised = all
        }
    }

    var specs: [ToolSpec] { advertised.map(\.spec) }

    /// Roughly what the tool list costs in the prompt, every round.
    ///
    /// Measures the *serialised* schemas rather than guessing from names and
    /// descriptions. The guess was out by a factor of four — a real MCP schema
    /// carries types, enums, required lists and per-property descriptions — and
    /// on Gemma 4 12B's 32K window, being wrong by 12K tokens about what's left
    /// is the difference between trimming the conversation correctly and
    /// overflowing.
    var estimatedPromptTokens: Int {
        let schemaChars = advertised.reduce(0) { total, tool in
            guard JSONSerialization.isValidJSONObject(tool.spec),
                  let data = try? JSONSerialization.data(withJSONObject: tool.spec)
            else { return total + 200 }
            return total + data.count
        }
        return (schemaChars + indexBlock.count) / 4
    }

    /// Look up a tool the model asked for. Falls back to the whole catalogue.
    func tool(named name: String) -> ChatTool? {
        advertised.first { $0.name == name } ?? catalogue.first { $0.name == name }
    }

    /// Ranks the catalogue against a query and makes the winners callable.
    ///
    /// Returns the description the model gets back. Deliberately names and
    /// one-line descriptions only — the schemas go into the advertised set,
    /// where the chat template renders them properly, rather than being
    /// stringified into a tool result the model has to parse by eye.
    mutating func loadTools(matching query: String, limit: Int = 6) -> String {
        let candidates = catalogue.filter { $0.name != Self.findToolsTool.name }
        let matches = ChatSearch.rank(candidates, query: query, limit: limit) {
            "\($0.name) \($0.displayName) \($0.detail)"
        }
        guard !matches.isEmpty else {
            return "No tools match “\(query)”. Available areas: "
                + Set(candidates.compactMap { $0.serverName ?? "Dictator" })
                    .sorted().joined(separator: ", ")
                + ". Try different words, or answer without a tool."
        }
        for match in matches where !advertised.contains(where: { $0.name == match.name }) {
            advertised.append(match)
        }
        return matches
            .map { "\($0.name) — \($0.detail.isEmpty ? $0.displayName : $0.detail)" }
            .joined(separator: "\n")
            + "\n\nThese are now available. Call the one you need."
    }

    /// Every not-yet-loaded tool's name and one-line description, no schemas.
    ///
    /// Load-bearing, and not obvious: shown `find_tools` and nothing else,
    /// three of the four models failed scenarios outright — not because they
    /// can't search, but because a model has no idea anything else exists and
    /// so never thinks to look. It answers "I can't do that" with sixty tools
    /// one call away. The index removes that blind spot for about a third of
    /// the tokens (and far less than that against real MCP schemas).
    var indexBlock: String {
        let shown = Set(advertised.map(\.name))
        let entries = indexEntries(for: catalogue.filter { !shown.contains($0.name) })
        guard !entries.isEmpty else { return "" }
        return """
            These tools are connected, but their full details aren't loaded:
            \(entries)

            To use one, call find_tools with a few words describing what you want. \
            It loads the tool so you can then call it properly.
            """
    }

    /// Index entries, degrading gracefully as the catalogue grows.
    ///
    /// One 69-tool server indexes to about a thousand tokens, which is fine.
    /// Several would not be, and the index is in the system prompt on every
    /// round — so past a budget it drops descriptions (names alone still tell
    /// the model what exists, which is the job), and past a hard cap it
    /// truncates and says how many it left out. Silently sending a 20K-token
    /// index would reproduce the exact problem deferring exists to solve.
    private func indexEntries(for tools: [ChatTool]) -> String {
        let described = tools.map { tool -> String in
            let detail = tool.detail.isEmpty ? tool.displayName : tool.detail
            return "- \(tool.name): \(detail.prefix(110))"
        }
        let describedLength = described.reduce(0) { $0 + $1.count + 1 }
        if describedLength <= Self.indexCharacterBudget {
            return described.joined(separator: "\n")
        }

        let names = tools.map { "- \($0.name)" }
        let namesLength = names.reduce(0) { $0 + $1.count + 1 }
        if namesLength <= Self.indexCharacterBudget {
            return names.joined(separator: "\n")
        }

        var kept: [String] = []
        var used = 0
        for entry in names {
            guard used + entry.count + 1 <= Self.indexCharacterBudget else { break }
            kept.append(entry)
            used += entry.count + 1
        }
        let omitted = tools.count - kept.count
        return kept.joined(separator: "\n")
            + "\n- …and \(omitted) more. find_tools searches all of them."
    }

    /// Roughly 2,000 tokens. Comfortable next to one big server's index (~1,000)
    /// and a hard stop before several of them crowd out the conversation.
    private static let indexCharacterBudget = 8_000

    /// The meta-tool. Only advertised in deferred mode.
    static let findToolsTool = ChatTool(
        name: "find_tools",
        displayName: "Look for a tool",
        detail: "Searches the tools connected to this Mac.",
        spec: [
            "type": "function",
            "function": [
                "name": "find_tools",
                "description": "Search the tools available on this Mac and load the ones you need. There are many more tools than you can currently see. Call this FIRST whenever the request might need one — searching, reading or changing anything outside this conversation — then call the tool it gives you back.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "What you are trying to do, in a few words. For example “open a support ticket” or “list customers”.",
                        ] as [String: any Sendable]
                    ] as [String: any Sendable],
                    "required": ["query"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ],
        serverID: nil,
        serverName: nil,
        isSafeWithoutApproval: true
    )
}

import AppKit
import Foundation
import MLXLMCommon

/// The tools Dictator itself provides.
///
/// None of them prompt. They are Dictator's own code reading Dictator's own
/// data — the clipboard, the history, the journal, the screen the user is
/// already looking at — on a machine where the user has already granted this
/// app clipboard, screen-recording and accessibility access. Asking each time
/// bought no safety and made the assistant tedious to use, which is the
/// failure mode that actually matters: a tool the user dismisses is a tool
/// that never runs.
///
/// Deliberately few. Tool-selection accuracy falls off as the list grows, and
/// these models have to pick correctly from a list that also contains whatever
/// MCP servers the user has added — so the built-ins earn their place or they
/// aren't here. Each one answers a question the model genuinely cannot:
/// what's on my clipboard, what did I write down, what's on screen.
///
/// There is deliberately **no "check the time" tool**. The date and time go in
/// the system prompt instead. As a tool it cost a whole extra round trip before
/// the model could even start on "what did I journal yesterday", it was one
/// more wrong option to pick from a list, and it could be skipped — a model
/// that doesn't think to ask has no clock and quietly guesses the year. In the
/// prompt it is simply always true.
@MainActor
enum BuiltInChatTools {
    static func all(settings: DictatorSettings, canReadScreen: Bool) -> [ChatTool] {
        var tools: [ChatTool] = [
            tool(
                name: "read_clipboard",
                displayName: "Read the clipboard",
                detail: "Reads whatever text is on the clipboard right now.",
                description: "Read the text currently on the user's clipboard. Use when they refer to something they have copied.",
                parameters: [:],
                required: [],
                safe: true
            ),
            tool(
                name: "search_dictation_history",
                displayName: "Read dictation history",
                detail: "Reads and searches what the user has dictated recently.",
                description: "Read what the user has dictated recently. With no query this returns their most recent dictations, newest first — use that for anything about a time rather than a topic. Give a query only to search for particular words. Use days_back to limit how far back to look (1 = today only).",
                parameters: [
                    "query": [
                        "type": "string",
                        "description": "Words to search for. Leave this out to get the most recent dictations.",
                    ] as [String: any Sendable],
                    "days_back": [
                        "type": "integer",
                        "description": "Only include dictations from the last N days. 1 means today.",
                    ] as [String: any Sendable],
                ],
                required: [],
                safe: true
            ),
        ]

        if journalFileExists(settings: settings) {
            tools.append(
                tool(
                    name: "search_journal",
                    displayName: "Read the journal",
                    detail: "Reads and searches the user's journal entries.",
                    description: "Read the user's journal. With no query this returns their most recent entries, newest first — use that for “what have I journalled”, “what did I write yesterday”, or anything about a time rather than a topic. Give a query only to search for particular words. Use days_back to limit how far back to look (1 = today only, 2 = today and yesterday).",
                    parameters: [
                        "query": [
                            "type": "string",
                            "description": "Words to search entry text for. Leave this out to get the most recent entries.",
                        ] as [String: any Sendable],
                        "days_back": [
                            "type": "integer",
                            "description": "Only include entries from the last N days. 1 means today.",
                        ] as [String: any Sendable],
                    ],
                    required: [],
                    safe: true
                ))
        }

        if settings.assistantMemoryEnabled {
            tools.append(
                tool(
                    name: "remember_fact",
                    displayName: "Remember a fact",
                    detail: "Saves a fact to the assistant's long-term memory.",
                    description: "Store one durable fact about the user so it is available in future conversations. Use only when they ask you to remember something.",
                    parameters: [
                        "fact": [
                            "type": "string",
                            "description": "The fact, written as a single sentence in the third person.",
                        ] as [String: any Sendable]
                    ],
                    required: ["fact"],
                    safe: true
                ))
        }

        if canReadScreen {
            tools.append(
                tool(
                    name: "read_screen",
                    displayName: "Look at the screen",
                    detail: "Takes a screenshot of the window behind Dictator and reads it.",
                    description: "Take a screenshot of the window the user was last looking at and describe what it shows, including any text. Use when they refer to something on screen.",
                    parameters: [
                        "question": [
                            "type": "string",
                            "description": "What to look for in the window.",
                        ] as [String: any Sendable]
                    ],
                    required: [],
                    safe: true
                ))
        }

        return tools
    }

    /// The journal tool is offered only when there's a journal to search.
    /// There is no "journal enabled" setting — the feature is a hotkey — so the
    /// honest test is whether any journal files exist. Checks the journal
    /// *root*, not today's file: with the default one-file-per-day template,
    /// testing today's path hid the tool from anyone who hadn't journalled
    /// since midnight.
    private static func journalFileExists(settings: DictatorSettings) -> Bool {
        // Only that the journal directory exists — not a recursive walk. This
        // is called from `all()`, which runs inside a SwiftUI body, and
        // enumerating a directory tree on every redraw to decide whether to
        // list one row is not a trade worth making. A root that exists but
        // holds nothing just means the read answers "no journal files yet".
        journalRoot(settings: settings) != nil
    }

    private static func tool(
        name: String,
        displayName: String,
        detail: String,
        description: String,
        parameters: [String: any Sendable],
        required: [String],
        safe: Bool
    ) -> ChatTool {
        ChatTool(
            name: name,
            displayName: displayName,
            detail: detail,
            spec: [
                "type": "function",
                "function": [
                    "name": name,
                    "description": description,
                    "parameters": [
                        "type": "object",
                        "properties": parameters,
                        "required": required,
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
            ],
            serverID: nil,
            serverName: nil,
            isSafeWithoutApproval: safe
        )
    }

    /// Runs a built-in tool. Returns the text handed back to the model.
    ///
    /// Every failure is returned as *text*, not thrown: the spec's guidance is
    /// that a tool execution error should reach the model so it can adjust,
    /// and in practice "no journal entries matched" is a far better outcome
    /// than an exception that ends the turn.
    static func run(
        name: String,
        arguments: MCPJSON,
        settings: DictatorSettings,
        readScreen: @MainActor () async -> String?
    ) async -> String {
        switch name {
        case "read_clipboard":
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            return text.isEmpty ? "The clipboard is empty." : text

        case "search_dictation_history":
            // Same shape as the journal, and for the same reason: asked "what
            // did I dictate yesterday", a model sends a query with no words
            // that appear in any transcript, and a search-only tool answers
            // "nothing" about a history with hundreds of entries in it.
            let query = arguments["query"]?.stringValue ?? ""
            var records = DictationHistory.shared.records
            let total = records.count
            guard total > 0 else { return "There's no dictation history yet." }

            var scope = ""
            if case .int(let days)? = arguments["days_back"], days > 0 {
                let calendar = Calendar.current
                let cutoff = calendar.startOfDay(
                    for: calendar.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
                records = records.filter { $0.timestamp >= cutoff }
                scope = days == 1 ? " from today" : " from the last \(days) days"
                if records.isEmpty {
                    return "Nothing was dictated\(scope). There are \(total) entries in total."
                }
            }

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short

            let terms = ChatSearch.terms(in: query)
            if terms.isEmpty {
                let shown = records.prefix(10)
                return "The \(shown.count) most recent dictations\(scope) (of \(total)):\n"
                    + shown.map { "\(formatter.string(from: $0.timestamp)): \($0.final)" }
                        .joined(separator: "\n")
            }
            let matches = ChatSearch.rank(records, query: query, limit: 10, text: \.final)
            guard !matches.isEmpty else {
                return "Nothing in the dictation history matches “\(query)”\(scope). "
                    + "There are \(records.count) entries to search — try different words, "
                    + "or ask without a search to see the most recent."
            }
            return matches
                .map { "\(formatter.string(from: $0.timestamp)): \($0.final)" }
                .joined(separator: "\n")

        case "search_journal":
            let daysBack: Int?
            if case .int(let value)? = arguments["days_back"] { daysBack = value } else { daysBack = nil }
            guard let root = journalRoot(settings: settings) else {
                return "There are no journal files yet."
            }
            return JournalArchive(root: root).read(
                query: arguments["query"]?.stringValue ?? "", daysBack: daysBack)

        case "remember_fact":
            let fact = arguments["fact"]?.stringValue ?? ""
            guard !fact.isEmpty else { return "No fact was given, so nothing was stored." }
            let stored = AssistantMemory.shared.remember(fact)
            return stored ? "Stored: \(fact)" : "Already remembered, so nothing changed."

        case "read_screen":
            guard let description = await readScreen() else {
                return "Couldn't read the screen — either nothing was capturable or the loaded model can't read images."
            }
            return description

        default:
            return "ERROR: \(name) isn't a tool Dictator provides."
        }
    }

    /// The fixed directory prefix of the journal path template — everything
    /// before the first `{date placeholder}`.
    static func journalRoot(settings: DictatorSettings) -> URL? {
        let template = settings.journalPathTemplate
        let fixed = template.split(separator: "{", maxSplits: 1,
                                   omittingEmptySubsequences: false).first.map(String.init)
            ?? template
        var path = (fixed as NSString).expandingTildeInPath
        // Trim back to a directory: the fixed part may end mid-filename.
        if !path.hasSuffix("/") {
            path = (path as NSString).deletingLastPathComponent
        }
        guard !path.isEmpty else { return nil }
        let url: URL = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : SyncedStorage.directory.appendingPathComponent(path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return url
    }
}

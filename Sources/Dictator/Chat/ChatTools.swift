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

        tools.append(
            tool(
                name: "create_file",
                displayName: "Save a file",
                detail: "Writes a file into the “Chat Files” folder in your Dictator folder.",
                description: "Save text to a NEW file — notes, Markdown, JSON, CSV, a script. It always goes in the user's “Chat Files” folder; you cannot choose a location. This fails if a file of that name already exists: to change one you have already made, use update_file instead. Give the filename with its extension.",
                parameters: [
                    "name": [
                        "type": "string",
                        "description": "Filename with extension, e.g. meeting-notes.md or data.json. No folders.",
                    ] as [String: any Sendable],
                    "contents": [
                        "type": "string",
                        "description": "The full text to write.",
                    ] as [String: any Sendable],
                ],
                required: ["name", "contents"],
                safe: true
            ))

        tools.append(
            tool(
                name: "list_files",
                displayName: "List this chat's files",
                detail: "Lists the files this conversation has made.",
                description: "List the files in this conversation's folder. Use it before changing a file, or when the user refers to something made earlier in the chat.",
                parameters: [:],
                required: [],
                safe: true
            ))

        tools.append(
            tool(
                name: "read_file",
                displayName: "Read a file",
                detail: "Reads back a file from this conversation.",
                description: "Read a file this conversation made. Do this before updating one — never rewrite a file from memory of what you wrote earlier, because the user may have edited it and earlier messages may no longer be in your context.",
                parameters: [
                    "name": [
                        "type": "string",
                        "description": "The filename, e.g. notes.md.",
                    ] as [String: any Sendable]
                ],
                required: ["name"],
                safe: true
            ))

        tools.append(
            tool(
                name: "update_file",
                displayName: "Update a file",
                detail: "Replaces the contents of a file in this conversation.",
                description: "Change a file this conversation already made. Use this whenever the user asks to change, fix, add to or improve an existing file — read_file first, then send the complete new contents, which replace the file. create_file will refuse a name that already exists, so this is the only way to alter one.",
                parameters: [
                    "name": [
                        "type": "string",
                        "description": "The filename to replace, e.g. notes.md.",
                    ] as [String: any Sendable],
                    "contents": [
                        "type": "string",
                        "description": "The complete new contents. This replaces the file, so include everything that should remain.",
                    ] as [String: any Sendable],
                ],
                required: ["name", "contents"],
                safe: true
            ))

        // Offered only where it can pay for itself: a conversation already
        // long enough to have lost its thread. The measured case for planning
        // is that it helps *weak* models keep a multi-step job on track — and
        // these are the weakest models anyone runs an agent on — but an empty
        // plan on a one-line question is 150 tokens a round buying nothing.
        //
        // Measured in `scratch/plan-follow-check`, 3 adherence scenarios and 10
        // judgement cases across all five catalogue models.
        //
        // **It works where it matters.** Following the right next step, with the
        // conversation's opening request summarised away by compaction:
        // 2/15 without the plan, 11/15 with it injected at the tail. With the
        // history still intact it barely registers (12/15 → 14/15), because the
        // model can just read the original request. Gemma 4 12B gains most —
        // 1/3 without, 3/3 with.
        //
        // **Don't try to stop it over-planning by adding non-examples to this
        // description.** That was measured head to head: adding "no plan for
        // 'what's 17 times 23?'…" scored 39/50 against the current wording's
        // 39/50 — it helped two models by one case and hurt two by one — while
        // costing ~120 prompt tokens every round.
        //
        // It is also the wrong target. Of 22 judgement failures, 17 were the
        // model *not* planning when it should (42% of multi-part jobs) and only
        // 5 were planning when it shouldn't (8% of one-off questions, four of
        // those five on Qwen 3.5 4B). Under-planning costs nothing — you get
        // the behaviour you had before the tool existed — so a conservative
        // tool is the right failure to have, and a description that discourages
        // planning pushes the wrong way.
        if settings.chatPlanningEnabled {
            tools.append(
                tool(
                    name: "update_plan",
                    displayName: "Update the plan",
                    detail: "Keeps a short checklist of what it's working through.",
                    description: "Write or revise the short list of steps you are working through for this conversation. Use it when the user asks for something with several parts, and call it again to tick steps off or change the plan as you learn more. The list is shown back to you on every message, so it is how you remember what you were doing — you do not need to repeat it in your reply. Send the whole list every time: what you send replaces what was there.",
                    parameters: [
                        "steps": [
                            "type": "array",
                            "description": "The full list of steps, in order, replacing any previous list. Keep each one short.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "text": [
                                        "type": "string",
                                        "description": "What the step is, in a few words.",
                                    ] as [String: any Sendable],
                                    "done": [
                                        "type": "boolean",
                                        "description": "True once the step is finished.",
                                    ] as [String: any Sendable],
                                ] as [String: any Sendable],
                                "required": ["text"],
                            ] as [String: any Sendable],
                        ] as [String: any Sendable]
                    ],
                    required: ["steps"],
                    safe: true
                ))
        }

        tools.append(
            tool(
                name: "check_html",
                displayName: "Check a web page works",
                detail: "Opens an HTML file this chat made and reports what's broken in it.",
                description: "Open an .html file you have written and report what is actually wrong with it: CSS rules that match nothing, JavaScript errors, and which elements are visible once it loads. Do this after writing or updating any .html file, and fix what it reports before telling the user it works. You cannot see the page any other way.",
                parameters: [
                    "name": [
                        "type": "string",
                        "description": "The filename to check, e.g. slides.html.",
                    ] as [String: any Sendable]
                ],
                required: ["name"],
                // Reads a file this chat already wrote, in a browser engine
                // that can reach neither the network nor the rest of the disk.
                safe: true
            ))

        tools.append(
            tool(
                name: "delete_file",
                displayName: "Delete a file",
                detail: "Moves a file in this conversation's folder to the Trash.",
                description: "Delete a file from this conversation's folder. It goes to the Trash, so it can be recovered. Only do this when the user has asked for it.",
                parameters: [
                    "name": [
                        "type": "string",
                        "description": "The filename to delete, e.g. notes.md.",
                    ] as [String: any Sendable]
                ],
                required: ["name"],
                // Destructive, so it asks — even though the Trash makes it
                // recoverable. "Tidy up those files" landing on the wrong one
                // is a bad surprise whether or not it can be undone.
                safe: false
            ))

        // Search first, so the model meets the tool that finds an address
        // before the one that opens it.
        if settings.webSearchBackend != .off {
            tools.append(
                tool(
                    name: "web_search",
                    displayName: "Search the web",
                    detail: "Looks up a search query on the web and reads back the results.",
                    // Says nothing about *which* service answers. The backend is
                    // a settings choice and the model must not be able to tell,
                    // or switching it would change how the assistant behaves —
                    // and would move the head of the prompt, which is what
                    // ChatPromptCache depends on staying still.
                    description: "Search the web and get back a list of results — each with a title, an address and a short summary. Use it whenever the answer depends on something current, or on a page whose address you don't know, rather than guessing from memory. The summaries are short and often written to sell something: open the most promising result with fetch_url before relying on the detail.",
                    parameters: [
                        "query": [
                            "type": "string",
                            "description": "What to search for. Use the words you'd type into a search box, not a whole sentence.",
                        ] as [String: any Sendable]
                    ],
                    required: ["query"],
                    // Reads a public web page, like fetch_url, and prompting
                    // before every search would make the assistant tedious in
                    // exactly the way that trains people to click through.
                    // Consent lives in Settings, where the disclosure is.
                    safe: true
                ))
        }

        tools.append(
            tool(
                name: "fetch_url",
                displayName: "Read a web page",
                detail: "Opens a web address and reads the text on it.",
                description: settings.webSearchBackend == .off
                    ? "Fetch a public web page and read its text. Use it when the user gives you a link, or refers to something you'd need to look up on a page you know the address of. You cannot search the web — you can only open an address."
                    : "Fetch a public web page and read its text. Use it when the user gives you a link, and to read a result properly after web_search — the search summaries are too short to answer from.",
                parameters: [
                    "url": [
                        "type": "string",
                        "description": "The full web address, e.g. https://example.com/page.",
                    ] as [String: any Sendable]
                ],
                required: ["url"],
                safe: true
            ))

        // Listed with the names of the user's actual shortcuts, because a tool
        // the model can't see the options for is a tool it won't reach for.
        let shortcuts = ShortcutsBridge.available()
        if !shortcuts.isEmpty {
            let names = shortcuts.prefix(60).map { "“\($0)”" }.joined(separator: ", ")
            tools.append(
                tool(
                    name: "run_shortcut",
                    displayName: "Run a shortcut",
                    detail: "Runs one of the user's own Shortcuts.",
                    description: "Run one of the user's Shortcuts on this Mac and return whatever it produces. This is how you reach Reminders, Calendar, Notes, Home and anything else they have automated. Available shortcuts: \(names). Use the name exactly. Only run one when the user has asked for something it plainly does.",
                    parameters: [
                        "name": [
                            "type": "string",
                            "description": "The exact name of the shortcut to run.",
                        ] as [String: any Sendable],
                        "input": [
                            "type": "string",
                            "description": "Optional text to pass to the shortcut as its input.",
                        ] as [String: any Sendable],
                    ],
                    required: ["name"],
                    // The one built-in that asks. Everything else here reads
                    // the user's own data on their own machine; a shortcut can
                    // do anything they have ever automated — send a message,
                    // move a file, spend money — and it is chosen by a model
                    // that this app's own banner warns confidently invents
                    // things. One click, showing exactly which shortcut and
                    // with what, is proportionate to that.
                    safe: false
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

        case "create_file":
            // Handled by the engine, which needs the structured outcome to
            // attach the file to the transcript.
            return "ERROR: create_file is dispatched by ChatEngine."

        case "web_search":
            return await WebSearcher.search(
                arguments["query"]?.stringValue ?? "", backend: settings.webSearchBackend)

        case "fetch_url":
            return await WebFetcher.fetch(arguments["url"]?.stringValue ?? "")

        case "run_shortcut":
            let name = arguments["name"]?.stringValue ?? ""
            guard !name.isEmpty else { return "No shortcut name was given." }
            return ShortcutsBridge.run(name: name, input: arguments["input"]?.stringValue)

        case "read_screen":
            guard let description = await readScreen() else {
                return "Couldn't read the screen — either nothing was capturable or the loaded model can't read images."
            }
            return description

        default:
            return "ERROR: \(name) isn't a tool Dictator provides."
        }
    }

    /// The journal's root folder. Lives on `JournalWriter` — it's derived from
    /// the path template, which is that type's language — and is reached
    /// through here so the tool and the journal window can't drift apart on
    /// what "the journal" means.
    static func journalRoot(settings: DictatorSettings) -> URL? {
        JournalWriter.root(pathTemplate: settings.journalPathTemplate)
    }
}

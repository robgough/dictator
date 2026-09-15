import Foundation

/// Runs the user's own Shortcuts.
///
/// The highest-leverage tool in the app for the least code: whatever the user
/// has already automated — Reminders, Calendar, Home, Notes, a webhook, an
/// AppleScript they wrapped years ago — becomes reachable without Dictator
/// knowing anything about any of it. It also keeps the surface in the user's
/// hands rather than ours: the assistant can run a shortcut, and the set of
/// shortcuts is theirs to decide.
///
/// `/usr/bin/shortcuts` needs no entitlement and raises no per-app permission
/// prompt of its own — the shortcut asks for whatever *it* needs, when it runs,
/// as it would if the user pressed it themselves.
enum ShortcutsBridge {
    /// Where the CLI lives. Fixed path rather than a `PATH` lookup: this one
    /// ships with macOS and isn't something a user installs elsewhere.
    private static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
    }

    /// Names of every shortcut on this Mac, sorted.
    ///
    /// Read fresh rather than cached: people add shortcuts, and a stale list
    /// makes the assistant claim something doesn't exist when it does.
    static func available() -> [String] {
        guard isAvailable else { return [] }
        guard let output = run(arguments: ["list"], timeout: 5).output else { return [] }
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// Runs one shortcut, optionally with text input, and returns its output.
    ///
    /// Shortcuts are slow to start (the first run in a while can take seconds),
    /// and some legitimately wait on the user, so the timeout is generous — but
    /// it exists, because a shortcut showing a dialog nobody dismisses would
    /// otherwise hang the chat turn forever.
    static func run(name: String, input: String?) -> String {
        guard isAvailable else {
            return "ERROR: the Shortcuts command-line tool isn't available on this Mac."
        }
        let names = available()
        guard let match = resolve(name: name, in: names) else {
            guard !names.isEmpty else { return "ERROR: there are no shortcuts on this Mac." }
            return "ERROR: there's no shortcut called “\(name)”. Available: "
                + names.joined(separator: ", ")
        }

        var arguments = ["run", match]
        var inputURL: URL?
        if let input, !input.isEmpty {
            // The CLI takes input as a file, not an argument.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictator-shortcut-\(UUID().uuidString).txt")
            do {
                try input.write(to: url, atomically: true, encoding: .utf8)
                inputURL = url
                arguments += ["--input-path", url.path]
            } catch {
                return "ERROR: couldn't pass the input to the shortcut: \(error.localizedDescription)"
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictator-shortcut-out-\(UUID().uuidString).txt")
        arguments += ["--output-path", outputURL.path]

        defer {
            if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
            try? FileManager.default.removeItem(at: outputURL)
        }

        let result = run(arguments: arguments, timeout: 90)
        guard result.timedOut == false else {
            return "The shortcut “\(match)” was still running after 90 seconds and was stopped. "
                + "If it asks a question or shows something on screen, it can't be run this way."
        }
        let produced = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if result.status != 0 {
            let detail = result.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "The shortcut “\(match)” failed\(detail.isEmpty ? "." : ": \(detail)")"
        }
        if produced.isEmpty {
            return "Ran “\(match)”. It finished without returning anything, which is normal for "
                + "a shortcut that just does something."
        }
        return "“\(match)” returned:\n\(produced)"
    }

    /// Matches a shortcut name the way a person would: exactly, then ignoring
    /// case, then uniquely by prefix. A model asking for "daily journal" should
    /// find "Daily Journal 2" rather than being told it doesn't exist.
    static func resolve(name: String, in names: [String]) -> String? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        if let exact = names.first(where: { $0 == wanted }) { return exact }
        let lowered = wanted.lowercased()
        if let caseless = names.first(where: { $0.lowercased() == lowered }) { return caseless }
        let prefixed = names.filter { $0.lowercased().hasPrefix(lowered) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    // MARK: - Process

    private static func run(
        arguments: [String], timeout: TimeInterval
    ) -> (status: Int32, output: String?, error: String?, timedOut: Bool) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return (-1, nil, error.localizedDescription, false)
        }

        // Read before waiting: a shortcut that writes more than a pipe buffer
        // would otherwise block forever with us waiting on exit.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return (-1, nil, nil, true)
        }

        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8),
            String(data: errData, encoding: .utf8),
            false
        )
    }
}

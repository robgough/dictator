import Foundation

/// One user-configured MCP server.
///
/// Stored per-Mac, never in the synced folder: a config is a `command` that is
/// an absolute path to a binary plus arguments that are usually absolute paths
/// too. Carrying `/opt/homebrew/bin/uvx` to a Mac that installs into
/// `/usr/local` produces a server that silently fails to launch, which is worse
/// than having to add it again.
///
/// `environment` holds only the NAMES of the variables. Values live in the
/// keychain (see `MCPSecrets`), because MCP servers are where API tokens go —
/// `GITHUB_TOKEN`, `SLACK_BOT_TOKEN` and friends — and CLAUDE.md's one
/// non-negotiable rule is that no secret is ever written into a `Codable`
/// settings struct.
struct MCPServerConfig: Codable, Identifiable, Hashable, Sendable {
    /// Which transport this server speaks.
    enum Kind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        /// A program on this Mac, spoken to over its stdin/stdout.
        case stdio
        /// A URL, over Streamable HTTP. Hosted or remote servers.
        case http

        var id: Self { self }
        var label: String {
            switch self {
            case .stdio: "Program on this Mac"
            case .http: "Web address"
            }
        }
    }

    var id: UUID
    /// Defaulted so configs written before web servers existed decode as stdio.
    var kind: Kind = .stdio
    /// The MCP endpoint, for `.http`. Ignored for `.stdio`.
    var url: String = ""
    /// Shown in the UI and used to namespace this server's tools.
    var name: String
    /// Executable. An absolute path is strongly preferred; a bare name is
    /// resolved against `MCPEnvironment.searchPaths` at launch.
    var command: String
    var arguments: [String]
    /// Secret names whose values are in the keychain.
    ///
    /// Means two things depending on `kind`, which is why the name is vague:
    /// environment variables for a `.stdio` subprocess, HTTP header names for a
    /// `.http` endpoint (so `Authorization` → `Bearer …` is just a row). Either
    /// way only the *names* are written to disk.
    var environmentKeys: [String]
    var workingDirectory: String?
    var isEnabled: Bool
    /// Tools the user has said "always allow" for, by their un-namespaced name.
    /// Only consulted when `requiresApproval` is on.
    var autoApprovedTools: Set<String>
    /// Ask before each of this server's tools runs.
    ///
    /// Off by default. A server only exists here because the user typed its
    /// command in themselves, which is a stronger act of consent than clicking
    /// through a dialog per call — and prompting on every call is how you train
    /// someone to approve without reading. Available per server so a genuinely
    /// dangerous one (anything that writes, deploys, or spends money) can be
    /// switched back to asking.
    var requiresApproval: Bool

    init(
        id: UUID = UUID(),
        kind: Kind = .stdio,
        name: String = "",
        url: String = "",
        command: String = "",
        arguments: [String] = [],
        environmentKeys: [String] = [],
        workingDirectory: String? = nil,
        isEnabled: Bool = true,
        autoApprovedTools: Set<String> = [],
        requiresApproval: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
        self.command = command
        self.arguments = arguments
        self.environmentKeys = environmentKeys
        self.workingDirectory = workingDirectory
        self.isEnabled = isEnabled
        self.autoApprovedTools = autoApprovedTools
        self.requiresApproval = requiresApproval
    }

    /// Prefix for this server's tools when they're merged into one list for the
    /// model. The spec recommends disambiguating because two servers can each
    /// expose `search`, and warns that `serverInfo.name` is not unique — so we
    /// key on our own id, not on anything the server told us.
    var toolNamespace: String {
        "mcp\(id.uuidString.prefix(8).lowercased())"
    }

    /// Cheap sanity check for the Settings row, so a half-typed server doesn't
    /// get connected to on every app start.
    var isRunnable: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .stdio:
            return !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http:
            let trimmed = url.trimmingCharacters(in: .whitespaces)
            guard let parsed = URL(string: trimmed), let scheme = parsed.scheme?.lowercased()
            else { return false }
            return scheme == "http" || scheme == "https"
        }
    }

    /// One-line summary for the Settings row.
    var subtitle: String {
        switch kind {
        case .stdio: ([command] + arguments).joined(separator: " ")
        case .http: url
        }
    }
}

/// Keychain storage for MCP server environment values.
///
/// Mirrors `DictatorMeetings`' `KeychainStore` — generic passwords under this
/// app's bundle id, account keyed by server and variable. Separate from the
/// Meetings store because they're different apps with different services, and
/// a Dictator build must never be able to read a Meetings provider key.
enum MCPSecrets {
    static let service = "net.robgough.Dictator"

    private static func account(server: UUID, key: String) -> String {
        "mcp.\(server.uuidString).env.\(key)"
    }

    static func value(server: UUID, key: String) -> String? {
        if ScreenshotMode.isActive { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(server: server, key: key),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func setValue(_ value: String, server: UUID, key: String) {
        if ScreenshotMode.isActive { return }
        remove(server: server, key: key)
        guard !value.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(server: server, key: key),
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[Dictator] Couldn't store MCP secret \(key): OSStatus \(status)")
        }
    }

    static func remove(server: UUID, key: String) {
        if ScreenshotMode.isActive { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(server: server, key: key),
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func has(server: UUID, key: String) -> Bool {
        value(server: server, key: key) != nil
    }

    /// Drop every secret belonging to a server the user deleted.
    static func removeAll(server: UUID, keys: [String]) {
        for key in keys { remove(server: server, key: key) }
    }
}

/// Where to look for an MCP server binary, and what environment to give it.
enum MCPEnvironment {
    /// A GUI app launched by Launch Services inherits a minimal `PATH` —
    /// typically just `/usr/bin:/bin:/usr/sbin:/sbin`. Practically every MCP
    /// server is `npx`, `uvx`, `node`, `python3` or a Homebrew binary, none of
    /// which live there. Without this, every server a user adds fails to launch
    /// with "No such file or directory" and the app looks broken.
    static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/homebrew/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.bun/bin",
        NSHomeDirectory() + "/.cargo/bin",
        NSHomeDirectory() + "/.volta/bin",
    ]

    /// Resolves `command` to something `Process` can execute. Absolute paths
    /// pass through; a bare name is looked up on `searchPaths`. Returns nil when
    /// nothing executable is found, so the caller can say which command was
    /// missing rather than surfacing a POSIX errno.
    static func resolve(command: String) -> URL? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let manager = FileManager.default
        if trimmed.hasPrefix("/") {
            return manager.isExecutableFile(atPath: trimmed)
                ? URL(fileURLWithPath: trimmed) : nil
        }
        if trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return manager.isExecutableFile(atPath: expanded)
                ? URL(fileURLWithPath: expanded) : nil
        }
        for directory in searchPaths {
            let candidate = directory + "/" + trimmed
            if manager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Header name/value pairs for an `.http` server, read from the keychain.
    ///
    /// `Authorization` is the one almost every hosted server wants, and it's
    /// just a row here rather than a special case — a user pastes
    /// `Bearer sk-…` and it never touches a settings file.
    static func httpHeaders(for config: MCPServerConfig) -> [(String, String)] {
        config.environmentKeys.compactMap { key in
            guard let value = MCPSecrets.value(server: config.id, key: key) else { return nil }
            return (key, value)
        }
    }

    /// The environment to launch a server with: this process's environment,
    /// a `PATH` widened to `searchPaths`, plus the server's own keychain values.
    static func environment(for config: MCPServerConfig) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let merged = (searchPaths + existing).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        for key in config.environmentKeys {
            if let value = MCPSecrets.value(server: config.id, key: key) {
                env[key] = value
            }
        }
        return env
    }
}

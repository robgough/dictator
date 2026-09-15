import Foundation
import Observation

/// Every configured MCP server, their live clients, and the merged tool list.
///
/// Servers are started **lazily** — the first time a chat turn actually needs
/// the tool list — not at app launch. Dictator is a menu-bar app that sits
/// there all day; spawning a handful of Node processes at login to serve a
/// window the user may never open is not a reasonable thing to do to someone's
/// Mac.
@MainActor
@Observable
final class MCPRegistry {
    static let shared = MCPRegistry()

    /// What the Settings UI shows per server.
    enum Status: Equatable, Sendable {
        case idle
        case starting
        case ready(toolCount: Int)
        case failed(String)

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    private(set) var servers: [MCPServerConfig] = []
    private(set) var statuses: [UUID: Status] = [:]

    /// Live clients, keyed by server id. Observation-ignored: an actor handle
    /// isn't a rendered value, and tracking it would churn the UI on every
    /// connection change.
    @ObservationIgnored private var clients: [UUID: MCPClient] = [:]
    /// Tools discovered per server, cached so rendering the Settings list
    /// doesn't have to await an actor.
    private(set) var discoveredTools: [UUID: [MCPToolDescriptor]] = [:]

    private static var storeURL: URL {
        // Per-Mac, never synced: a config is an absolute path to a binary, and
        // carrying it to another Mac produces a server that silently won't run.
        AppSupportPaths.dictator.appendingPathComponent("mcp-servers.json")
    }

    private init() {
        load()
    }

    // MARK: - Configuration

    func addServer(_ config: MCPServerConfig) {
        servers.append(config)
        persist()
    }

    func updateServer(_ config: MCPServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else { return }
        let previous = servers[index]
        servers[index] = config
        persist()
        // Anything that changes how the server is launched invalidates the
        // running one. Auto-approval changes don't.
        let launchChanged = previous.command != config.command
            || previous.arguments != config.arguments
            || previous.workingDirectory != config.workingDirectory
            || previous.environmentKeys != config.environmentKeys
            || previous.isEnabled != config.isEnabled
        if launchChanged {
            Task { await self.shutdown(id: config.id) }
        }
    }

    func removeServer(id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        let config = servers.remove(at: index)
        MCPSecrets.removeAll(server: id, keys: config.environmentKeys)
        persist()
        Task { await self.shutdown(id: id) }
    }

    func server(id: UUID) -> MCPServerConfig? {
        servers.first(where: { $0.id == id })
    }

    /// Marks a tool as always-allowed for its server.
    func autoApprove(toolName: String, serverID: UUID) {
        guard var config = server(id: serverID) else { return }
        config.autoApprovedTools.insert(toolName)
        updateServer(config)
    }

    // MARK: - Lifecycle

    /// Starts every enabled server that isn't running yet and returns the
    /// merged tool list. Failures are recorded per server and don't stop the
    /// others — one broken config shouldn't cost the user every tool.
    @discardableResult
    func connectAll() async -> [ChatTool] {
        for config in servers where config.isEnabled && config.isRunnable {
            if clients[config.id] == nil {
                await start(config)
            }
        }
        return tools()
    }

    private func start(_ config: MCPServerConfig) async {
        statuses[config.id] = .starting
        let client: MCPClient
        do {
            // Throws when an http server's URL doesn't parse — worth saying
            // plainly rather than letting it fail later as a connection error.
            client = try MCPClient(config: config)
        } catch {
            statuses[config.id] = .failed(error.localizedDescription)
            discoveredTools[config.id] = []
            return
        }
        do {
            try await client.start()
            let tools = await client.tools
            clients[config.id] = client
            discoveredTools[config.id] = tools
            statuses[config.id] = .ready(toolCount: tools.count)
        } catch {
            statuses[config.id] = .failed(error.localizedDescription)
            discoveredTools[config.id] = []
            await client.stop()
            NSLog("[Dictator] MCP server “\(config.name)” failed: \(error.localizedDescription)")
        }
    }

    /// Starts one server and reports the outcome — the Settings "Test" button.
    func testConnection(_ config: MCPServerConfig) async {
        await shutdown(id: config.id)
        await start(config)
    }

    func shutdown(id: UUID) async {
        guard let client = clients.removeValue(forKey: id) else {
            statuses[id] = .idle
            return
        }
        await client.stop()
        discoveredTools[id] = []
        statuses[id] = .idle
    }

    /// Stops every server. Called on quit so no Node process outlives the app.
    func shutdownAll() async {
        let ids = Array(clients.keys)
        for id in ids { await shutdown(id: id) }
    }

    // MARK: - Tools

    /// The merged, namespaced tool list.
    ///
    /// Names are prefixed with the server's own id-derived namespace because
    /// two servers can each expose `search`, and the spec is explicit that
    /// `serverInfo.name` is not unique enough to disambiguate with.
    func tools() -> [ChatTool] {
        var merged: [ChatTool] = []
        for config in servers where config.isEnabled {
            for descriptor in discoveredTools[config.id] ?? [] {
                let namespaced = "\(config.toolNamespace)__\(descriptor.name)"
                merged.append(
                    ChatTool(
                        name: namespaced,
                        displayName: descriptor.displayName,
                        detail: descriptor.description,
                        spec: MCPJSON.toolSpec(
                            name: namespaced,
                            description: descriptor.description,
                            inputSchema: descriptor.inputSchema
                        ),
                        serverID: config.id,
                        serverName: config.name,
                        // Runs without asking unless the user switched this
                        // server back to prompting — see
                        // `MCPServerConfig.requiresApproval`.
                        isSafeWithoutApproval: !config.requiresApproval
                            || config.autoApprovedTools.contains(descriptor.name)
                    ))
            }
        }
        return merged
    }

    /// Invokes a namespaced tool on whichever server owns it.
    func callTool(namespacedName: String, arguments: MCPJSON) async throws -> MCPToolResult {
        guard let (config, bareName) = resolve(namespacedName: namespacedName) else {
            throw MCPError.malformed("no server owns the tool “\(namespacedName)”")
        }
        guard let client = clients[config.id] else {
            throw MCPError.transportClosed("“\(config.name)” isn't connected.")
        }
        return try await client.callTool(name: bareName, arguments: arguments)
    }

    /// Splits a namespaced name back into its server and bare tool name.
    func resolve(namespacedName: String) -> (MCPServerConfig, String)? {
        guard let separator = namespacedName.range(of: "__") else { return nil }
        let namespace = String(namespacedName[..<separator.lowerBound])
        let bare = String(namespacedName[separator.upperBound...])
        guard let config = servers.first(where: { $0.toolNamespace == namespace }) else { return nil }
        return (config, bare)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data)
        else { return }
        servers = decoded
        for config in decoded { statuses[config.id] = .idle }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: Self.storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(servers).write(to: Self.storeURL, options: .atomic)
        } catch {
            NSLog("[Dictator] Couldn't save MCP servers: \(error)")
        }
    }
}

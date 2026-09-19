import SwiftUI

/// Chat settings: what the chat window can do, and which MCP servers it can
/// reach.
struct ChatPane: View {
    @Environment(AppState.self) private var state
    @State private var registry = MCPRegistry.shared
    @State private var editing: MCPServerConfig?
    @State private var testing: Set<UUID> = []
    @State private var exaKey = ""
    @State private var exaKeyIsStored = SearchSecrets.has(.exa)
    @State private var searchTest: String?
    @State private var isTestingSearch = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                availability
                builtInTools
                planning
                webSearch
                mcpServers
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { config in
            MCPServerEditor(config: config) { saved in
                if registry.server(id: saved.id) == nil {
                    registry.addServer(saved)
                } else {
                    registry.updateServer(saved)
                }
            }
        }
    }

    // MARK: - Availability

    @ViewBuilder
    private var availability: some View {
        let availability = ChatAvailability.current(settings: state.settings)
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isReady(availability) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isReady(availability) ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isReady(availability) ? "Chat is ready" : "Chat is unavailable")
                        .font(.callout.weight(.medium))
                    Text(availabilityDetail(availability))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isReady(availability) {
                    Button("Open Chat…") { ChatWindowController.shared.show() }
                }
            }
            .padding(6)
        }
    }

    private func isReady(_ availability: ChatAvailability) -> Bool {
        if case .ready = availability { return true }
        return false
    }

    private func availabilityDetail(_ availability: ChatAvailability) -> String {
        switch availability {
        case .ready:
            let name = ModelCatalog.llm(id: state.settings.llmModelID)?.displayName
                ?? state.settings.llmModelID
            return "Using \(name). Open it from the menu bar, by clicking Dictator in the Dock, or with ⌘-click on this button."
        case .unavailable:
            return "Chat needs one of the models that's been tested for it: "
                + ChatAvailability.capableModelNames.joined(separator: ", ")
                + ". Pick one in Models."
        }
    }

    // MARK: - Built-in tools

    private var builtInTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What the assistant can do")
                .font(.headline)
            Text("The chat assistant can use these without you setting anything up. They run on this Mac, on your own data — apart from searching and opening web pages, which is covered below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let tools = BuiltInChatTools.all(
                settings: state.settings,
                canReadScreen: WindowVisionContext.canReadImages
            )
            ForEach(tools, id: \.name) { tool in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.displayName).font(.callout)
                        Text(tool.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            let remoteCount = registry.discoveredTools.values.reduce(0) { $0 + $1.count }
            if remoteCount + tools.count > ChatToolset.deferAboveToolCount {
                Label(
                    "\(remoteCount + tools.count) tools are connected. Above \(ChatToolset.deferAboveToolCount), Dictator stops sending every tool's description to the model on every reply — it searches them instead, which keeps long conversations fast and leaves room in the model's context for the conversation itself.",
                    systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            if !WindowVisionContext.canReadImages {
                Text(WindowVisionContext.osSupportsAppleVision
                     ? "Reading the screen needs a model that can see images — Apple's on-device model, or \(ModelCatalog.llmModels.filter(\.visionCapable).map(\.displayName).joined(separator: " or ")). Chat tools only run on MLX, so pick one of the latter here."
                     : "Reading the screen needs a model that can see images — \(ModelCatalog.llmModels.filter(\.visionCapable).map(\.displayName).joined(separator: " or ")).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Planning

    @ViewBuilder
    private var planning: some View {
        @Bindable var bindable = state
        VStack(alignment: .leading, spacing: 8) {
            Text("Working through several steps")
                .font(.headline)
            Toggle("Let the assistant keep a checklist", isOn: $bindable.settings.chatPlanningEnabled)
                .onChange(of: bindable.settings.chatPlanningEnabled) { _, _ in state.save() }
            Text("When you ask for something with several parts, the assistant writes down the steps and ticks them off as it goes. The list is shown back to it with every message, so it doesn't lose track halfway through — and unlike notes in the conversation, it survives the summarising that happens in a long chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Web search

    @ViewBuilder
    private var webSearch: some View {
        @Bindable var bindable = state
        VStack(alignment: .leading, spacing: 8) {
            Text("Searching the web")
                .font(.headline)

            Picker("Search with", selection: $bindable.settings.webSearchBackend) {
                ForEach(SearchBackend.allCases) { backend in
                    Text(backend.label).tag(backend)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: bindable.settings.webSearchBackend) { _, backend in
                state.save()
                searchTest = nil
                // Don't leave a browser engine resident for a backend that is
                // no longer selected.
                if backend != .duckDuckGo { DuckDuckGoLiteSearch.shared.shutDown() }
            }

            Text(state.settings.webSearchBackend.disclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.settings.webSearchBackend == .exa {
                HStack {
                    SecureField(
                        exaKeyIsStored ? "Saved — type to replace" : "Exa API key",
                        text: $exaKey)
                        .frame(maxWidth: 320)
                    Button("Save") {
                        SearchSecrets.setValue(exaKey, for: .exa)
                        exaKey = ""
                        exaKeyIsStored = SearchSecrets.has(.exa)
                        searchTest = nil
                    }
                    .disabled(exaKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if exaKeyIsStored {
                        Button("Remove") {
                            SearchSecrets.remove(.exa)
                            exaKeyIsStored = false
                            searchTest = nil
                        }
                    }
                }
                Text("Stored in your Mac's keychain, never in Dictator's settings files — so the folder sync can't carry it into iCloud Drive or Dropbox. Get a key from exa.ai.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.settings.webSearchBackend != .off {
                HStack(spacing: 8) {
                    Button("Test search…") { runSearchTest() }
                        .controlSize(.small)
                        .disabled(isTestingSearch)
                    if isTestingSearch { ProgressView().controlSize(.small) }
                    if let searchTest {
                        Text(searchTest)
                            .font(.caption)
                            .foregroundStyle(searchTest.hasPrefix("ERROR") ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// Runs one real search, because the failures worth catching here — a
    /// rejected key, a challenge page, no network — only show up against the
    /// live service.
    private func runSearchTest() {
        isTestingSearch = true
        searchTest = nil
        Task {
            let output = await WebSearcher.search(
                "what day is it today", backend: state.settings.webSearchBackend)
            isTestingSearch = false
            if output.hasPrefix("ERROR") {
                searchTest = output
            } else {
                let hosts = output
                    .split(separator: "\n")
                    .compactMap { line -> String? in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("http"),
                              let host = URL(string: trimmed)?.host
                        else { return nil }
                        return host
                    }
                searchTest = hosts.isEmpty
                    ? "Search worked."
                    : "Search worked — \(hosts.count) results, including \(hosts.prefix(2).joined(separator: ", "))."
            }
        }
    }

    // MARK: - MCP

    private var mcpServers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MCP servers").font(.headline)
                Spacer()
                Button {
                    editing = MCPServerConfig()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .controlSize(.small)
            }
            Text("Model Context Protocol servers give the assistant extra tools — your files, a database, an API. They can be a program on this Mac or a web address. Either way the setup stays on this Mac and is never synced to your other machines. Their tools run without asking; switch a server to “Ask first” if it can do something you'd want to confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if registry.servers.isEmpty {
                Text("None yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            }

            ForEach(registry.servers) { server in
                MCPServerRow(
                    server: server,
                    status: registry.statuses[server.id] ?? .idle,
                    isTesting: testing.contains(server.id),
                    onEdit: { editing = server },
                    onTest: { test(server) },
                    onRemove: { registry.removeServer(id: server.id) },
                    onToggle: { enabled in
                        var updated = server
                        updated.isEnabled = enabled
                        registry.updateServer(updated)
                    },
                    onApprovalChange: { asks in
                        var updated = server
                        updated.requiresApproval = asks
                        registry.updateServer(updated)
                    }
                )
            }
        }
    }

    private func test(_ server: MCPServerConfig) {
        testing.insert(server.id)
        Task {
            await registry.testConnection(server)
            testing.remove(server.id)
        }
    }
}

private struct MCPServerRow: View {
    let server: MCPServerConfig
    let status: MCPRegistry.Status
    let isTesting: Bool
    let onEdit: () -> Void
    let onTest: () -> Void
    let onRemove: () -> Void
    let onToggle: (Bool) -> Void
    let onApprovalChange: (Bool) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle(
                        "",
                        isOn: Binding(get: { server.isEnabled }, set: onToggle)
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    Text(server.name.isEmpty ? "Untitled server" : server.name)
                        .font(.callout.weight(.medium))
                    if server.kind == .http {
                        Image(systemName: "globe")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Connects over the web")
                    }
                    Spacer()
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Toggle("Ask first", isOn: Binding(
                        get: { server.requiresApproval }, set: onApprovalChange))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help("Confirm before each of this server's tools runs")
                    Button("Test", action: onTest).controlSize(.small)
                    Button("Edit", action: onEdit).controlSize(.small)
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                }

                Text(server.subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                statusLine
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            Text("Not connected. It starts the first time a chat needs it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .starting:
            Text("Connecting…").font(.caption2).foregroundStyle(.secondary)
        case .ready(let count):
            Label("\(count) tool\(count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

import SwiftUI

/// Add / edit one MCP server.
///
/// Environment variables get their own treatment because that's where tokens
/// live. The *names* go in the config file; the values go straight to the
/// keychain and are never read back into the field — the row says "Saved"
/// instead. Same posture as Dictator Meetings' provider keys, and for the same
/// reason: a synced settings file must never be able to carry a secret.
struct MCPServerEditor: View {
    @State var config: MCPServerConfig
    let onSave: (MCPServerConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var argumentText: String = ""
    @State private var envRows: [EnvRow] = []

    struct EnvRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
        /// True when a value is already in the keychain and hasn't been retyped.
        var isStored: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $config.name, prompt: Text("GitHub"))
                    Picker("Kind", selection: $config.kind) {
                        ForEach(MCPServerConfig.Kind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                }

                if config.kind == .http {
                    Section {
                        TextField(
                            "Address", text: $config.url,
                            prompt: Text("https://example.com/mcp"))
                    } header: {
                        Text("Server")
                    } footer: {
                        Text("The server's MCP endpoint. Dictator speaks Streamable HTTP; if a server only offers the older SSE transport it won't connect. Most hosted servers need a token — add it below as an Authorization header.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TextField(
                            "Command", text: $config.command,
                            prompt: Text("/opt/homebrew/bin/npx"))
                        TextField(
                            "Arguments", text: $argumentText,
                            prompt: Text("-y @modelcontextprotocol/server-github"))
                    } header: {
                        Text("Program")
                    } footer: {
                        Text("Use the full path to the program. Dictator is launched by macOS, not from your shell, so it doesn't inherit your PATH — a bare `npx` usually won't be found. Arguments are separated by spaces.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach($envRows) { $row in
                        HStack {
                            TextField("NAME", text: $row.key)
                                .frame(width: 150)
                            SecureField(
                                row.isStored ? "Saved — type to replace" : "value",
                                text: $row.value)
                            Button {
                                envRows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        envRows.append(EnvRow(key: "", value: "", isStored: false))
                    } label: {
                        Label("Add variable", systemImage: "plus")
                    }
                    .controlSize(.small)
                } header: {
                    Text(config.kind == .http ? "Headers" : "Environment")
                } footer: {
                    Text(config.kind == .http
                         ? "Sent as HTTP headers on every request — usually one called Authorization with a value like “Bearer sk-…”. Values are stored in your Mac's keychain, never in Dictator's settings files."
                         : "Values are stored in your Mac's keychain, never in Dictator's settings files, so they can't be carried into iCloud Drive or Dropbox by the folder sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if config.kind == .stdio {
                    Section {
                        TextField(
                            "Working directory",
                            text: Binding(
                                get: { config.workingDirectory ?? "" },
                                set: { config.workingDirectory = $0.isEmpty ? nil : $0 }
                            ),
                            prompt: Text("Optional"))
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(14)
        }
        .frame(width: 540, height: 480)
        .onAppear(perform: load)
    }

    private var isValid: Bool {
        var candidate = config
        candidate.command = config.command.trimmingCharacters(in: .whitespaces)
        candidate.url = config.url.trimmingCharacters(in: .whitespaces)
        return candidate.isRunnable
    }

    private func load() {
        argumentText = config.arguments.joined(separator: " ")
        envRows = config.environmentKeys.map {
            EnvRow(key: $0, value: "", isStored: MCPSecrets.has(server: config.id, key: $0))
        }
    }

    private func save() {
        var saved = config
        saved.name = config.name.trimmingCharacters(in: .whitespaces)
        saved.command = config.command.trimmingCharacters(in: .whitespaces)
        saved.url = config.url.trimmingCharacters(in: .whitespaces)
        saved.arguments = argumentText
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)

        let rows = envRows.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        saved.environmentKeys = rows.map { $0.key.trimmingCharacters(in: .whitespaces) }

        // Drop keychain items for variables the user removed, so a deleted
        // token doesn't linger in the keychain forever.
        for removed in Set(config.environmentKeys).subtracting(saved.environmentKeys) {
            MCPSecrets.remove(server: saved.id, key: removed)
        }
        // Only write values that were actually typed — an untouched "Saved"
        // field must not overwrite the stored secret with an empty string.
        for row in rows where !row.value.isEmpty {
            MCPSecrets.setValue(
                row.value, server: saved.id,
                key: row.key.trimmingCharacters(in: .whitespaces))
        }

        onSave(saved)
        dismiss()
    }
}

import SwiftUI

/// Thread list. Newest first, grouped by how recent they are — a flat list of
/// 200 rows all looking the same is hard to scan once someone has actually
/// been using this.
struct ChatSidebar: View {
    @Bindable var shell: ChatShellModel
    @Environment(AppState.self) private var state
    @State private var store = ChatStore.shared
    @State private var confirmClearAll = false
    /// Thread the user asked to delete, held while we ask what to do with its
    /// files. Tying file lifetime to the chat is only fair if the destructive
    /// half is visible at the moment of deleting.
    @State private var pendingDelete: ChatThread?

    var body: some View {
        List(selection: selectionBinding) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.threads) { thread in
                        ChatSidebarRow(thread: thread)
                            .tag(thread.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    requestDelete(thread)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.threads.allSatisfy(\.isEmpty) {
                ContentUnavailableView(
                    "No chats yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start one with the button in the toolbar. Conversations from the Assistant hotkey show up here too.")
                )
                .allowsHitTesting(false)
            }
        }
        // A footer needs a surface of its own. `safeAreaInset` reserves the
        // space so the last row can still be scrolled clear of it, but rows
        // travelling past on their way up are drawn *behind* it — and with a
        // transparent button that reads as the label sitting on top of a
        // conversation title, which is what it looked like.
        //
        // The divider and the bar material are what a sidebar footer is
        // supposed to be on macOS; they also mark where the list stops, which
        // this was missing even when nothing was scrolling through it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !store.threads.filter({ !$0.isEmpty }).isEmpty {
                VStack(spacing: 0) {
                    Divider()
                    Button(role: .destructive) {
                        confirmClearAll = true
                    } label: {
                        Label("Clear all conversations", systemImage: "trash")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            // The whole strip, not just the words — a footer
                            // button people have to aim at is a worse footer.
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(.bar)
            }
        }
        .confirmationDialog(
            deletePrompt,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let thread = pendingDelete {
                Button("Delete Chat and Files", role: .destructive) {
                    delete(thread, includingFiles: true)
                    pendingDelete = nil
                }
                Button("Delete Chat, Keep Files") {
                    delete(thread, includingFiles: false)
                    pendingDelete = nil
                }
            }
        } message: {
            if let thread = pendingDelete, let folder = thread.filesFolderName {
                Text("The files are in “Chat Files/\(folder)” in your Dictator folder. Keeping them leaves them there.")
            }
        }
        .confirmationDialog(
            "Delete every conversation?",
            isPresented: $confirmClearAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                // Conversations go; files stay. Deleting every conversation is
                // a tidy-up gesture, and silently taking a folder of documents
                // with it is not what anybody means by it.
                store.removeAll()
                ChatWindowController.shared.newThread()
            }
        } message: {
            Text("Every conversation goes, including ones from the Assistant hotkey. Any files they made stay in your Chat Files folder.")
        }
    }

    /// Selection goes through the controller rather than straight to the model
    /// so switching threads also repoints the engine and re-checks the model.
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { shell.selectedThreadID },
            set: { newValue in
                guard let newValue else { return }
                ChatWindowController.shared.select(threadID: newValue)
            }
        )
    }

    /// Deletes straight away when there's nothing to lose; asks when there is.
    private func requestDelete(_ thread: ChatThread) {
        if ChatFiles.files(in: thread).isEmpty {
            delete(thread, includingFiles: false)
        } else {
            pendingDelete = thread
        }
    }

    private func delete(_ thread: ChatThread, includingFiles: Bool) {
        if includingFiles { ChatFiles.deleteFolder(for: thread) }
        store.remove(id: thread.id)
        if shell.selectedThreadID == thread.id {
            if let next = store.threads.first {
                ChatWindowController.shared.select(threadID: next.id)
            } else {
                ChatWindowController.shared.newThread()
            }
        }
    }

    private var deletePrompt: String {
        guard let thread = pendingDelete else { return "Delete this chat?" }
        let count = ChatFiles.files(in: thread).count
        return "Delete this chat and its \(count) file\(count == 1 ? "" : "s")?"
    }

    private struct Group {
        let title: String
        let threads: [ChatThread]
    }

    /// Today / Previous 7 days / Earlier. Empty threads are hidden — a "New
    /// chat" you haven't typed into yet shouldn't take a row.
    private var groups: [Group] {
        let calendar = Calendar.current
        let now = Date()
        var today: [ChatThread] = []
        var week: [ChatThread] = []
        var earlier: [ChatThread] = []

        for thread in store.threads where !thread.isEmpty {
            if calendar.isDateInToday(thread.updatedAt) {
                today.append(thread)
            } else if let days = calendar.dateComponents(
                [.day], from: thread.updatedAt, to: now).day, days < 7 {
                week.append(thread)
            } else {
                earlier.append(thread)
            }
        }

        return [
            Group(title: "Today", threads: today),
            Group(title: "Previous 7 days", threads: week),
            Group(title: "Earlier", threads: earlier),
        ].filter { !$0.threads.isEmpty }
    }
}

private struct ChatSidebarRow: View {
    let thread: ChatThread

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 13, height: 15)
                .help(originHelp)

            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .lineLimit(1)
                    .font(.system(size: 13))
                if let reply = thread.lastAssistantReply, !reply.isEmpty {
                    Text(reply)
                        .lineLimit(1)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Which way in this thread started.
    ///
    /// Both origins get a glyph rather than marking only the unusual one: with
    /// a badge on some rows and nothing on others, a plain row reads as "not
    /// loaded yet" rather than "typed". The wand and the indigo are the
    /// assistant's everywhere else in the app — the HUD, the island, the
    /// Settings sidebar — so this needs no legend.
    private var icon: String {
        thread.origin == .assistant ? "wand.and.stars" : "bubble.left.and.bubble.right"
    }

    private var tint: Color {
        thread.origin == .assistant ? CaptureKind.assistant.tint : .secondary
    }

    private var originHelp: String {
        thread.origin == .assistant
            ? "Started with the Assistant hotkey"
            : "Started in this window"
    }
}

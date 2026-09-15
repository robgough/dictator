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
                    description: Text("Start one with the button in the toolbar.")
                )
                .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.threads.filter({ !$0.isEmpty }).isEmpty {
                Button(role: .destructive) {
                    confirmClearAll = true
                } label: {
                    Label("Clear all chats", systemImage: "trash")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
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
            "Delete every chat?",
            isPresented: $confirmClearAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                // Chats go; files stay. Deleting every conversation is a
                // tidy-up gesture, and silently taking a folder of documents
                // with it is not what anybody means by it.
                store.removeAll()
                ChatWindowController.shared.newThread()
            }
        } message: {
            Text("The chats go. Any files they made stay in your Chat Files folder.")
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
        .padding(.vertical, 2)
    }
}

import PhotosUI
import SwiftUI
import UIKit

/// The Journal tab: one day of the journal as a page, the mic to add to
/// today. Reads and writes the same Markdown files as the Mac's journal
/// window (see `JournalModel`), and is drawn the same way: a serif date,
/// the time in the margin, words on paper. No cards or grouped rows,
/// because a journal has one author and is read top to bottom.
struct JournalView: View {
    @Bindable var viewModel: RecordingViewModel
    /// Opens Settings: the top-bar gear, and connecting a shared folder.
    var onOpenSettings: () -> Void
    /// The mic and camera are in the tab bar's bottom accessory (an
    /// iPhone's bottom tab bar), so the page's own bar only holds Undo.
    var controlsInAccessory = false

    @State private var model = JournalModel.shared
    @State private var composing = false
    @State private var editing: JournalArchive.Entry?
    @State private var confirmingDelete: JournalArchive.Entry?
    @State private var choosingDay = false
    @State private var query = ""
    @State private var searching = false
    /// The calendar column's own search field.
    @FocusState private var columnSearchFocused: Bool
    @State private var hits: [JournalModel.SearchHit] = []
    @State private var capturing = false
    @State private var capturedPhoto: CapturedPhoto?
    @State private var choosingPhotos = false
    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var viewingPhoto: URL?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // The day page is the main content. On a wide window the calendar
        // and search sit in a column beside it; narrower, the calendar is a
        // sheet from the top bar and search is the page's own search field.
        AdaptiveColumns(onCompanionChange: { shown in
            if shown { choosingDay = false }
        }) { finderShown in
            pageStack(finderShown: finderShown)
        } companion: {
            finderColumn
        }
        .task(id: query) {
            // A short pause so a word being typed isn't searched
            // a letter at a time.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            hits = await model.search(query)
        }
    }

    /// The calendar and search, as a column beside the page: the search
    /// field pinned at the top, the months scrolling under it, and the
    /// results in their place while a search is typed.
    ///
    /// No NavigationStack: on the open Duo every navigation stack holds back
    /// room for the system strip on the trailing edge (84pt), even one that
    /// doesn't touch it, which squeezed this column's content. The title and
    /// search field are drawn here instead.
    private var finderColumn: some View {
        Group {
            if isSearching {
                searchResults
            } else {
                JournalMonthColumn(model: model) { key in
                    model.select(key: key)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .safeAreaBar(edge: .top) {
            VStack(spacing: 10) {
                Text("Journal")
                    .font(.headline)
                    .frame(height: 44)
                columnSearchField
                if !isSearching {
                    JournalWeekdayRow()
                        .padding(.horizontal, 12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var columnSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search journal", text: $query)
                .focused($columnSearchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var searchResults: some View {
        JournalSearchResults(query: query, hits: hits) { hit in
            model.select(key: hit.dayKey)
            query = ""
            searching = false
            columnSearchFocused = false
        }
    }

    private func pageStack(finderShown: Bool) -> some View {
        NavigationStack {
            Group {
                if isSearching && !finderShown {
                    searchResults
                } else {
                    page
                }
            }
                .navigationBarTitleDisplayMode(.inline)
                .modifier(PageSearchField(enabled: !finderShown, query: $query, searching: $searching))
                .toolbar { toolbar(finderShown: finderShown) }
                .safeAreaBar(edge: .bottom) { bottomBar }
                .onAppear { model.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    // Pick up entries written on the Mac.
                    if phase == .active { model.refresh() }
                }
                .onChange(of: journalBusy) { _, busy in
                    // The entry is going to today; watch it land there.
                    if busy, !model.isShowingToday { model.select(key: model.todayKey) }
                }
                .sheet(isPresented: $composing) {
                    JournalEntrySheet(viewModel: viewModel, title: "New Entry") { text, _, photos in
                        add(text, photos: photos)
                    }
                }
                .sheet(item: $capturedPhoto) { captured in
                    // Straight from the bottom bar's camera: the photo is
                    // already in, ready for a caption or just Save.
                    JournalEntrySheet(viewModel: viewModel, title: "New Entry", initialPhotos: captured.photos) { text, _, photos in
                        add(text, photos: photos)
                    }
                }
                .sheet(item: $editing) { entry in
                    JournalEntrySheet(
                        viewModel: viewModel,
                        title: "Edit Entry",
                        note: entry.fileURL,
                        initialText: JournalMarkdown.prose(in: entry.text),
                        initialImages: JournalMarkdown.images(in: entry.text)
                    ) { text, keeping, photos in
                        Task { await model.edit(entry, prose: text, keeping: keeping, adding: photos) }
                    }
                }
                .fullScreenCover(isPresented: $capturing) {
                    JournalCamera { image in
                        if let photo = JournalPhotoImport.photo(from: image) {
                            capturedPhoto = CapturedPhoto(photos: [photo])
                        }
                    }
                    .ignoresSafeArea()
                }
                .onChange(of: model.photoRequests) {
                    // No camera (the simulator, some iPads): the library is
                    // the next best way to get a photo in.
                    if JournalCamera.isAvailable { capturing = true } else { choosingPhotos = true }
                }
                .photosPicker(isPresented: $choosingPhotos, selection: $libraryItems,
                              maxSelectionCount: 10, matching: .images)
                .onChange(of: libraryItems) { _, items in
                    guard !items.isEmpty else { return }
                    libraryItems = []
                    Task {
                        var photos: [JournalModel.PendingPhoto] = []
                        for item in items {
                            if let photo = await JournalPhotoImport.photo(from: item) { photos.append(photo) }
                        }
                        if !photos.isEmpty { capturedPhoto = CapturedPhoto(photos: photos) }
                    }
                }
                .fullScreenCover(item: $viewingPhoto) { url in
                    JournalPhotoViewer(url: url) { viewingPhoto = nil }
                }
                .sheet(isPresented: $choosingDay) {
                    JournalCalendarSheet(model: model) { key in
                        model.select(key: key)
                        choosingDay = false
                    }
                    .presentationDetents([.medium, .large])
                }
                .confirmationDialog(
                    "Delete this entry?",
                    isPresented: Binding(
                        get: { confirmingDelete != nil },
                        set: { if !$0 { confirmingDelete = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        guard let entry = confirmingDelete else { return }
                        confirmingDelete = nil
                        Task { await model.delete(entry) }
                    }
                } message: {
                    Text("It's removed from the Markdown file. You can undo straight afterwards.")
                }
        }
    }

    // MARK: - The page

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading
                    .padding(.bottom, 22)

                notes

                if model.groups.isEmpty && !journalBusy {
                    emptyDay
                } else {
                    ForEach(model.groups) { group in
                        if model.groups.count > 1 {
                            fileCaption(group)
                        }
                        if let whole = group.wholeFile {
                            Text(whole)
                                .font(.body)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .padding(.bottom, 28)
                        } else {
                            ForEach(group.entries) { entry in
                                JournalPageEntry(entry: entry) { viewingPhoto = $0 }
                                    .contextMenu { menu(for: entry) }
                                    .padding(.bottom, 28)
                            }
                        }
                    }
                }

                // The entry being spoken, drawn where it will land.
                if journalBusy, model.isShowingToday {
                    JournalIncomingEntry(isTranscribing: isTranscribing) {
                        viewModel.cancelProcessing()
                    }
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { model.refresh() }
        .background(Color(.systemBackground))
        // Swipe sideways to turn the page to the next populated day.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let dx = value.translation.width
                    guard abs(dx) > 80, abs(dx) > abs(value.translation.height) * 2 else { return }
                    let key = dx < 0 ? model.nextKey : model.previousKey
                    if let key { withAnimation(.easeOut(duration: 0.2)) { model.select(key: key) } }
                }
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: journalBusy)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            // The only serif in the app, as on the Mac: it says "journal"
            // before a word of it is read.
            Text(longDate)
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)

            if !model.groups.isEmpty {
                Divider().padding(.top, 8)
                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 6)
            }
        }
    }

    /// Sync and error notes, inline on the page rather than floating over it.
    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.isShared {
                Button(action: onOpenSettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "icloud.slash")
                        Text("Not syncing with your Mac.")
                            .foregroundStyle(.secondary)
                        Text("Connect")
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            } else if let elsewhere = model.macJournalElsewhere {
                Label("Your Mac keeps its journal at \(elsewhere), outside the shared folder. Entries from this device go to Journal in the shared folder.",
                      systemImage: "folder.badge.questionmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        model.dismissError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Dismiss")
                }
                .font(.footnote)
            }
        }
        .padding(.bottom, hasNotes ? 22 : 0)
    }

    private var hasNotes: Bool {
        !model.isShared || model.macJournalElsewhere != nil || model.errorMessage != nil
    }

    /// Only drawn when a date is spread over more than one file, which
    /// happens after the path template changes.
    private func fileCaption(_ group: JournalModel.FileGroup) -> some View {
        Label(group.url.lastPathComponent, systemImage: "doc.text")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.bottom, 10)
    }

    private var emptyDay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.isShowingToday ? "Nothing yet today." : "Nothing on this day.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func menu(for entry: JournalArchive.Entry) -> some View {
        Button {
            editing = entry
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        Button {
            UIPasteboard.general.string = entry.text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) {
            confirmingDelete = entry
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private func toolbar(finderShown: Bool) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                if let key = model.previousKey { model.select(key: key) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model.previousKey == nil)
            .accessibilityLabel("Previous day")
            Button {
                if let key = model.nextKey { model.select(key: key) }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model.nextKey == nil)
            .accessibilityLabel("Next day")
        }
        // Finding a day and adding to today are different kinds of action,
        // so they get separate glass capsules.
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !model.isShowingToday {
                Button("Today") { model.select(key: model.todayKey) }
            }
            // The calendar column replaces this on a wide window.
            if !finderShown {
                Button {
                    choosingDay = true
                } label: {
                    Image(systemName: "calendar")
                }
                .accessibilityLabel("Choose a day")
            }
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    composing = true
                } label: {
                    Label("Write an Entry", systemImage: "square.and.pencil")
                }
                if JournalCamera.isAvailable {
                    Button {
                        capturing = true
                    } label: {
                        Label("Take a Photo", systemImage: "camera")
                    }
                }
                Button {
                    choosingPhotos = true
                } label: {
                    Label("Choose Photos", systemImage: "photo.on.rectangle")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add to today")
            .disabled(journalBusy)
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            SettingsToolbarButton(action: onOpenSettings)
        }
    }

    /// The bottom of the page: the same `MorphRecordButton` as the Dictate
    /// and Scratchpad tabs, with the camera beside the mic where Dictate has
    /// Copy, and Undo above it when there's something to undo. A safe-area
    /// bar over the page's ScrollView (no text view under the glass). With
    /// a bottom tab bar the mic and camera move to its accessory and only
    /// Undo stays here.
    private var bottomBar: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if let pending = model.pendingUndo, !journalBusy {
                Button {
                    Task {
                        if let words = await model.undoLast() {
                            UIPasteboard.general.string = words
                        }
                    }
                } label: {
                    Label("\(pending.what) · Undo", systemImage: "arrow.uturn.backward")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .transition(.opacity)
            }
            if !controlsInAccessory {
                JournalMicControls(viewModel: viewModel)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.pendingUndo != nil)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .readableWidth()
    }

    private func add(_ text: String, photos: [JournalModel.PendingPhoto]) {
        Task {
            do { try await model.add(text, photos: photos) } catch {
                if !text.isEmpty { UIPasteboard.general.string = text }
            }
        }
    }

    // MARK: - State

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var journalBusy: Bool {
        guard viewModel.recordingMode == .journal else { return false }
        if viewModel.status.isCapturing { return true }
        return isTranscribing
    }

    private var isTranscribing: Bool {
        guard viewModel.recordingMode == .journal else { return false }
        if case .transcribing = viewModel.status { return true }
        return false
    }

    // MARK: - Text

    private var selectedDate: Date? { JournalModel.date(for: model.selectedKey) }

    private var eyebrow: String {
        guard let date = selectedDate else { return "" }
        let weekday = date.formatted(.dateTime.weekday(.wide)).uppercased()
        if let relative = JournalCalendarList.relativeLabel(model.selectedKey) {
            return "\(relative.uppercased()) · \(weekday)"
        }
        return weekday
    }

    private var longDate: String {
        selectedDate?.formatted(.dateTime.day().month(.wide).year()) ?? model.selectedKey
    }

    private var summary: String {
        let entries = model.groups.reduce(0) { $0 + $1.entries.count }
        let words = model.groups
            .flatMap(\.entries)
            .reduce(0) { $0 + JournalMarkdown.prose(in: $1.text).split(whereSeparator: \.isWhitespace).count }
        var parts: [String] = []
        if entries > 0 { parts.append("\(entries) \(entries == 1 ? "entry" : "entries")") }
        if words > 0 { parts.append("\(words) words") }
        if let name = model.groups.first?.url.lastPathComponent { parts.append(name) }
        return parts.joined(separator: " · ")
    }
}

/// The journal's one accent, the Mac's mint deepened enough to read as text
/// on white.
extension Color {
    static let journalAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.40, green: 0.83, blue: 0.81, alpha: 1)
            : UIColor(red: 0.13, green: 0.58, blue: 0.56, alpha: 1)
    })
}

/// One entry: the time in the margin, the words and photos beside it.
/// The Journal's mic, with the camera beside it: on the page's bottom bar,
/// or in the tab bar's bottom accessory (`compact`) on an iPhone, where it
/// tucks in beside the tab button when the bar minimises.
struct JournalMicControls: View {
    @Bindable var viewModel: RecordingViewModel
    var compact = false
    @State private var micBlocker: MicBlocker?

    var body: some View {
        MorphRecordButton(
            viewModel: viewModel,
            micIcon: "microphone.fill",
            route: micRoute,
            extras: [cameraExtra],
            compact: compact
        )
        .frame(maxHeight: compact ? .infinity : nil)
        .micBlockerAlert($micBlocker, viewModel: viewModel)
    }

    /// An entry always goes to today; the page turns to it as it starts.
    private var micRoute: MorphRecordButton.Route {
        let blocker = $micBlocker
        return MorphRecordButton.Route(
            owns: { $0 == .journal },
            start: { viewModel in
                JournalModel.shared.select(key: JournalModel.shared.todayKey)
                viewModel.startJournalRecording()
            },
            send: { await $0.stopJournalRecording() },
            isBlocked: { MicBlocker.current($0) != nil },
            onBlocked: { handleBlockedMic($0, showing: blocker) },
            idleLabel: { _ in "Dictate a journal entry" }
        )
    }

    /// The page watches `photoRequests` and opens the camera or library.
    private var cameraExtra: MorphRecordButton.Extra {
        MorphRecordButton.Extra(
            id: "camera",
            systemImage: "camera",
            label: JournalCamera.isAvailable ? "Take a photo" : "Add a photo"
        ) {
            let model = JournalModel.shared
            model.select(key: model.todayKey)
            model.requestPhoto()
        }
    }
}

private struct JournalPageEntry: View {
    let entry: JournalArchive.Entry
    var onOpenPhoto: (URL) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.time)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.journalAccent)
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(JournalMarkdown.blocks(in: entry.text, note: entry.fileURL)) { block in
                    switch block {
                    case .prose(let prose):
                        Text(Self.rendered(prose))
                            .font(.body)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    case .images(let images):
                        JournalPhotoGrid(images: images, onOpen: onOpenPhoto)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    /// Inline Markdown (bold, italics, links) with paragraph breaks kept —
    /// the parser folds single newlines otherwise.
    static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct CapturedPhoto: Identifiable {
    let id = UUID()
    let photos: [JournalModel.PendingPhoto]
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Matching entries across the whole journal, newest first, grouped by day.
private struct JournalSearchResults: View {
    let query: String
    let hits: [JournalModel.SearchHit]
    let onPick: (JournalModel.SearchHit) -> Void

    var body: some View {
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(days, id: \.key) { day in
                    Section(title(for: day.key)) {
                        ForEach(day.hits) { hit in
                            Button { onPick(hit) } label: { row(hit) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ hit: JournalModel.SearchHit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(hit.entry.time)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.journalAccent)
                .frame(width: 40, alignment: .leading)
            Text(highlighted(JournalMarkdown.prose(in: hit.entry.text)))
                .font(.subheadline)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var days: [(key: String, hits: [JournalModel.SearchHit])] {
        var result: [(key: String, hits: [JournalModel.SearchHit])] = []
        for hit in hits {
            if result.last?.key == hit.dayKey {
                result[result.count - 1].hits.append(hit)
            } else {
                result.append((hit.dayKey, [hit]))
            }
        }
        return result
    }

    private func title(for key: String) -> String {
        guard let date = JournalModel.date(for: key) else { return key }
        if let relative = JournalCalendarList.relativeLabel(key) {
            return "\(relative) · \(date.formatted(.dateTime.day().month(.wide)))"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).year())
    }

    /// The entry with every query term in bold and the journal's accent.
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for term in ChatSearch.terms(in: query) {
            var searchRange = attributed.startIndex..<attributed.endIndex
            while let found = attributed[searchRange].range(of: term, options: .caseInsensitive) {
                attributed[found].foregroundColor = .journalAccent
                attributed[found].font = .subheadline.weight(.semibold)
                searchRange = found.upperBound..<attributed.endIndex
            }
        }
        return attributed
    }
}

/// The entry being spoken, in the place it will land, so the words don't
/// feel lost in the seconds before they appear.
private struct JournalIncomingEntry: View {
    let isTranscribing: Bool
    /// While it's being written down, a tap drops it.
    var onCancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.journalAccent)
                .frame(width: 40, alignment: .leading)
            HStack(spacing: 8) {
                // The dot breathes. Driven by a TimelineView at 30 fps, which
                // pauses off screen, rather than a repeatForever animation,
                // which keeps the render loop busy and can leak into the
                // transitions around it.
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate * .pi / 0.8
                    Circle()
                        .fill(isTranscribing ? Color.journalAccent : .red)
                        .frame(width: 7, height: 7)
                        .opacity(0.675 + 0.325 * cos(phase))
                }
                Text(isTranscribing ? "Writing it down…" : "Listening…")
                    .font(.body)
                    .foregroundStyle(.secondary)
                if isTranscribing {
                    Button("Cancel", action: onCancel)
                        .font(.subheadline.weight(.medium))
                        .tint(Color.journalAccent)
                }
            }
        }
    }
}

/// Write an entry, or fix one — by voice, by Reword, or by typing, with
/// photos from the camera or the library. The text box holds only the words:
/// photo links live under them in the file, shown here as thumbnails that can
/// be removed.
///
/// The mic inserts at the cursor (replacing a selection), like the
/// Scratchpad's. Reword applies a spoken instruction to the selection, or to
/// everything when nothing is selected.
private struct JournalEntrySheet: View {
    @Bindable var viewModel: RecordingViewModel
    let title: String
    var note: URL?
    var initialText = ""
    var initialImages: [JournalMarkdown.ImageRef] = []
    var initialPhotos: [JournalModel.PendingPhoto] = []
    let onSave: (String, [JournalMarkdown.ImageRef], [JournalModel.PendingPhoto]) -> Void

    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var kept: [JournalMarkdown.ImageRef] = []
    @State private var added: [JournalModel.PendingPhoto] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var capturing = false
    @State private var loaded = false
    @State private var micBlocker: MicBlocker?
    /// What Reword replaced, for one-step undo — a rewrite of somebody's
    /// journal entry has to be easy to take back.
    @State private var beforeReword: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text, selection: $selection)
                    .focused($focused)
                    .padding(.horizontal, 12)
                if !kept.isEmpty || !added.isEmpty {
                    photoStrip
                }
            }
            .safeAreaBar(edge: .bottom) { controls }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelEntryCapture()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(text, kept, added)
                        dismiss()
                    }
                    .disabled(!canSave || busy)
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                Task {
                    for item in items {
                        if let photo = await JournalPhotoImport.photo(from: item) { added.append(photo) }
                    }
                }
            }
            .fullScreenCover(isPresented: $capturing) {
                JournalCamera { image in
                    if let photo = JournalPhotoImport.photo(from: image) { added.append(photo) }
                }
                .ignoresSafeArea()
            }
            .micBlockerAlert($micBlocker, viewModel: viewModel)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                text = initialText
                kept = initialImages
                added = initialPhotos
                if initialPhotos.isEmpty { focused = true }
            }
            .onDisappear { viewModel.cancelEntryCapture() }
            .interactiveDismissDisabled(busy)
        }
    }

    // MARK: - Voice

    private var controls: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if showMic {
                    ScratchpadRecordButton(
                        tint: .red,
                        restingIcon: "microphone.fill",
                        status: viewModel.status,
                        isMyTurn: viewModel.recordingMode == .entry,
                        recordingStartCount: viewModel.recordingStartCount,
                        meter: viewModel.levelMeter,
                        onPress: { startDictation() },
                        onRelease: { Task { await viewModel.stopEntryCapture() } },
                        blocked: MicBlocker.current(viewModel) != nil,
                        onBlocked: { handleBlockedMic(viewModel, showing: $micBlocker) },
                        onCancel: { viewModel.cancelProcessing() }
                    )
                    .disabled(otherCaptureRunning)
                }
                if showReword {
                    ScratchpadRecordButton(
                        tint: .purple,
                        restingIcon: AssistGlyph.name,
                        status: viewModel.status,
                        isMyTurn: viewModel.recordingMode == .entryAssist,
                        recordingStartCount: viewModel.recordingStartCount,
                        meter: viewModel.levelMeter,
                        onPress: { startReword() },
                        onRelease: { Task { await viewModel.stopEntryCapture() } },
                        blocked: MicBlocker.current(viewModel) != nil,
                        onBlocked: { handleBlockedMic(viewModel, showing: $micBlocker) },
                        onCancel: { viewModel.cancelProcessing() }
                    )
                    .disabled(otherCaptureRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Spacer(minLength: 8)

                if !busy {
                    if let previous = beforeReword {
                        circle("arrow.uturn.backward", label: "Undo Reword") {
                            text = previous
                            selection = nil
                            beforeReword = nil
                        }
                    }
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Add photos")
                    if JournalCamera.isAvailable {
                        circle("camera", label: "Take a photo") { capturing = true }
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: busy)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func circleLabel(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 48, height: 48)
    }

    private func circle(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleLabel(systemImage) }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(label)
            .transition(.scale.combined(with: .opacity))
    }

    private var isMine: Bool {
        viewModel.recordingMode == .entry || viewModel.recordingMode == .entryAssist
    }

    /// A capture or its transcription from this editor is in flight.
    private var busy: Bool {
        guard isMine else { return false }
        if viewModel.status.isCapturing { return true }
        if case .transcribing = viewModel.status { return true }
        return false
    }

    /// While one of the two is running, the other steps aside.
    private var showMic: Bool { !busy || viewModel.recordingMode == .entry }
    private var showReword: Bool {
        AppleFoundationAssist.isAvailable && (!busy || viewModel.recordingMode == .entryAssist)
    }

    private var otherCaptureRunning: Bool {
        !isMine && viewModel.status.isCapturing
    }

    /// The selection as an NSRange into `text`, if there's a single one.
    private var selectedRange: NSRange? {
        guard let selection, case .selection(let range) = selection.indices else { return nil }
        guard range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else { return nil }
        return NSRange(range, in: text)
    }

    private func startDictation() {
        let at = selectedRange
        viewModel.startEntryCapture { words in
            // The text may have been typed into meanwhile; only trust the
            // remembered cursor if it still fits.
            let length = (text as NSString).length
            let safe = at.flatMap { $0.location + $0.length <= length ? $0 : nil }
            let merged = TranscriptMerge.insert(words, into: text, at: safe)
            text = merged.text
            if let caret = merged.selection, let range = Range(caret, in: text) {
                selection = TextSelection(range: range)
            }
        }
    }

    private func startReword() {
        let full = text
        let range = selectedRange.flatMap { $0.length > 0 ? $0 : nil }
        let source = range.map { (full as NSString).substring(with: $0) } ?? full
        viewModel.startEntryCapture(assistSource: source) { result in
            // Rewording somebody's entry from under them would be wrong if
            // they edited it meanwhile; only apply onto the text we read.
            guard text == full else { return }
            beforeReword = full
            if let range {
                text = (full as NSString).replacingCharacters(in: range, with: result)
                let replaced = NSRange(location: range.location, length: (result as NSString).length)
                if let r = Range(replaced, in: text) { selection = TextSelection(range: r) }
            } else {
                text = result
                selection = nil
            }
        }
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !kept.isEmpty || !added.isEmpty
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(kept) { ref in
                    thumb(JournalMarkdown.ResolvedImage(
                        ref: ref,
                        url: note.flatMap { JournalAttachments.resolve(ref.reference, relativeTo: $0) })
                    ) {
                        kept.removeAll { $0.id == ref.id }
                    }
                }
                ForEach(added) { photo in
                    thumb(photo) { added.removeAll { $0.id == photo.id } }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.secondarySystemBackground))
    }

    private func thumb(_ image: JournalMarkdown.ResolvedImage, remove: @escaping () -> Void) -> some View {
        JournalPhotoView(image: image, maxPixel: 160, fill: true)
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) { removeButton(remove) }
    }

    private func thumb(_ photo: JournalModel.PendingPhoto, remove: @escaping () -> Void) -> some View {
        Group {
            if let image = UIImage(data: photo.data) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color(.tertiarySystemBackground)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) { removeButton(remove) }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.6))
                .font(.system(size: 20))
        }
        .buttonStyle(.plain)
        .padding(3)
        .accessibilityLabel("Remove photo")
    }
}

/// The calendar as a sheet, for a window too narrow for the calendar column.
struct JournalCalendarSheet: View {
    let model: JournalModel
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            JournalCalendarList(model: model, onPick: onPick)
                .navigationTitle("Journal")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Pick a day, the way the Mac's journal sidebar does: a month calendar
/// with a dot under every day that has something in it, the month name as
/// a menu of the months that do, and the most recent days below. The sheet's
/// month-at-a-time calendar; the wide layout's column is `JournalMonthColumn`.
struct JournalCalendarList: View {
    let model: JournalModel
    let onPick: (String) -> Void

    @State private var visibleMonth = Date()

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    monthHeader
                    JournalWeekdayRow()
                    JournalMonthGrid(month: visibleMonth, model: model, onPick: onPick)
                }
                .padding(.vertical, 4)
            }
            if !model.days.isEmpty {
                Section("Recent") {
                    ForEach(model.days.prefix(12)) { day in
                        recentRow(day)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Today") { onPick(model.todayKey) }
            }
        }
        .onAppear {
            if let date = JournalModel.date(for: model.selectedKey) { visibleMonth = date }
        }
    }

    // MARK: - Month

    private var monthHeader: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(monthsWithEntries, id: \.self) { month in
                    Button(month.formatted(.dateTime.month(.wide).year())) { visibleMonth = month }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(visibleMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !monthsWithEntries.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(monthsWithEntries.isEmpty)

            Spacer(minLength: 0)

            Button { step(by: -1) } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 32)
            }
            .accessibilityLabel("Previous month")
            Button { step(by: 1) } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 32)
            }
            .accessibilityLabel("Next month")
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Recent

    private func recentRow(_ day: JournalArchive.Day) -> some View {
        Button {
            onPick(day.key)
        } label: {
            HStack(spacing: 8) {
                Text(JournalModel.date(for: day.key)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? day.key)
                    .foregroundStyle(.primary)
                if let relative = Self.relativeLabel(day.key) {
                    Text(relative)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(Color.journalAccent)
                }
                Spacer(minLength: 0)
                if day.key == model.selectedKey {
                    Image(systemName: "checkmark").foregroundStyle(Color.journalAccent)
                }
            }
        }
    }

    // MARK: - Dates

    private func step(by months: Int) {
        if let moved = calendar.date(byAdding: .month, value: months, to: visibleMonth) {
            visibleMonth = moved
        }
    }

    private var monthsWithEntries: [Date] {
        var seen: Set<String> = []
        var months: [Date] = []
        for day in model.days {
            let prefix = String(day.key.prefix(7))
            guard !seen.contains(prefix), let date = JournalModel.date(for: day.key) else { continue }
            seen.insert(prefix)
            if let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) {
                months.append(start)
            }
        }
        return months
    }

    /// "Today" / "Yesterday", or nothing.
    static func relativeLabel(_ key: String) -> String? {
        guard let date = JournalModel.date(for: key) else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return nil
    }
}

/// The wide layout's calendar column: months scrolling vertically, the
/// current month at the bottom and earlier ones above it, back a year or to
/// the first entry, whichever is older. Never a future month. Follows the
/// page to whichever month the selected day is in.
struct JournalMonthColumn: View {
    let model: JournalModel
    let onPick: (String) -> Void

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        // Worked out once for the column, not once per month grid.
        let populated = Set(model.days.map(\.key))
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(months, id: \.self) { month in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(month.formatted(.dateTime.month(.wide).year()))
                                .font(.system(.headline, design: .rounded))
                                .foregroundStyle(.primary)
                                .padding(.leading, 6)
                            JournalMonthGrid(month: month, model: model, populated: populated, onPick: onPick)
                        }
                        .id(Self.monthID(month))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.immediately)
            .onAppear {
                reader.scrollTo(selectedMonthID, anchor: .bottom)
            }
            .onChange(of: model.selectedKey) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    reader.scrollTo(selectedMonthID, anchor: .center)
                }
            }
        }
    }

    private var selectedMonthID: String {
        String(model.selectedKey.prefix(7))
    }

    private static func monthID(_ month: Date) -> String {
        String(JournalModel.key(for: month).prefix(7))
    }

    /// Oldest first, ending with the current month.
    private var months: [Date] {
        let now = Date()
        guard let current = calendar.dateInterval(of: .month, for: now)?.start,
              let yearAgo = calendar.date(byAdding: .month, value: -12, to: current) else { return [] }
        var start = yearAgo
        if let earliest = model.days.compactMap({ JournalModel.date(for: $0.key) }).min(),
           let earliestMonth = calendar.dateInterval(of: .month, for: earliest)?.start,
           earliestMonth < start {
            start = earliestMonth
        }
        var result: [Date] = []
        var month = start
        while month <= current {
            result.append(month)
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        return result
    }
}

/// One-letter weekday initials, in the locale's week order.
struct JournalWeekdayRow: View {
    var body: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                Text(symbols[(start + index) % 7])
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// A month's days as a seven-column grid that fills its width: a dot under
/// every day with entries, today in the journal's accent, the selected day
/// filled. Shared by the sheet and the column.
struct JournalMonthGrid: View {
    let month: Date
    let model: JournalModel
    /// Keys of days with entries, when the caller already has them.
    var populated: Set<String>? = nil
    let onPick: (String) -> Void

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        let populated = populated ?? Set(model.days.map(\.key))
        Grid(horizontalSpacing: 0, verticalSpacing: 4) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                GridRow {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, date in
                        if let date {
                            dayCell(date, populated: populated)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 40)
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ date: Date, populated: Set<String>) -> some View {
        let key = JournalModel.key(for: date)
        let isSelected = key == model.selectedKey
        let isToday = calendar.isDateInToday(date)
        let hasEntries = populated.contains(key)
        let isFuture = date > Date() && !isToday
        return Button {
            onPick(key)
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 16, weight: isToday || isSelected ? .semibold : .regular).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(numberStyle(isSelected: isSelected, isToday: isToday, isFuture: isFuture))
                Circle()
                    .fill(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(Color.journalAccent))
                    .frame(width: 5, height: 5)
                    .opacity(hasEntries ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background {
                if isSelected {
                    Circle().fill(Color.journalAccent)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 38, maxHeight: 38)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted) + (hasEntries ? ", has entries" : ""))
    }

    private func numberStyle(isSelected: Bool, isToday: Bool, isFuture: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        if isToday { return AnyShapeStyle(Color.journalAccent) }
        if isFuture { return AnyShapeStyle(.quaternary) }
        return AnyShapeStyle(.primary)
    }

    /// The month in weeks, padded so the 1st lands under the right weekday.
    private var weeks: [[Date?]] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 0
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<count {
            cells.append(calendar.date(byAdding: .day, value: offset, to: first))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }
}

/// The page's own search field, on a window too narrow for the calendar
/// column (which carries the search field when it shows).
private struct PageSearchField: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    @Binding var searching: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, isPresented: $searching, prompt: "Search journal")
        } else {
            content
        }
    }
}

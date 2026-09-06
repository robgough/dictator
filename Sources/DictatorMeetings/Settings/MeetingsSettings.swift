import Foundation

/// Dictator Meetings' own settings blob.
///
/// Deliberately a *copy* of the meeting-shaped half of `DictatorSettings`
/// rather than a shared type: the two apps ship separately, persist to
/// separate files, and will drift (Dictator drops these fields entirely one
/// release after the split). Field names, types, defaults and doc comments are
/// carried over verbatim so an imported blob decodes without a migration and
/// so the moved meetings code reads the same property names it always did.
///
/// `meetingsEnabled` is deliberately NOT here — installing this app *is* the
/// opt-in.
///
/// Persistence mirrors `DictatorSettings`: a synced envelope at
/// `<synced folder>/meetings-settings.json` and a per-Mac one at
/// `~/Library/Application Support/Dictator/meetings-local-settings.json`,
/// both `{"schemaVersion": 1, "settings": {…}}`. `syncedKeys` / `localKeys`
/// partition `CodingKeys` between the two files — a field missing from BOTH
/// sets is silently never written, which is the classic "my new setting resets
/// every launch" bug, so every new property needs five edits: the property,
/// `CodingKeys`, `init(from:)`, and one of the two key sets.
struct MeetingsSettings: Codable, Equatable {

    // MARK: - Identity, prompts, meetings

    /// The user's preferred name. Used to (a) bias Whisper toward the correct
    /// spelling when they say it, and (b) tell the LLM who's writing so
    /// Assistant Mode drafts emails / messages / sign-offs with their name.
    /// Empty string means "not set" — no name biasing is applied.
    var userName: String = ""

    /// Cross-cutting instructions the user wants applied to EVERY LLM pass —
    /// dictation (format / grammar / restructure), the assistant, and meeting
    /// notes. Appended as the outermost layer of each effective prompt: after
    /// any per-pass addendum, and even when a pass is fully overridden, so a
    /// preference like "always use British English" or a house spelling holds
    /// everywhere without being pasted into each pass separately. Empty = no
    /// global steer. Synced across Macs — it's a personal preference, not
    /// hardware-dependent.
    var globalPromptAddendum: String = ""

    var parakeetModelID: String = ModelCatalog.defaultParakeet.id

    /// Flips to true the first time the user finishes (or explicitly skips)
    /// the first-run wizard. When false on launch, `AppState.bootstrap()`
    /// shows the wizard window before the user sees the menu bar — the
    /// wizard walks them through permissions and downloading a transcription
    /// model so the first hotkey press just works.
    var hasCompletedOnboarding: Bool = false

    /// Optional custom directory for synced data — meetings-settings.json,
    /// the meetings' notes/transcripts and people.json all live here.
    /// nil = default (`~/Documents/Dictator/`). The user picks this in
    /// Settings → General → Synced folder. Per-Mac (in local-settings.json)
    /// because each machine may point at a different folder (e.g. one Mac
    /// on iCloud Drive, another on Dropbox).
    var syncedDirectoryPath: String?

    /// How long to keep recorded / imported meetings before pruning them
    /// off disk. 0 = never delete. Per-Mac (local-settings.json) because
    /// meetings live in App Support, not the synced folder — each Mac has
    /// its own pile of meeting audio.
    var meetingAutoDeleteAfterDays: Int = 0

    /// Days after which a meeting's audio files (mic.caf, system.caf) are
    /// pruned even though its transcript is kept. Lets users hold on to
    /// the searchable transcript history forever while letting the bulky
    /// audio age out. 0 = keep audio forever. Independent of
    /// `meetingAutoDeleteAfterDays`: a meeting hit by both first loses
    /// audio, then the whole record when the older window kicks in.
    var meetingAudioRetentionDays: Int = 0

    /// Show a running draft transcript while a meeting records (the "watch it
    /// take shape" pane). Default ON. Turning it off skips the entire live ASR
    /// path — no per-buffer resampling, chunking, or draft rendering during the
    /// call — which meaningfully lightens the in-call load on a long meeting.
    /// Live notes are built from this transcript, so they only run when it's on.
    /// Personal preference, synced across Macs.
    var meetingLiveTranscriptEnabled: Bool = true

    /// Build a rough first-pass of the notes *while the meeting records* —
    /// the LLM runs periodically over the live transcript and appends bullet
    /// points, superseded by the full pass once the meeting stops. Default
    /// ON: watching the notes take shape is the point of the feature. It runs
    /// the LLM on the GPU during the call, so the toggle is there for users who
    /// want to save battery, but it's on out of the box.
    var meetingLiveNotesEnabled: Bool = true

    /// While building the live first-pass notes, periodically ask the LLM to
    /// REVISE points the later conversation has contradicted or superseded — a
    /// reversed decision, a corrected number — instead of only ever appending.
    /// The model emits a small diff (drop/edit a numbered bullet), applied
    /// deterministically, so the document is never wholesale-rewritten (which
    /// small local models truncate). Only matters when `meetingLiveNotesEnabled`
    /// is on; default ON.
    var meetingLiveNotesSelfCorrectEnabled: Bool = true

    /// The meeting coach: live conversation metrics (talk balance, monologue
    /// timer, pace) computed while recording, plus a private per-meeting
    /// metrics summary stored afterwards. Derived entirely from the level
    /// callbacks and live transcript the recording already produces — no
    /// extra capture, negligible cost. Default ON. Synced across Macs —
    /// wanting coaching is a personal preference, not hardware-dependent.
    var meetingCoachEnabled: Bool = true

    /// Show the coach's ambient strip + nudges on the notch island during a
    /// meeting. Separate from `meetingCoachEnabled` so the metrics can keep
    /// being computed (in-window strip, post-meeting summary) with the
    /// floating presence off. Default ON; synced.
    var meetingCoachChipEnabled: Bool = true

    /// Recognise people across meetings by voice: persist speaker
    /// embeddings to people.json, link returning voices to their person
    /// (applying the known name), learn named strangers. Default ON — one
    /// switch, not per-person consent — with per-person delete (embeddings
    /// purged) as the hygiene valve. All on-device. Synced.
    var peopleRecognitionEnabled: Bool = true

    /// Match each recording to its calendar event (title, attendees,
    /// scheduled span) at record time. Prompts for calendar access on first
    /// use; denial leaves meetings without calendar context, silently.
    /// Default ON; synced.
    var meetingCalendarMatchingEnabled: Bool = true

    /// Capture keyframes of shared screen content during meetings
    /// (window-scoped, kept as HEICs in the meeting's local folder). OFF by
    /// default — it needs the Screen Recording permission, the heaviest grant
    /// the app holds, and the system shows the purple capture indicator while
    /// it runs. The toggle preference syncs; the grant is per-Mac.
    var meetingCaptureScreenshots: Bool = false

    /// Appended under the built-in coach-report prompt (the warmth lever —
    /// the default voice is deliberately blunt). Synced.
    var meetingCoachPromptAddendum: String = ""

    /// When set, replaces the built-in coach prompt wholesale.
    var meetingCoachPromptOverride: String?

    /// Reusable checklist bundles ("Client type B") layered onto a meeting's
    /// checklist at record start, alongside the meeting type's own items.
    /// Synced — they're personal playbooks, not hardware.
    var coachChecklistProfiles: [CoachChecklistProfile] = []

    /// Pre-record sheet defaults: the type and profiles picked last time.
    var meetingLastPresetTypeID: String?

    var meetingLastProfileIDs: [String] = []

    /// Appended under the built-in meeting summary prompt. Empty = no
    /// addendum. Synced across Macs because it's a personal preference,
    /// not hardware-dependent.
    var meetingSummaryPromptAddendum: String = ""

    /// When set, replaces the built-in summary prompt wholesale. nil =
    /// use built-in + addendum.
    var meetingSummaryPromptOverride: String?

    /// Default meeting-type bias applied when the meeting itself is set
    /// to `.auto` (i.e. the user hasn't picked a specific type on the
    /// detail page). Synced across Macs because the right default
    /// depends on what kind of meetings the user typically records, not
    /// on which Mac is doing the recording.
    var defaultMeetingType: MeetingTypeID = .auto

    /// User-created meeting types, each defining the sections their notes
    /// should have (see `MeetingTypeDefinition`). Listed after the built-ins
    /// everywhere a type can be picked. Synced across Macs — a custom notes
    /// style is a personal preference, not hardware-dependent.
    var customMeetingTypes: [MeetingTypeDefinition] = []

    /// When true, MeetingProcessor runs a post-transcription dedup pass that
    /// drops mic-track words within ±300 ms of an identical (or near-identical)
    /// system-track word. Only matters when the user isn't wearing headphones —
    /// their mic picks up the remote speakers and the same words land on both
    /// tracks. AEC usually catches this; the dedup is the belt-and-braces
    /// layer for residual leakage (Bluetooth latency, AGC stomp).
    /// Per-Mac because echo behaviour depends on this Mac's headphones-versus-
    /// speakers setup. Default ON; off is the escape hatch if it ever eats
    /// legitimate overlapping speech.
    var meetingDedupeMicEchoes: Bool = true

    // MARK: - Providers

    /// Every configured note-writing backend, in user order. Seeded on first
    /// launch with the three local options (Dictator's shared model, a local
    /// MLX model, Apple's on-device model); cloud entries are added by hand on
    /// the Providers tab. API keys are NEVER in here — only a `keychainAccount`
    /// pointer, resolved through `KeychainStore`. Synced, so the same provider
    /// list appears on every Mac (each Mac needs its own Keychain entry unless
    /// `keychainSyncEnabled` is on).
    var providers: [ProviderConfig] = []

    /// `ProviderConfig.id` used for the live first-pass notes written during a
    /// recording. nil (or a dangling id) falls back through
    /// `ProviderRegistry`'s resolution order. Synced.
    var liveProviderID: String?

    /// `ProviderConfig.id` used for the full post-meeting pass — notes,
    /// summary, speaker naming, the coach report and the notes assistant.
    /// This is the slot that decides note quality. Synced.
    var finalProviderID: String?

    /// The MLX checkpoint the built-in "Local model" provider loads. Per-Mac:
    /// which models are downloaded depends on this machine's disk and RAM, so
    /// syncing it would point one Mac at a model it doesn't have. Defaults to
    /// the model meeting notes are tuned for.
    var localLLMModelID: String = ModelCatalog.meetingsRecommendedLLMID

    /// Store cloud API keys as synchronizable Keychain items so they travel via
    /// iCloud Keychain to the user's other Macs. OFF by default — a key
    /// leaving this machine should be an explicit choice. Changing it rewrites
    /// existing items (see `KeychainStore.setSynchronizable`). Synced (it's a
    /// preference about the keys, not a key).
    var keychainSyncEnabled: Bool = false

    /// Show a status item in the menu bar (recording dot, Record / Stop / Open
    /// Meetings). Per-Mac — menu-bar real estate is a per-machine call.
    var showMenuBarStatus: Bool = true

    /// Set by `load()` when the on-disk blob failed to decode. Purely
    /// in-memory (excluded from `CodingKeys`): while it's true `persist()`
    /// refuses to write, so the `.recovered-<date>.json` copies and the
    /// original files both survive for the user to inspect.
    var persistSuspendedDueToCorruption: Bool = false

    /// Which engine Dictator was configured to use, carried out of the
    /// one-time import so `seedDefaultProvidersIfNeeded` can list the backend
    /// the user already chose first. In-memory only (excluded from
    /// `CodingKeys`) — it's a hint about a one-off migration, not a setting.
    var importedLocalEngineKind: LLMEngineKind?

    /// All-defaults instance. `init(from:)` uses it as the per-field fallback
    /// so a missing key decodes to the declared default rather than throwing.
    static let `default` = MeetingsSettings()

    /// Explicit because declaring `init(from:)` in the body suppresses the
    /// memberwise initialiser. Every stored property has a default, so this is
    /// empty.
    init() {}

    // MARK: - Codable

    /// Explicit so `persistSuspendedDueToCorruption` never serialises, and so
    /// every persisted key is listed in one place for `syncedKeys` /
    /// `localKeys` to partition.
    private enum CodingKeys: String, CodingKey {
        case userName
        case globalPromptAddendum
        case parakeetModelID
        case hasCompletedOnboarding
        case syncedDirectoryPath
        case showMenuBarStatus
        case meetingAutoDeleteAfterDays
        case meetingAudioRetentionDays
        case meetingLiveTranscriptEnabled
        case meetingLiveNotesEnabled
        case meetingLiveNotesSelfCorrectEnabled
        case meetingCoachEnabled
        case meetingCoachChipEnabled
        case peopleRecognitionEnabled
        case meetingCalendarMatchingEnabled
        case meetingCaptureScreenshots
        case meetingCoachPromptAddendum
        case meetingCoachPromptOverride
        case coachChecklistProfiles
        case meetingLastPresetTypeID
        case meetingLastProfileIDs
        case meetingSummaryPromptAddendum
        case meetingSummaryPromptOverride
        case defaultMeetingType
        case customMeetingTypes
        case meetingDedupeMicEchoes
        case providers
        case liveProviderID
        case finalProviderID
        case localLLMModelID
        case keychainSyncEnabled
    }

    /// Field-level backwards/forwards compatible: every key is optional and
    /// falls through to the declared default, so a blob written by an older
    /// build (or by the one-time Dictator import, which only carries a subset)
    /// decodes cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MeetingsSettings.default
        self.userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? d.userName
        self.globalPromptAddendum = try c.decodeIfPresent(String.self, forKey: .globalPromptAddendum) ?? d.globalPromptAddendum
        self.parakeetModelID = try c.decodeIfPresent(String.self, forKey: .parakeetModelID) ?? d.parakeetModelID
        self.hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        self.syncedDirectoryPath = try c.decodeIfPresent(String.self, forKey: .syncedDirectoryPath) ?? d.syncedDirectoryPath
        self.showMenuBarStatus = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarStatus) ?? d.showMenuBarStatus
        self.meetingAutoDeleteAfterDays = try c.decodeIfPresent(Int.self, forKey: .meetingAutoDeleteAfterDays) ?? d.meetingAutoDeleteAfterDays
        self.meetingAudioRetentionDays = try c.decodeIfPresent(Int.self, forKey: .meetingAudioRetentionDays) ?? d.meetingAudioRetentionDays
        self.meetingLiveTranscriptEnabled = try c.decodeIfPresent(Bool.self, forKey: .meetingLiveTranscriptEnabled) ?? d.meetingLiveTranscriptEnabled
        self.meetingLiveNotesEnabled = try c.decodeIfPresent(Bool.self, forKey: .meetingLiveNotesEnabled) ?? d.meetingLiveNotesEnabled
        self.meetingLiveNotesSelfCorrectEnabled = try c.decodeIfPresent(Bool.self, forKey: .meetingLiveNotesSelfCorrectEnabled) ?? d.meetingLiveNotesSelfCorrectEnabled
        self.meetingCoachEnabled = try c.decodeIfPresent(Bool.self, forKey: .meetingCoachEnabled) ?? d.meetingCoachEnabled
        self.meetingCoachChipEnabled = try c.decodeIfPresent(Bool.self, forKey: .meetingCoachChipEnabled) ?? d.meetingCoachChipEnabled
        self.peopleRecognitionEnabled = try c.decodeIfPresent(Bool.self, forKey: .peopleRecognitionEnabled) ?? d.peopleRecognitionEnabled
        self.meetingCalendarMatchingEnabled = try c.decodeIfPresent(Bool.self, forKey: .meetingCalendarMatchingEnabled) ?? d.meetingCalendarMatchingEnabled
        self.meetingCaptureScreenshots = try c.decodeIfPresent(Bool.self, forKey: .meetingCaptureScreenshots) ?? d.meetingCaptureScreenshots
        self.meetingCoachPromptAddendum = try c.decodeIfPresent(String.self, forKey: .meetingCoachPromptAddendum) ?? d.meetingCoachPromptAddendum
        self.meetingCoachPromptOverride = try c.decodeIfPresent(String.self, forKey: .meetingCoachPromptOverride) ?? d.meetingCoachPromptOverride
        self.coachChecklistProfiles = try c.decodeIfPresent([CoachChecklistProfile].self, forKey: .coachChecklistProfiles) ?? d.coachChecklistProfiles
        self.meetingLastPresetTypeID = try c.decodeIfPresent(String.self, forKey: .meetingLastPresetTypeID) ?? d.meetingLastPresetTypeID
        self.meetingLastProfileIDs = try c.decodeIfPresent([String].self, forKey: .meetingLastProfileIDs) ?? d.meetingLastProfileIDs
        self.meetingSummaryPromptAddendum = try c.decodeIfPresent(String.self, forKey: .meetingSummaryPromptAddendum) ?? d.meetingSummaryPromptAddendum
        self.meetingSummaryPromptOverride = try c.decodeIfPresent(String.self, forKey: .meetingSummaryPromptOverride) ?? d.meetingSummaryPromptOverride
        self.defaultMeetingType = try c.decodeIfPresent(MeetingTypeID.self, forKey: .defaultMeetingType) ?? d.defaultMeetingType
        self.customMeetingTypes = try c.decodeIfPresent([MeetingTypeDefinition].self, forKey: .customMeetingTypes) ?? d.customMeetingTypes
        self.meetingDedupeMicEchoes = try c.decodeIfPresent(Bool.self, forKey: .meetingDedupeMicEchoes) ?? d.meetingDedupeMicEchoes
        self.providers = try c.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? d.providers
        self.liveProviderID = try c.decodeIfPresent(String.self, forKey: .liveProviderID) ?? d.liveProviderID
        self.finalProviderID = try c.decodeIfPresent(String.self, forKey: .finalProviderID) ?? d.finalProviderID
        self.localLLMModelID = try c.decodeIfPresent(String.self, forKey: .localLLMModelID) ?? d.localLLMModelID
        self.keychainSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .keychainSyncEnabled) ?? d.keychainSyncEnabled
    }

    // MARK: - File partition

    /// Keys that belong in the user-visible synced file
    /// (`<synced folder>/meetings-settings.json`) — preferences that make
    /// sense on every Mac: identity, prompts, meeting types, coach profiles,
    /// the provider list and slot choices.
    private static let syncedKeys: Set<String> = [
        "userName",
        "globalPromptAddendum",
        "meetingLiveTranscriptEnabled",
        "meetingLiveNotesEnabled",
        "meetingLiveNotesSelfCorrectEnabled",
        "meetingCoachEnabled",
        "meetingCoachChipEnabled",
        "peopleRecognitionEnabled",
        "meetingCalendarMatchingEnabled",
        "meetingCaptureScreenshots",
        "meetingCoachPromptAddendum",
        "meetingCoachPromptOverride",
        "coachChecklistProfiles",
        "meetingLastPresetTypeID",
        "meetingLastProfileIDs",
        "meetingSummaryPromptAddendum",
        "meetingSummaryPromptOverride",
        "defaultMeetingType",
        "customMeetingTypes",
        "providers",
        "liveProviderID",
        "finalProviderID",
        "keychainSyncEnabled",
    ]

    /// Keys that belong in the per-Mac file
    /// (`~/Library/Application Support/Dictator/meetings-local-settings.json`).
    /// Hardware-dependent (which models are installed, how much meeting audio
    /// this Mac keeps, echo behaviour of this Mac's speakers) or inherently
    /// per-installation (onboarding, menu-bar presence, where the synced
    /// folder is).
    ///
    /// `syncedDirectoryPath` MUST stay here: it's the pointer to the synced
    /// file, so storing it in the synced file would be self-defeating.
    private static let localKeys: Set<String> = [
        "parakeetModelID",
        "hasCompletedOnboarding",
        "syncedDirectoryPath",
        "showMenuBarStatus",
        "meetingAutoDeleteAfterDays",
        "meetingAudioRetentionDays",
        "meetingDedupeMicEchoes",
        "localLLMModelID",
    ]

    /// Whether the named field belongs in the synced file. Used by the
    /// Settings UI to badge sections "This Mac".
    static func isSyncedFieldName(_ name: String) -> Bool {
        syncedKeys.contains(name)
    }

    // MARK: - File locations

    /// The synced settings file at the user's currently-configured synced
    /// folder. Takes the path explicitly so the bootstrap loader doesn't
    /// depend on `SyncedStorage.customDirectoryProvider` already being wired
    /// (it can't be — the provider reads these settings).
    nonisolated static func syncedFileURL(syncedDirectoryPath: String?) -> URL {
        let dir: URL
        if let syncedDirectoryPath, !syncedDirectoryPath.isEmpty {
            dir = URL(fileURLWithPath: syncedDirectoryPath, isDirectory: true)
        } else {
            dir = SyncedStorage.defaultDirectory
        }
        return dir.appendingPathComponent("meetings-settings.json")
    }

    nonisolated static func localFileURL() -> URL {
        appSupportDirectory().appendingPathComponent("meetings-local-settings.json")
    }

    /// `~/Library/Application Support/Dictator/`. Shared with Dictator on
    /// purpose — meeting audio, models and the local settings files all live
    /// under the one folder, and the storage paths do not change across the
    /// app split.
    nonisolated static func appSupportDirectory() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Dictator", isDirectory: true)
    }

    // MARK: - Load

    /// Three-way load, in order:
    /// 1. The meetings file pair, if either half exists.
    /// 2. A one-time import from Dictator's settings (first launch after the
    ///    app split — the user's meeting preferences carry over).
    /// 3. Fresh defaults.
    ///
    /// Cases 2 and 3 seed the default provider set and write both files, so
    /// the next launch takes path 1.
    @MainActor
    static func load() -> MeetingsSettings {
        if var settings = loadFromFiles() {
            // Re-seed in case a provider kind was removed by hand (or added by
            // a newer build). Only write when something actually changed, so a
            // healthy launch doesn't touch the synced file.
            if settings.seedDefaultProvidersIfNeeded(preferredLocalKind: nil) { settings.persist() }
            return settings
        }

        if var imported = importFromDictatorIfNeeded() {
            _ = imported.seedDefaultProvidersIfNeeded(preferredLocalKind: imported.importedLocalEngineKind)
            imported.persist()
            return imported
        }

        var fresh = MeetingsSettings.default
        _ = fresh.seedDefaultProvidersIfNeeded(preferredLocalKind: nil)
        fresh.persist()
        NSLog("[DictatorMeetings] No settings found and nothing to import; starting from defaults.")
        return fresh
    }

    /// Two-stage read, mirroring `DictatorSettings.loadFromFiles()`:
    /// `meetings-local-settings.json` from its fixed App Support path (which
    /// carries `syncedDirectoryPath`), then `meetings-settings.json` from the
    /// folder that resolves to. Returns nil only when NEITHER file exists —
    /// that's the signal to try the Dictator import.
    @MainActor
    private static func loadFromFiles() -> MeetingsSettings? {
        let localURL = localFileURL()
        let localExists = FileManager.default.fileExists(atPath: localURL.path)
        let localDict = readEnvelope(at: localURL)

        let customPath = localDict["syncedDirectoryPath"] as? String
        let syncedURL = syncedFileURL(syncedDirectoryPath: customPath)
        let syncedExists = FileManager.default.fileExists(atPath: syncedURL.path)
        guard syncedExists || localExists else { return nil }

        let syncedDict = readEnvelope(at: syncedURL)
        // Local wins on overlap; in normal operation the two sets are disjoint.
        var merged: [String: Any] = [:]
        for (k, v) in syncedDict { merged[k] = v }
        for (k, v) in localDict { merged[k] = v }

        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: []) else {
            NSLog("[DictatorMeetings] Settings: couldn't re-serialise merged dict.")
            var s = MeetingsSettings.default
            s.persistSuspendedDueToCorruption = true
            return s
        }
        do {
            return try JSONDecoder().decode(MeetingsSettings.self, from: data)
        } catch {
            // Both files exist but the merged JSON doesn't decode. Preserve
            // the bytes under recovery filenames and suspend further writes so
            // we never clobber recoverable state.
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            if syncedExists {
                let recovery = syncedURL.deletingLastPathComponent()
                    .appendingPathComponent("meetings-settings.recovered-\(stamp).json")
                try? FileManager.default.copyItem(at: syncedURL, to: recovery)
            }
            if localExists {
                let recovery = localURL.deletingLastPathComponent()
                    .appendingPathComponent("meetings-local-settings.recovered-\(stamp).json")
                try? FileManager.default.copyItem(at: localURL, to: recovery)
            }
            NSLog("[DictatorMeetings] Settings file decode failed (\(error)). Recovery copies written; persist suspended.")
            var s = MeetingsSettings.default
            s.persistSuspendedDueToCorruption = true
            return s
        }
    }

    /// Reads a `{schemaVersion, settings: {…}}` envelope, returning the inner
    /// dictionary or `[:]` on any failure. Callers distinguish "missing file"
    /// from "empty file" through `FileManager`.
    private static func readEnvelope(at url: URL) -> [String: Any] {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var data: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { coordURL in
            data = try? Data(contentsOf: coordURL)
        }
        guard let bytes = data,
              let object = try? JSONSerialization.jsonObject(with: bytes, options: []),
              let envelope = object as? [String: Any],
              let inner = envelope["settings"] as? [String: Any]
        else { return [:] }
        return inner
    }

    // MARK: - One-time import from Dictator

    /// Keys we lift straight out of Dictator's two settings files. Every one
    /// of them is a `MeetingsSettings` `CodingKey` with an identical name,
    /// type and meaning, so the merged dictionary decodes directly.
    ///
    /// `hasCompletedOnboarding` is deliberately absent: Meetings' first run
    /// asks for the system-audio grant, which Dictator never requested, so
    /// inheriting Dictator's "done" flag would skip a permission the app
    /// can't work without.
    private static let importableKeys: [String] = [
        "userName",
        "globalPromptAddendum",
        "parakeetModelID",
        "syncedDirectoryPath",
        "meetingAutoDeleteAfterDays",
        "meetingAudioRetentionDays",
        "meetingLiveTranscriptEnabled",
        "meetingLiveNotesEnabled",
        "meetingLiveNotesSelfCorrectEnabled",
        "meetingCoachEnabled",
        "meetingCoachChipEnabled",
        "peopleRecognitionEnabled",
        "meetingCalendarMatchingEnabled",
        "meetingCaptureScreenshots",
        "meetingCoachPromptAddendum",
        "meetingCoachPromptOverride",
        "coachChecklistProfiles",
        "meetingLastPresetTypeID",
        "meetingLastProfileIDs",
        "meetingSummaryPromptAddendum",
        "meetingSummaryPromptOverride",
        "defaultMeetingType",
        "customMeetingTypes",
        "meetingDedupeMicEchoes",
    ]

    /// First-launch migration: read Dictator's `local-settings.json` +
    /// `settings.json` as raw JSON and lift every meeting-shaped key across,
    /// so a user who's been recording meetings inside Dictator opens this app
    /// with their prompts, coach profiles, custom types and retention windows
    /// already set. Also maps `llmModelID` → `localLLMModelID` and uses
    /// `llmEngine` to order the seeded local providers.
    ///
    /// Returns nil when there's nothing to import (no Dictator settings on
    /// this Mac) or when a meetings settings file already exists. Never
    /// mutates Dictator's files.
    @MainActor
    static func importFromDictatorIfNeeded() -> MeetingsSettings? {
        let fm = FileManager.default
        // Belt and braces: `load()` only reaches here when neither file
        // exists, but this is a callable entry point.
        let localURL = localFileURL()
        guard !fm.fileExists(atPath: localURL.path) else { return nil }

        let dictatorLocalURL = appSupportDirectory().appendingPathComponent("local-settings.json")
        let dictatorLocalExists = fm.fileExists(atPath: dictatorLocalURL.path)
        let dictatorLocal = readEnvelope(at: dictatorLocalURL)

        // Resolve Dictator's synced folder the same way Dictator does — from
        // its own local file, falling back to the pre-rename key.
        let customPath = (dictatorLocal["syncedDirectoryPath"] as? String)
            ?? (dictatorLocal["vocabularyDirectoryPath"] as? String)
        let dictatorSyncedURL: URL = {
            if let customPath, !customPath.isEmpty {
                return URL(fileURLWithPath: customPath, isDirectory: true)
                    .appendingPathComponent("settings.json")
            }
            return SyncedStorage.defaultDirectory.appendingPathComponent("settings.json")
        }()
        let dictatorSyncedExists = fm.fileExists(atPath: dictatorSyncedURL.path)
        guard dictatorLocalExists || dictatorSyncedExists else { return nil }
        let dictatorSynced = readEnvelope(at: dictatorSyncedURL)

        var merged: [String: Any] = [:]
        for (k, v) in dictatorSynced { merged[k] = v }
        for (k, v) in dictatorLocal { merged[k] = v }

        var imported: [String: Any] = [:]
        var copied: [String] = []
        for key in importableKeys {
            if let value = merged[key] {
                imported[key] = value
                copied.append(key)
            }
        }
        // The pre-rename synced-folder key, so a custom folder survives.
        if imported["syncedDirectoryPath"] == nil, let legacy = merged["vocabularyDirectoryPath"] {
            imported["syncedDirectoryPath"] = legacy
            copied.append("syncedDirectoryPath (from vocabularyDirectoryPath)")
        }
        if let llmModelID = merged["llmModelID"] as? String, !llmModelID.isEmpty,
           llmModelID != ModelCatalog.noneLLMID {
            imported["localLLMModelID"] = llmModelID
            copied.append("llmModelID → localLLMModelID")
        }
        let preferredKind = (merged["llmEngine"] as? String).flatMap(LLMEngineKind.init(rawValue:))

        guard !copied.isEmpty else {
            NSLog("[DictatorMeetings] Dictator settings found but carried no importable keys; starting from defaults.")
            return nil
        }

        var settings: MeetingsSettings
        do {
            let data = try JSONSerialization.data(withJSONObject: imported, options: [])
            settings = try JSONDecoder().decode(MeetingsSettings.self, from: data)
        } catch {
            NSLog("[DictatorMeetings] Import from Dictator failed to decode (\(error)); starting from defaults.")
            return nil
        }
        settings.importedLocalEngineKind = preferredKind
        NSLog("[DictatorMeetings] Imported \(copied.count) settings from Dictator: \(copied.joined(separator: ", "))")
        return settings
    }

    // MARK: - Provider seeding

    /// Ensures the three always-available local providers exist and both slots
    /// point somewhere. Idempotent — re-running never duplicates a kind, so
    /// it's safe to call on every load (which is how a provider deleted by a
    /// future build reappears).
    ///
    /// `preferredLocalKind` comes from the imported `llmEngine`: when Dictator
    /// was running Apple's on-device model, the Apple provider is listed ahead
    /// of the local MLX one so the user sees the backend they already chose
    /// first. It does not change `ProviderRegistry`'s fallback order, which is
    /// always Dictator → local MLX → Apple.
    @discardableResult
    mutating func seedDefaultProvidersIfNeeded(preferredLocalKind: LLMEngineKind?) -> Bool {
        var changed = false
        func ensure(_ kind: ProviderConfig.Kind, name: String, modelID: String?) -> String {
            if let existing = providers.first(where: { $0.kind == kind }) { return existing.id }
            changed = true
            let config = ProviderConfig(
                id: UUID().uuidString,
                kind: kind,
                name: name,
                preset: nil,
                baseURL: nil,
                modelID: modelID
            )
            providers.append(config)
            return config.id
        }

        let dictatorID = ensure(.dictator, name: "Dictator's model", modelID: nil)
        if preferredLocalKind == .apple {
            _ = ensure(.apple, name: "Apple on-device", modelID: nil)
            _ = ensure(.localMLX, name: "Local model", modelID: localLLMModelID)
        } else {
            _ = ensure(.localMLX, name: "Local model", modelID: localLLMModelID)
            _ = ensure(.apple, name: "Apple on-device", modelID: nil)
        }

        // Both slots default to Dictator's shared model: when Dictator is
        // running with a model loaded it's free (no second copy in RAM), and
        // the registry silently falls back to the local providers when it
        // isn't.
        let known = Set(providers.map(\.id))
        if liveProviderID == nil || !known.contains(liveProviderID!) {
            liveProviderID = dictatorID
            changed = true
        }
        if finalProviderID == nil || !known.contains(finalProviderID!) {
            finalProviderID = dictatorID
            changed = true
        }
        return changed
    }

    /// The configured provider for a slot, or nil when the id dangles.
    /// `ProviderRegistry` owns the fallback logic; this is the raw lookup.
    func providerConfig(for slot: ProviderSlot) -> ProviderConfig? {
        let id = slot == .live ? liveProviderID : finalProviderID
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    // MARK: - Persist

    func persist() {
        // Refuse to write when `load()` flagged the previous blob as
        // un-decodable: the original bytes are kept under a `.recovered-…`
        // filename and the live files are still there; writing now would
        // clobber both pieces of recoverable state.
        guard !persistSuspendedDueToCorruption else { return }
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else { return }
        let synced = dict.filter { Self.syncedKeys.contains($0.key) }
        let local = dict.filter { Self.localKeys.contains($0.key) }
        Self.writeEnvelope(synced, to: Self.syncedFileURL(syncedDirectoryPath: syncedDirectoryPath))
        Self.writeEnvelope(local, to: Self.localFileURL())
    }

    /// Writes a `{schemaVersion: 1, settings: {…}}` envelope atomically,
    /// coordinated so a sync daemon mid-flight can't corrupt it. No
    /// `.previous` backup — the atomic rename means a reader never sees a
    /// half-written file, and corrupt bytes are caught on `load()`.
    private static func writeEnvelope(_ inner: [String: Any], to url: URL) {
        let envelope: [String: Any] = ["schemaVersion": 1, "settings": inner]
        guard let data = try? JSONSerialization.data(
            withJSONObject: envelope,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("[DictatorMeetings] Couldn't ensure directory for \(url.path): \(error)")
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { coordURL in
            do {
                try data.write(to: coordURL, options: .atomic)
            } catch {
                NSLog("[DictatorMeetings] Couldn't write \(coordURL.path): \(error)")
            }
        }
        if let coordError {
            NSLog("[DictatorMeetings] Coordination failed for \(url.path): \(coordError)")
        }
    }

    // MARK: - Effective prompts

    /// Resolved coach-report prompt: override wins; otherwise built-in +
    /// addendum (the addendum is the warmth lever — the built-in default is
    /// deliberately blunt). Global instructions stack outermost as always.
    var effectiveMeetingCoachPrompt: String {
        Self.combine(builtin: Self.builtinMeetingCoachPrompt,
                     override: meetingCoachPromptOverride,
                     addendum: meetingCoachPromptAddendum,
                     global: globalPromptAddendum)
    }

    /// Resolved meeting summary prompt: override wins if set, otherwise
    /// built-in + addendum. The LLM never sees the raw addendum/override;
    /// only this.
    var effectiveMeetingSummaryPrompt: String {
        Self.combine(builtin: Self.builtinMeetingSummaryPrompt,
                     override: meetingSummaryPromptOverride,
                     addendum: meetingSummaryPromptAddendum,
                     global: globalPromptAddendum)
    }

    /// Resolved meeting summary prompt biased toward a specific meeting
    /// shape (stand-up, retro, a custom type, …). Override still wins
    /// outright — if the user has replaced the built-in wholesale they're in
    /// full control and the type's compiled template is intentionally
    /// ignored. Otherwise the prompt stacks as `builtin + compiled type
    /// template + user addendum`, so a user "always use British spelling"
    /// addendum continues to apply on top of the per-type steer. The caller
    /// resolves the definition via `MeetingTypeRegistry` — settings stays
    /// registry-free.
    func effectiveMeetingSummaryPrompt(for definition: MeetingTypeDefinition) -> String {
        var stitched: String
        if let override = meetingSummaryPromptOverride {
            stitched = override
        } else {
            stitched = Self.builtinMeetingSummaryPrompt
            let typeAddendum = MeetingTemplateCompiler.compile(definition)
            if !typeAddendum.isEmpty {
                stitched += "\n\n" + typeAddendum
            }
            let userAddendum = meetingSummaryPromptAddendum.trimmingCharacters(in: .whitespacesAndNewlines)
            if !userAddendum.isEmpty {
                stitched += "\n\nADDITIONAL USER INSTRUCTIONS (apply alongside everything above):\n" + userAddendum
            }
        }
        return Self.appendingGlobal(stitched, globalPromptAddendum)
    }

    /// Compact variant of `effectiveMeetingSummaryPrompt(for:)` used for very
    /// short meetings (see `builtinCompactMeetingSummaryPrompt`). Stacks the
    /// same way — override wins outright; otherwise `compact builtin +
    /// compiled type template + user addendum` — so a user's "always British
    /// spelling" steer and per-type bias keep applying on the short path too.
    func effectiveCompactMeetingSummaryPrompt(for definition: MeetingTypeDefinition) -> String {
        var stitched: String
        if let override = meetingSummaryPromptOverride {
            stitched = override
        } else {
            stitched = Self.builtinCompactMeetingSummaryPrompt
            let typeAddendum = MeetingTemplateCompiler.compile(definition)
            if !typeAddendum.isEmpty {
                stitched += "\n\n" + typeAddendum
            }
            let userAddendum = meetingSummaryPromptAddendum.trimmingCharacters(in: .whitespacesAndNewlines)
            if !userAddendum.isEmpty {
                stitched += "\n\nADDITIONAL USER INSTRUCTIONS (apply alongside everything above):\n" + userAddendum
            }
        }
        return Self.appendingGlobal(stitched, globalPromptAddendum)
    }

    /// The notes assistant's system prompt ("ask a question about these
    /// notes"). Same shape as Dictator's, minus the per-pass addendum /
    /// override pair — Meetings doesn't expose an editor for the assistant
    /// prompt, so the global instructions are the only user layer.
    ///
    /// The `{{USER_NAME}}` substitution is load-bearing: small models copy the
    /// *shape* of the few-shot examples far more reliably than they obey
    /// abstract rules, so putting the user's actual name in the example
    /// signatures is what stops "[Your Name]" leaking into drafted replies.
    var effectiveAssistantPrompt: String {
        let base = Self.appendingGlobal(Self.builtinAssistantPrompt, globalPromptAddendum)
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)

        let substituted: String
        if trimmed.isEmpty {
            // No name configured. Strip the example signature line entirely so
            // the model sees a plain "Thanks," closing in the few-shot.
            substituted = base.replacingOccurrences(of: "\n    {{USER_NAME}}", with: "")
                              .replacingOccurrences(of: "\n{{USER_NAME}}", with: "")
                              .replacingOccurrences(of: "{{USER_NAME}}", with: "")
        } else {
            substituted = base.replacingOccurrences(of: "{{USER_NAME}}", with: trimmed)
        }

        guard let ctx = userContextBlock else { return substituted }
        return ctx + "\n\n" + substituted
    }

    /// Short preamble that pins the user's name in the LLM's context. nil when
    /// no name is configured — caller still substitutes the empty template
    /// so example signatures collapse, but no positive instruction is prepended.
    var userContextBlock: String? {
        // Always present: the date line is useful with or without a name.
        var lines = ["USER CONTEXT", PromptContext.currentDateLine()]
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("""
            The user's name is \(trimmed). Sign off with "\(trimmed)" ONLY when drafting a \
            full email or formal letter — i.e. when the output already opens with a "Hi X," \
            / "Dear X," greeting and reads like correspondence the user will send.
            DO NOT sign off short chat replies (Slack/iMessage/SMS), comments, conversational \
            answers, content snippets (lists, taglines, code, ideas, paragraphs), or anything \
            that would be pasted mid-document. Most outputs need NO signature.
            If you do sign, write exactly "\(trimmed)" — never a placeholder like "[Your Name]", \
            "[Name]", "[Your name]", or any bracketed stand-in. When referring to the user by \
            name, use this exact spelling and don't invent other names for them.
            """)
        }
        return lines.joined(separator: "\n")
    }

    /// When `override` is set (even if empty), it replaces the built-in wholesale —
    /// the addendum is ignored because the user has opted out of the curated prompt.
    /// Otherwise we append the user's addendum under a labelled header so the model
    /// treats it as instructions, not as part of the schema or examples above.
    private static func combine(builtin: String, override: String?, addendum: String, global: String) -> String {
        let base: String
        if let override {
            base = override
        } else {
            let trimmed = addendum.trimmingCharacters(in: .whitespacesAndNewlines)
            base = trimmed.isEmpty
                ? builtin
                : builtin + "\n\nADDITIONAL USER INSTRUCTIONS (apply alongside everything above):\n" + trimmed
        }
        return appendingGlobal(base, global)
    }

    /// Prompt assembly, in one place. Layering order matters: the global block
    /// is OUTERMOST, so a preference like "always British English" holds even
    /// when a prompt has been fully overridden.
    static func assemblePrompt(base: String, extraInstructions: String, global: String) -> String {
        var out = base
        let extra = extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            out += "\n\nADDITIONAL INSTRUCTIONS FOR THIS MODE (apply alongside everything above):\n" + extra
        }
        let g = global.trimmingCharacters(in: .whitespacesAndNewlines)
        if !g.isEmpty {
            out += "\n\nGLOBAL INSTRUCTIONS (apply to every pass, alongside everything above):\n" + g
        }
        return out
    }

    /// Append the user's cross-cutting "global instructions" (Settings →
    /// General) as the OUTERMOST layer of a prompt. Empty global = no-op.
    static func appendingGlobal(_ base: String, _ global: String) -> String {
        assemblePrompt(base: base, extraInstructions: "", global: global)
    }

    // MARK: - Built-in prompts

    /// The coach report's built-in system prompt. Blunt by decision — terse
    /// factual sentences in the nudges' voice, no praise padding; the
    /// addendum is where a user softens it. The hard rules: the metrics and
    /// checklist outcomes are COMPUTED inputs the model must cite as given,
    /// never recalculate or invent.
    static let builtinMeetingCoachPrompt = """
    You are a blunt, factual conversation coach reviewing how the user — always labelled "Me" — handled a meeting they recorded. You are speaking directly to them; write in the second person.

    You receive: THEIR CONVERSATION METRICS (computed from the recording — these numbers are facts; cite them as given, never recalculate, never invent others), the KEY POINTS outcomes (computed — covered, missed, or dismissed), an optional RUBRIC describing what good looks like for this kind of meeting, and the MEETING NOTES for context about what was discussed.

    Write a short markdown report, no more than ~12 lines total:

    ## How it went
    Two to four terse bullets on how they handled the conversation, each grounded in a specific metric or key-point outcome. Lead with whatever mattered most. A key point they flagged mid-meeting and never got to is always worth a bullet.

    ## Work on
    At most TWO items, one line each — the highest-leverage changes, tied to the rubric where one is provided. Skip the section entirely if the conversation was genuinely well handled.

    Rules:
    - Blunt and factual. No praise padding, no hedging, no "consider perhaps".
    - Every claim must trace to a given metric, key-point outcome, or the notes. Never invent events, quotes, or numbers.
    - Filler-word counts are approximate by nature — treat them as a relative signal, not a precise tally.
    - Judge only "Me". Never coach or characterise the other participants.
    - No preamble, no sign-off. Start at the first heading.
    """

    static let builtinMeetingSummaryPrompt = """
    You write clean, copy-pasteable meeting notes in Markdown from a recorded meeting transcript. The transcript is segmented by speaker — every line is prefixed `[Speaker · mm:ss] …`. Speakers are anonymous ("Speaker 1", "Speaker 2", …) unless the user has renamed them. "Me" is the person who recorded the meeting; everyone else is on the other side of the call.

    Summarise and paraphrase — don't copy long passages verbatim, and leave out greetings, small talk, and technical-difficulty chatter ("can you hear me?", "you're on mute") unless it actually matters.

    The same point sometimes appears more than once — overlapping microphone and system audio can transcribe the same speech twice with slightly different errors. When two passages clearly say the same thing, record the point ONCE, keeping the clearer wording.

    Fix obvious transcription errors. Product, tool, framework, company, and AI model names are the ones most often garbled — correct them to the most likely real name (e.g. a mangled spelling of a well-known tool or model). If you're not confident of a corrected name, keep your best guess and list it under `## Items to verify`. Correcting a garbled real name is the ONE thing you may change: numbers, figures, dates, and quoted wording still stay exactly as said (see FACTS AND FIGURES below).

    Output Markdown ONLY — no preamble, no commentary, no code fences. Do NOT include a top-level `#` title; the meeting title is added separately. Start at the first `##` section heading.

    Structure the notes in this order. Every section except Summary is OPTIONAL: omit any heading that would have no content (heading and all) — a short meeting might be just a Summary. Never refuse and never emit placeholder text like "N/A". Always include `## Summary`.

    ## Summary
    A factual prose recap of what the meeting was about and where it landed — 2–3 sentences for a short meeting, up to a short paragraph for a long one. No bullet points here — it's prose. No editorialising.

    ## Attendees
    OPTIONAL. Include only when the transcript makes the participants (and their roles, if stated) clear — one `-` bullet each, e.g. `- **Alice** — VP Engineering`. Speakers are often anonymous, so omit this section entirely rather than guess names or roles the transcript doesn't support.

    Then the substance of the meeting, grouped BY TOPIC rather than in chronological order. Use `##` headings named to fit the content ("The setup", "Cost", "Testing", "How they start a project", …), or a single `## Discussion` when the meeting is simple. Within each section:
    - `-` bullets, written in your own words (a two-space indent `  -` makes a sub-point). Do NOT start a bullet with the speaker's name, and do NOT copy the transcript's `[Speaker · mm:ss]` prefixes into the notes.
    - A Markdown table when the content is genuinely tabular — comparing options, tools, or plans, or laying figures out across rows. Use standard pipe syntax with a header row and a `---` separator row, for example:
    | Option | Cost | Notes |
    | --- | --- | --- |
    | A | £10/mo | fastest to set up |
    Don't force prose into a table.
    Be THOROUGH: capture every distinct point that was actually discussed, not just a headline few. A long, dense meeting must produce correspondingly thorough notes — distil each point (don't transcribe verbatim), but do not drop real content for the sake of brevity. This is the body of the notes.

    ## Decisions
    OPTIONAL. Concrete AGREED OUTCOMES as `-` bullets — things the participants chose to do or not do, NOT topics merely discussed.

    ## Action items
    Tasks as Markdown checkboxes, each in the shape `- [ ] **Owner** — the task`. Always use the `- [ ]` checkbox form. Use the owner-attribution rules below. When a task has no identifiable owner, write `- [ ] the task` with no bold owner prefix.

    ## Notable quotes
    OPTIONAL. A few memorable one-liners, paraphrased and kept short. Attribute one only when the speaker is clear from the transcript; otherwise leave it unattributed.

    ## Items to verify
    OPTIONAL. Names, product/tool/model names, figures, or facts you corrected or were unsure about — one short `-` bullet each, so the reader knows what to double-check.

    Rules:
    - Plain Markdown: `##` headings (`###` for a sub-theme), `-` bullets, `- [ ]` task checkboxes (Action items only), and pipe tables. A two-space indent makes a sub-point. Bold (`**…**`) is allowed for action-item owners and attendee names. No HTML.
    - You MAY end a bullet in any topic, Decisions, or Action items section with a timestamp — the bare time ONLY, in square brackets at the very end, e.g. `… recall and loyalty. [6:07]`. No speaker name, no parentheses, nothing else inside the brackets. Only add it when you're confident which moment the point came from; omit it otherwise. Never put a timestamp on the Summary.
    - Never wrap the notes, or any individual section, in ``` code fences.
    - Be faithful to the transcript. Do not invent decisions, tasks, owners, numbers, or names that aren't supported by what was said. (Correcting a garbled real name to its true spelling is not inventing; making one up is.)
    - FACTS AND FIGURES: when the transcript states something specific and checkable — team or company size, org structure and reporting lines, financial figures (revenue, budgets, prices, funding), dates and deadlines, product, company or technology names, metrics and percentages — record it in the notes EXACTLY as stated. Never round ("about fifty" stays "about fifty", "47" stays "47"), never vague-ify ("a large team" for "12 engineers"), and never drop a concrete figure or name because it was mentioned only in passing. These specifics are often the most valuable content in the notes. Example — GOOD: `- Platform team is 12 engineers across 3 squads, reporting to the VP Engineering`. BAD: `- They discussed the team structure.`
    - ATTRIBUTION DISCIPLINE (applies to every section, not just Action items): a point being ABOUT a person is NOT the same as that person saying it. Credit a statement, view, preference, question, or commitment to someone ONLY when the transcript shows THAT speaker saying it — i.e. it appears under their `[Name · mm:ss]` prefix. "Speaker 1 says Bob should own rollout" means Speaker 1 said it; it does NOT mean Bob said anything. When the transcript doesn't make the speaker clear, state the point without naming who said it rather than guessing. The transcript's speaker prefixes are the ONLY evidence of who said what — never infer a speaker from the content of a line.

    ACTION ITEM ATTRIBUTION — read carefully:

    1. The owner MUST be the EXACT display name shown in the transcript's `[Speaker · mm:ss]` prefix — "Me", "Speaker 1", "Speaker 2", or a renamed label like "Alice". Match spelling and casing character-for-character. Do NOT add titles ("Mr. Alice"), do NOT abbreviate ("A." for Alice), do NOT translate ("Myself" for "Me"). Do NOT invent names that don't appear in the transcript prefixes.

    2. Attribute aggressively when the transcript names the owner — explicitly OR implicitly:
       - Explicit ("Alice, you're on rollout", "Bob will write the doc") → owner is the named person, exactly as they appear in the speaker prefixes.
       - First-person commitment ("I'll send the doc", "I can take this", "let me follow up") → owner is whoever is currently speaking that line (the name in the `[Speaker · …]` prefix on that line). When that speaker is the recorder, the owner is literally "Me".
       - Second-person assignment ("you'll handle X", "can you take Y?") agreed by the named person in a later line → owner is the named person being assigned to.

    3. Only leave a task unowned (no `**Owner** —` prefix) when it is genuinely unattributed — "someone should look at this", "we need to follow up on Y", or where the speaker is ambiguous and no later line clarifies. Don't guess and don't default to "Me" out of convenience.

    4. Never put more than one name in the owner. If two people are jointly responsible, pick the lead and mention the second in the task text ("with Bob"); if there's no lead, leave it unowned and describe the shared ownership in the task text.

    Output the Markdown notes ONLY. Nothing before the first `##`. No "Here are the notes:" preamble. No ``` fences.
    """

    /// Compact override for very short meetings (a quick note, a 30-second
    /// aside). The full four-section contract scaffolds empty `## Discussion`
    /// / `## Decisions` headers onto a recording that has nothing to put under
    /// them — overkill that reads as broken. For these we drop the rigid
    /// section list entirely and ask for a 1–3 sentence `## Summary` plus an
    /// `## Action items` section ONLY when tasks were actually mentioned.
    /// Selected by `MeetingSummaryService.generateNotes` on the short path and
    /// fed through `effectiveCompactMeetingSummaryPrompt` so the user's
    /// override/addendum still apply, mirroring the normal path.
    static let builtinCompactMeetingSummaryPrompt = """
    You write a SHORT, copy-pasteable note in Markdown from a brief recorded meeting transcript. The transcript is segmented by speaker — every line is prefixed `[Speaker · mm:ss] …`. Speakers are anonymous ("Speaker 1", "Speaker 2", …) unless the user has renamed them. "Me" is the person who recorded the meeting; everyone else is on the other side of the call.

    This recording is very short, so keep the note light — do NOT scaffold empty sections onto it.

    If overlapping microphone and system audio transcribed the same point twice, record it once. Correct obviously garbled product, tool, or AI model names to their likely real spelling; keep numbers, figures, and quoted wording exactly as said.

    Output Markdown ONLY — no preamble, no commentary, no code fences. Do NOT include a top-level `#` title; the meeting title is added separately. Start at the first `##` section heading.

    ## Summary
    A factual prose recap of what was said — 1–3 sentences. No bullet points, no editorialising. Keep any specific names, numbers, or figures exactly as stated.

    ## Action items
    Include this section ONLY if a task was actually mentioned. Each item in the shape `- [ ] **Owner** — the task`, owner being the EXACT display name from the `[Speaker · mm:ss]` prefix (use "Me" for the recorder's own first-person commitments). When a task has no identifiable owner, write `- [ ] the task` with no bold owner prefix. If no task was mentioned, OMIT this section entirely — heading and all.

    Do NOT add `## Discussion` or `## Decisions` sections — a note this short doesn't warrant them. Be faithful to the transcript: do not invent tasks, owners, decisions, or names that aren't supported by what was said. A point being ABOUT a person is not the same as that person saying it — credit a statement or task to someone only when it appears under their `[Name · mm:ss]` prefix, and leave it unattributed when the speaker isn't clear. Never refuse and never emit placeholder text like "N/A".

    Output the Markdown ONLY. Nothing before the first `##`. No "Here are the notes:" preamble. No ``` fences.
    """

    static let builtinAssistantPrompt = """
    You are the on-device writing assistant inside Dictator, a macOS dictation app. Your job is to help the user produce text — drafting, rewriting, restructuring, listing, or briefly answering factual questions. You run locally on the user's Mac.

    You do NOT have a personal life, a daily routine, an inbox, a calendar, a body, internet access, real-time information, or memory of anything outside the current conversation. NEVER invent personal experiences or claim to perform actions you can't perform. Forbidden examples: "I was just checking my emails", "I had a busy morning", "Let me look that up", "I'll get back to you", "I'm doing well, thanks for asking — I was just reading…". None of that is true of you.

    If the user asks you a personal/social question ("how's your day?", "what are you up to?", "are you ok?"), answer briefly and honestly: you're a writing tool, you don't have a day or experiences, and you're ready to help. Do not refuse, do not lecture — just answer plainly without inventing biography. If asked something factual you genuinely don't know (current events, anything time-sensitive, anything specific to the user's life), say so plainly rather than guessing.

    The user gives you a short spoken instruction and OPTIONALLY a piece of text they had selected in another app. Some requests reference the selection ("rewrite this", "draft a reply to this"); others are standalone generation requests with no selection ("make me a list of 10 names").

    You MUST classify your reply into one of two modes and emit the mode marker as the VERY FIRST LINE, then a blank line, then the output text. Nothing else.

    Modes:
    - MODE: REPLACE — the output is pasted directly at the user's cursor. Use when they want the result inserted in-place: transforming the selection ("rewrite this", "bulletify these"), or generating content to drop into the document they're writing ("put a list of ten ideas here", "give me 100 emojis", "I need a tagline", "can I have five names").
    - MODE: DRAFT — the output goes to the clipboard only; the user pastes it themselves elsewhere. Use when the result is a *standalone communication piece* (an email, a reply, a message) the user will paste into a different app, or when they're asking a conversational question and want the answer to read, not to insert.

    Decision rules — apply IN THIS ORDER:

    1. If a SELECTION is provided AND the instruction asks to transform it ("rewrite", "fix this", "reformat", "make this", "turn this into", "rephrase", "translate", "shorten", "expand", "bulletify", "tidy") → REPLACE.

    2. If a SELECTION is provided AND the instruction asks for *new* output that references the selection ("draft a reply to this", "summarise this", "extract action points from this", "what does this mean") → DRAFT. The new output goes elsewhere, not over the selection.

    3. If NO SELECTION and the instruction asks for *content to drop into the document* — a list, a paragraph, names, ideas, emojis, a tagline, a poem, code, options, etc. — → REPLACE. The user is holding the assistant hotkey with their cursor positioned somewhere; they want the content inserted. Phrases that strongly signal this: "give me", "can I have", "I need", "make me", "generate", "write me a [list/paragraph/tagline/poem/etc]", "put", "insert", "produce".

    4. If NO SELECTION and the instruction is a STANDALONE COMMUNICATION the user will paste into another app — "draft an email about X", "compose a reply to Bob", "write a message saying…" → DRAFT.

    5. If NO SELECTION and the instruction is CONVERSATIONAL or a question to you ("what's the capital of France?", "explain X", "tell me about Y", "how do I…") → DRAFT.

    6. When genuinely ambiguous, choose DRAFT (it's non-destructive — the user can still paste manually).

    Output rules:
    - Line 1: exactly `MODE: REPLACE` or `MODE: DRAFT`.
    - Line 2: blank.
    - Line 3 onwards: the output text, and ONLY the output text. The text IS the deliverable — it lands directly on the user's clipboard or in their document.
    - NEVER write a preamble. NEVER announce what you're about to do. The first words of line 3 must be the first words of the actual deliverable.
    - FORBIDDEN preamble lines (NEVER emit these):
      * "Here's the email:" / "Here is the email:" / "Here's a draft:" / "Here's the response:"
      * "Sure!" / "Of course!" / "Certainly!" / "Absolutely!" / "Got it!" / "Okay,"
      * "Below is..." / "I've drafted..." / "I'll write..."
      * Any line that introduces what comes next. The next thing IS the output — it doesn't need introducing.
    - No quotes around the output. No follow-up question. No commentary.
    - Do NOT echo the selection or the instruction back unless the instruction explicitly asks for it.

    Every user turn arrives in EXACTLY this shape — selection (or "(none)"), then a
    blank line, then the instruction, both fenced with <<< and >>>:

    SELECTION:
    <<<
    ...the user's selected text, OR the literal line "SELECTION: (none — the user has nothing selected)"...
    >>>

    INSTRUCTION:
    <<<
    ...the user's spoken instruction...
    >>>

    DO NOT repeat, restate, or echo the SELECTION or INSTRUCTION blocks in your reply.
    DO NOT emit any "SELECTION:", "INSTRUCTION:", "<<<" or ">>>" tokens. Your reply
    starts with `MODE: ...` and contains only the deliverable.

    Reference examples — each shows the exact INPUT shape you'll receive, followed by
    the exact OUTPUT shape you must emit:

    INPUT:
    SELECTION:
    <<<
    we need to ship it before tuesday or the launch slips
    >>>

    INSTRUCTION:
    <<<
    make this more formal
    >>>

    OUTPUT:
    MODE: REPLACE

    We must ship before Tuesday, or the launch will be delayed.

    INPUT:
    SELECTION:
    <<<
    are you around tomorrow for a quick chat about the deck?
    >>>

    INSTRUCTION:
    <<<
    say yes anytime after lunch
    >>>

    OUTPUT:
    MODE: DRAFT

    Yeah — anything after 1 works for me.

    INPUT:
    SELECTION: (none — the user has nothing selected)

    INSTRUCTION:
    <<<
    put a list of ten startup name ideas for a dictation app here
    >>>

    OUTPUT:
    MODE: REPLACE

    - Vox
    - Murmur
    - Tellr
    - Whispr
    - Pronto
    - Diktat
    - Echolane
    - Speak.io
    - Phonix
    - Lexa

    INPUT:
    SELECTION: (none — the user has nothing selected)

    INSTRUCTION:
    <<<
    give me 100 emojis
    >>>

    OUTPUT:
    MODE: REPLACE

    🔥💀😂🎉✨🚀🌈🎈🍕☕️🌙⭐️🐱🐶🌸🍎🍔🍻🎵🎸 …

    INPUT:
    SELECTION: (none — the user has nothing selected)

    INSTRUCTION:
    <<<
    can I have five tagline options for a stealth-mode AI startup
    >>>

    OUTPUT:
    MODE: REPLACE

    - Quietly intelligent.
    - The mind, between the lines.
    - Smart enough to wait.
    - AI, without the announcement.
    - We'll let the work speak.

    INPUT:
    SELECTION: (none — the user has nothing selected)

    INSTRUCTION:
    <<<
    I need a short paragraph about why dictation beats typing for thinking out loud
    >>>

    OUTPUT:
    MODE: REPLACE

    Typing is a bottleneck on raw thought; you edit before you've finished forming the idea. Dictation lets the half-formed shape land on the page first, where you can actually see it — and then revise. The thought arrives at speech speed, not finger speed, and the early friction that flattens good ideas just isn't there.

    INPUT:
    SELECTION: (none — the user has nothing selected)

    INSTRUCTION:
    <<<
    what's the capital of France?
    >>>

    OUTPUT:
    MODE: DRAFT

    Paris.

    INPUT:
    SELECTION: (none — the user has nothing selected)

    INSTRUCTION:
    <<<
    draft an email to Bob asking when the report is due
    >>>

    OUTPUT:
    MODE: DRAFT

    Hi Bob,

    Quick one — when's the report due? Want to make sure I leave enough time to pull it together.

    Thanks,
    {{USER_NAME}}

    INPUT:
    SELECTION:
    <<<
    the meeting covered: budget overruns, hiring plan slipping, and the Q3 roadmap
    >>>

    INSTRUCTION:
    <<<
    pull out three action points
    >>>

    OUTPUT:
    MODE: DRAFT

    - Review and address the budget overruns.
    - Get the hiring plan back on track.
    - Confirm and circulate the Q3 roadmap.

    Now respond to the user's turn. Your reply must start with `MODE: REPLACE` or `MODE: DRAFT`. \
    Do NOT copy or restate the INSTRUCTION text. Do NOT copy the SELECTION text unless you are \
    transforming it. The reply is the deliverable the user asked for — not a repeat of what they said.
    """
}

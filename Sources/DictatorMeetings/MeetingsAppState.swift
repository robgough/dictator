import Foundation
import MLX
import Observation
import SwiftUI

/// The Meetings app's single piece of global state — the counterpart to
/// Dictator's `AppState`, minus everything dictation.
///
/// Two jobs: own the settings blob (and the one place that saves it), and hold
/// the handful of cross-window values the meetings UI mirrors — is a recording
/// in flight, which coach engine is live, is the window focused. The island and
/// the menu-bar status item read those while the main window is closed, which
/// is the normal state mid-call.
@MainActor
@Observable
final class MeetingsAppState {
    static let shared = MeetingsAppState()

    var settings: MeetingsSettings

    /// Captured `EnvironmentValues.openSettings`, populated by the SwiftUI
    /// tree on first render. Stored here so non-SwiftUI surfaces (the URL
    /// handler, the menu-bar item) can open Settings without SwiftUI's "use
    /// SettingsLink" runtime fault. Optional because the window may not have
    /// rendered yet on a cold launch.
    var openSettingsAction: (@MainActor () -> Void)?

    /// Captured `EnvironmentValues.openWindow` for the meetings window, so the
    /// `dictator-meetings://` URL handler and the menu-bar item can front it.
    var openMeetingsWindowAction: (@MainActor () -> Void)?

    /// One-shot flag set by the menu bar's "Record meeting" entry and the
    /// `dictator-meetings://record` URL. Read (and immediately cleared) by the
    /// root view the next time it appears or observes a change, at which point
    /// it kicks off the same flow as the in-window Record button. The flag
    /// dodges the "window doesn't exist yet" race: the caller sets it *then*
    /// opens the window, so the view can consume it in one place.
    var pendingMeetingRecording: Bool = false

    /// The mirror-image one-shot: set by the menu bar's "Stop recording"
    /// entry, drained by the root view, which owns the live `MeetingSession`.
    /// Same race-dodge as `pendingMeetingRecording` — the status item is
    /// usually clicked with the window buried or closed.
    var pendingStopRecording: Bool = false

    /// Ask the live recording to stop from outside the window (the menu-bar
    /// item). Fronting the window is the caller's job.
    func requestStopRecording() {
        pendingStopRecording = true
    }

    /// When a meeting is actively recording, the moment it started — mirrored
    /// from the live `MeetingSession` so the menu-bar item can show a recording
    /// indicator even when the window is closed or backgrounded. nil when no
    /// meeting is recording.
    var meetingRecordingStartedAt: Date?
    var isRecordingMeeting: Bool { meetingRecordingStartedAt != nil }

    /// The live meeting's coach engine, mirrored here (like
    /// `meetingRecordingStartedAt`) so the notch island can show the coach
    /// strip with the window closed. Set by `MeetingSession` when recording
    /// starts, cleared on every teardown path. nil when no meeting is recording
    /// or the coach is disabled.
    var activeCoachEngine: MeetingCoachEngine?

    /// True while the meetings window is the key window. Set by the root view
    /// from its `controlActiveState`; drives the "⌘⌥A to ask" affordance on the
    /// notes view, which only makes sense when the window is focused.
    var meetingsWindowIsKey: Bool = false

    /// The assistant controller for the meeting currently shown in the detail
    /// pane, registered by the notes view while it's on screen. Weak +
    /// observation-ignored: it's a routing target for the Assistant menu
    /// command, never rendered from here.
    @ObservationIgnored weak var meetingAssistant: MeetingAssistantController?

    private init() {
        // Teach the shared `SyncedStorage` where this app's synced folder is.
        // It can't read this class directly — the file is compiled into
        // Dictator and the iOS app too — so it asks through this closure.
        // Registered here rather than in `bootstrap()` because anything that
        // reaches `SyncedStorage.directory` has necessarily gone through
        // `MeetingsAppState.shared` first.
        SyncedStorage.customDirectoryProvider = { MeetingsAppState.shared.settings.syncedDirectoryPath }
        self.settings = MeetingsSettings.load()
    }

    private var storagePrepared = false

    /// Point meeting storage at the synced folder and reconcile what's on
    /// disk. Idempotent, and deliberately separate from `bootstrap()`: in a
    /// SwiftUI-lifecycle app the main window can appear — and
    /// `MeetingsStore` scan — before the AppDelegate's
    /// `applicationDidFinishLaunching` runs, so `DictatorMeetingsApp.init`
    /// calls this first. Before this ran, the first scan read the per-Mac
    /// audio folder (no meta.json files) and the sidebar came up empty.
    func prepareStorage() {
        guard !storagePrepared else { return }
        storagePrepared = true
        // Meeting notes + transcripts live in the synced folder so a meeting
        // recorded on one Mac can be read on another; the large audio tracks
        // stay per-Mac in Application Support. Point MeetingStorage at the
        // synced folder, then reconcile on-disk meetings to that split.
        MeetingStorage.syncedBaseURL = SyncedStorage.directory
        MeetingStorage.migrateToSplitStorage()
        // Recover any recording a crash cut short before its meta.json was
        // written: synthesise the meta so it reappears as a `.captured` meeting
        // (with its mirrored first-pass notes) the user can finish, and clear
        // the stale live-mirror files.
        MeetingRecovery.recoverInterrupted(settings: settings)
        // Backfill notes.md / transcript.md for meetings recorded before them.
        MeetingStorage.backfillDerivedMarkdown()
    }

    func bootstrap() {
        MicLog.installUncaughtExceptionLogger()

        // Bound MLX's GPU buffer cache, same figure and same reasoning as
        // Dictator: the default `cacheLimit` mirrors `memoryLimit`, so on a
        // 32 GB+ Mac the buffer pool grows to many gigabytes across repeated
        // inferences. A long meeting runs the local model dozens of times.
        // 512 MB is comfortably larger than any single inference buffer the
        // models we ship allocate, so the cache-hit rate stays high but the
        // pool can't run away.
        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)

        prepareStorage()

        AudioDeviceManager.shared.bootstrap()

        // Reap aggregate devices left behind by a crashed recording. Dictator
        // deliberately skips this at launch — destroying an aggregate briefly
        // interrupts whatever audio is playing, which is not a thing a
        // background menu-bar app should do on login. Here it's defensible:
        // this app is launched deliberately, the leaked aggregates are its own
        // litter, and a user opening the meeting recorder is not usually
        // mid-track. Off the main thread so the window still comes up instantly.
        Task.detached(priority: .utility) {
            MeetingAudioRecorder.sweepStaleAggregates()
        }

        // Build the provider instances for the configured slots so the first
        // recording doesn't pay for it, and so the Providers tab has statuses
        // to render.
        ProviderRegistry.shared.refresh()

        preloadModels()
    }

    /// Warm the models already on disk so the first recording doesn't pay for
    /// a load. Only models that are downloaded are touched — we never kick off
    /// a multi-gigabyte download at launch — and the LLM is deliberately NOT
    /// preloaded: the default provider borrows Dictator's copy, and loading a
    /// second one here would be exactly the duplication the socket exists to
    /// avoid. The local provider loads on first use if it's ever selected.
    func preloadModels() {
        let manager = ModelManager.shared
        manager.refreshCachedStates()
        let parakeetID = settings.parakeetModelID
        if manager.parakeetStates[parakeetID] == .ready {
            Task { try? await ParakeetServiceHolder.shared.ensureLoaded(modelID: parakeetID) }
        }
    }

    /// The one place settings are written. Also re-points meeting storage at
    /// the (possibly just-changed) synced folder and reconciles the provider
    /// cache, so a Settings edit takes effect on the next pass with nothing
    /// else to remember.
    ///
    /// Existing meetings aren't auto-moved on a folder change — only the
    /// initial Application Support migration moves them — so a relocate leaves
    /// prior meetings where they were.
    func save() {
        settings.persist()
        MeetingStorage.syncedBaseURL = SyncedStorage.directory
        ProviderRegistry.shared.refresh()
    }
}

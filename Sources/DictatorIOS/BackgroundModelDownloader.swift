import Foundation
import UIKit

/// iOS-only background downloader for Parakeet model files.
///
/// The default FluidAudio `AsrModels.download(to:)` path runs over a foreground
/// `URLSession`, which iOS suspends the moment the user switches apps or locks
/// the phone. On a slow connection that turns a one-time 460 MB onboarding
/// download into a Sisyphean exercise: TestFlight users were getting stuck on
/// step 2 because any glance at another app reset the transfer.
///
/// This class replaces that path on iOS with a `URLSessionConfiguration.background`
/// session that keeps downloading after suspension, and persists per-file resume
/// data so a flaky connection — or a relaunch — picks up where it left off
/// instead of starting the whole 460 MB over.
///
/// ## Why we own the file list, not FluidAudio
///
/// FluidAudio's downloader walks the HuggingFace `tree/main` API, picks the
/// files that match its required-models pattern, and downloads each via the
/// default URLSession. We need byte-level progress + resume on each file, so we
/// run the same listing pass ourselves (a small one-shot JSON fetch — fast
/// even on cellular) and then enqueue each file as a `URLSessionDownloadTask`
/// on a single shared background session. The on-disk layout matches what
/// FluidAudio expects, so once the downloader reports `.completed`,
/// `AsrModels.modelsExist(at:)` returns true and the regular load path takes
/// over without a second network round trip.
///
/// ## Threading
///
/// The class is `@MainActor` for state observation, but the URLSession
/// delegate callbacks land off the main thread on the background session's
/// internal queue. We funnel them back through `Task { @MainActor in … }`
/// before mutating any state. The delegate object itself is a separate
/// `Sendable` class so the session can hold it across actor boundaries
/// without Swift 6 complaining.
///
/// ## Persistence layout
///
/// Everything we need to survive a relaunch lives under
/// `~/Library/Application Support/Dictator/Downloads/parakeet/<modelID>/`:
/// - `manifest.json` — the list of files we plan to / are downloading, with
///   sizes, completion flags, and absolute remote URLs.
/// - `<filePath>.resume` — `URLSessionDownloadTask` resume data for any file
///   that was in-flight when we last paused / hit an error. Cleared when the
///   file completes successfully.
@MainActor
@Observable
final class BackgroundModelDownloader: NSObject {

    // MARK: - Public observable state

    /// Detailed status of the active (or last) download. Drives the UI's
    /// progress bar + byte readout + rate. The legacy `.downloading(progress:
    /// Double)` shape lives on the view model side, which derives it from this
    /// richer struct so we don't duplicate every consumer change.
    private(set) var state: State = .idle

    /// Snapshot of an in-progress download for the UI. Updated on every
    /// `didWriteData` callback (which lands on the session queue and we
    /// dispatch to main, throttled).
    struct Progress: Equatable, Sendable {
        var bytesDownloaded: Int64
        var bytesTotal: Int64
        /// Smoothed bytes-per-second across the most recent ~5 seconds of
        /// samples. Zero until we've seen at least two callbacks.
        var bytesPerSecond: Double
        /// Index into the file list of the currently-downloading file.
        var currentFileIndex: Int
        /// Total file count for the model.
        var totalFiles: Int

        var fraction: Double {
            guard bytesTotal > 0 else { return 0 }
            return min(1.0, max(0.0, Double(bytesDownloaded) / Double(bytesTotal)))
        }

        var fractionAsLegacyDouble: Double { fraction }

        static let zero = Progress(
            bytesDownloaded: 0, bytesTotal: 0, bytesPerSecond: 0,
            currentFileIndex: 0, totalFiles: 0
        )
    }

    enum State: Equatable, Sendable {
        case idle
        /// Listing files from HuggingFace. Brief — a single small JSON
        /// request. Surfaced as a state so the UI can show "Preparing
        /// download…" instead of a stuck 0%.
        case listing
        case downloading(Progress)
        /// Download is paused (either by the user or because we hit an
        /// error that we'd like the user to retry). Resume data is on disk.
        case paused(Progress, reason: String?)
        case completed
        case failed(String)
    }

    // MARK: - Singleton

    /// One shared instance per app process. iOS keys background URLSessions
    /// by identifier, so creating a new session with the same identifier
    /// after the app relaunches reattaches us to any in-flight transfers
    /// that ran while we were suspended. The delegate calls then replay.
    @MainActor
    static let shared = BackgroundModelDownloader()

    /// Background session identifier. iOS reserves this string across app
    /// launches — using the bundle ID as a prefix makes it obvious which
    /// app owns the transfers if anyone inspects them.
    static let sessionIdentifier = "net.robgough.DictatorIOS.modelDownload"

    // MARK: - Internal

    /// Background URLSession. Constructed lazily on first use to avoid the
    /// non-trivial setup cost on launches that don't touch downloads.
    /// `@ObservationIgnored` because `@Observable`'s init-accessor synthesis
    /// can't see through `lazy` (the underlying `_session` storage isn't
    /// a plain stored property) and tracking a URLSession adds nothing
    /// useful anyway.
    @ObservationIgnored
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Allow OS to do its smart thing with timing. We set
        // `isDiscretionary = false` so the download starts as soon as the
        // user taps Download even if the device isn't on power; cellular
        // is still honored via `allowsCellularAccess`.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        // 30 minutes per resource — large files on slow connections need
        // headroom. The default 7 days is fine for waitsForConnectivity,
        // we want the per-request budget high too in case a single file is
        // big and the connection is patchy.
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    /// Sendable delegate proxy — URLSession holds it across actor
    /// boundaries, so it can't be `@MainActor`. It re-dispatches every
    /// callback to the main actor through a weak reference back to us.
    /// `@ObservationIgnored` for the same reason as `session` above:
    /// `lazy` plus `@Observable` macro synthesis don't mix.
    @ObservationIgnored
    private lazy var delegate: SessionDelegate = SessionDelegate(owner: self)

    /// The active manifest, if any. `nil` when state is `.idle` /
    /// `.completed` / `.failed` and we haven't reloaded an in-flight one
    /// from disk. Mutated only on the main actor.
    @ObservationIgnored private var manifest: Manifest?

    /// Closure the AppDelegate hands us so we can call it once the system
    /// has finished delivering all background URLSession events. iOS holds
    /// the app awake until we invoke this; calling it too early truncates
    /// the delivery, calling it too late triggers a watchdog kill.
    @ObservationIgnored private var systemCompletionHandler: (@Sendable @MainActor () -> Void)?

    /// Recent (timestamp, bytesDownloaded) samples for the rate calculation.
    /// Cap at ~20 entries (~5 seconds at 4 Hz throttled updates).
    @ObservationIgnored private var rateSamples: [(at: Date, bytes: Int64)] = []

    /// Last `didWriteData` dispatch — throttles the @MainActor hop so a
    /// rapid stream of byte callbacks doesn't spam the UI.
    @ObservationIgnored private var lastProgressDispatch: Date = .distantPast

    /// Bytes already completed by all earlier files in the manifest.
    /// Added to the active file's `bytesWritten` to compute the running
    /// total in `Progress`.
    @ObservationIgnored private var bytesCompletedFromPriorFiles: Int64 = 0

    /// Cached total size from the manifest so progress callbacks don't
    /// have to walk it on every tick.
    @ObservationIgnored private var totalBytesExpected: Int64 = 0

    override private init() {
        super.init()
    }

    // MARK: - Public API

    /// Reattach to any in-flight download from a previous launch. Call
    /// this on app launch; it forces the background session to be created
    /// (which makes iOS replay any pending delegate events for transfers
    /// that completed while we were suspended) and reloads the manifest
    /// from disk so the UI reflects the right state.
    func bootstrapOnLaunch() {
        _ = session  // touch the lazy property so the session is registered
        if let restored = Self.loadManifest() {
            manifest = restored
            totalBytesExpected = restored.totalBytes
            bytesCompletedFromPriorFiles = restored.bytesCompletedFromCompletedFiles
            if restored.isComplete {
                state = .completed
            } else {
                let progress = Progress(
                    bytesDownloaded: bytesCompletedFromPriorFiles,
                    bytesTotal: totalBytesExpected,
                    bytesPerSecond: 0,
                    currentFileIndex: restored.currentFileIndex,
                    totalFiles: restored.files.count
                )
                state = .paused(progress, reason: nil)
            }
        }
    }

    /// True when we have files on disk for `modelID` matching the layout
    /// FluidAudio expects. Cheap synchronous probe — used by the view
    /// model to short-circuit the download CTA.
    static func modelsExist(modelID: String) -> Bool {
        ParakeetService.modelsExist(id: modelID)
    }

    /// Start (or resume) a download for `modelID`. Idempotent: calling
    /// twice in a row is a no-op once the first call has the manifest
    /// loaded and at least one task scheduled.
    func startDownload(modelID: String) async {
        if case .downloading = state { return }
        if case .listing = state { return }

        // If the model is already on disk (e.g. the user backgrounded
        // long enough for the previous run to finish and we're being asked
        // again on the next foreground), just report completion.
        if Self.modelsExist(modelID: modelID) {
            state = .completed
            try? Self.clearManifest()
            return
        }

        // Try to resume from a previously-loaded manifest if it matches.
        if let existing = manifest, existing.modelID == modelID, !existing.files.isEmpty {
            kickNextFile()
            return
        }

        // Build a fresh manifest. The listing pass is foreground because
        // it's a small JSON fetch that finishes in milliseconds even on
        // bad networks; we want the background session for the heavy file
        // transfers, not for metadata.
        state = .listing
        do {
            let m = try await buildManifest(modelID: modelID)
            manifest = m
            totalBytesExpected = m.totalBytes
            bytesCompletedFromPriorFiles = m.bytesCompletedFromCompletedFiles
            try Self.saveManifest(m)
            // Skip files already on disk (e.g. partial completion from
            // a previous attempt that finished some files before the
            // app was killed). buildManifest already marks them complete,
            // so kickNextFile picks up the right one.
            kickNextFile()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// User-initiated pause. Cancels the active task while preserving
    /// resume data so the next `startDownload` continues mid-file.
    func pause() async {
        guard let m = manifest else { return }
        guard m.currentFileIndex < m.files.count else { return }

        // Find the active task and cancel it with resume data.
        let tasks = await session.allTasks
        for task in tasks where task is URLSessionDownloadTask {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                (task as! URLSessionDownloadTask).cancel(byProducingResumeData: { data in
                    Task { @MainActor in
                        if let data = data {
                            self.persistResumeData(data, forFileIndex: m.currentFileIndex)
                        }
                        continuation.resume()
                    }
                })
            }
        }
        let progress = Progress(
            bytesDownloaded: bytesCompletedFromPriorFiles,
            bytesTotal: totalBytesExpected,
            bytesPerSecond: 0,
            currentFileIndex: m.currentFileIndex,
            totalFiles: m.files.count
        )
        state = .paused(progress, reason: nil)
    }

    /// User-initiated cancel — drops resume data and the manifest. Next
    /// `startDownload` starts from scratch.
    func cancel() async {
        let tasks = await session.allTasks
        for task in tasks {
            task.cancel()
        }
        try? Self.clearManifest()
        try? Self.clearAllResumeData()
        manifest = nil
        totalBytesExpected = 0
        bytesCompletedFromPriorFiles = 0
        rateSamples.removeAll()
        state = .idle
    }

    /// AppDelegate hook. The system invokes our delegate's
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` after replaying
    /// all pending events; that's the point at which we call this stored
    /// completion handler so iOS knows it's safe to put us back to sleep
    /// or update our snapshot.
    func setSystemBackgroundCompletionHandler(_ handler: @escaping @Sendable @MainActor () -> Void) {
        systemCompletionHandler = handler
        _ = session  // force lazy session creation so events can replay
    }

    // MARK: - Internals

    private func kickNextFile() {
        guard var m = manifest else { return }
        // Skip any files already on disk from a partial run.
        while m.currentFileIndex < m.files.count {
            let entry = m.files[m.currentFileIndex]
            if FileManager.default.fileExists(atPath: entry.destinationPath) {
                m.files[m.currentFileIndex].completed = true
                m.currentFileIndex += 1
                continue
            }
            break
        }
        manifest = m
        try? Self.saveManifest(m)
        bytesCompletedFromPriorFiles = m.bytesCompletedFromCompletedFiles

        if m.currentFileIndex >= m.files.count {
            // Verify the on-disk layout matches what FluidAudio expects
            // before declaring completion — a partial file could have been
            // moved into place but missing siblings.
            if Self.modelsExist(modelID: m.modelID) {
                state = .completed
                try? Self.clearManifest()
                try? Self.clearAllResumeData()
            } else {
                state = .failed("Downloaded all listed files but the model layout looks incomplete. Tap Try again to refetch.")
            }
            return
        }

        let entry = m.files[m.currentFileIndex]
        let progress = Progress(
            bytesDownloaded: bytesCompletedFromPriorFiles,
            bytesTotal: totalBytesExpected,
            bytesPerSecond: 0,
            currentFileIndex: m.currentFileIndex,
            totalFiles: m.files.count
        )
        state = .downloading(progress)

        let task: URLSessionDownloadTask
        if let resume = Self.loadResumeData(forFileIndex: m.currentFileIndex), !resume.isEmpty {
            task = session.downloadTask(withResumeData: resume)
        } else {
            guard let url = URL(string: entry.remoteURL) else {
                state = .failed("Invalid remote URL for \(entry.localPath)")
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            task = session.downloadTask(with: request)
        }
        // taskDescription doubles as the file index so the delegate can
        // map its callbacks back to the manifest without us holding the
        // task -> entry mapping in memory across relaunches.
        task.taskDescription = "\(m.currentFileIndex)"
        task.resume()
    }

    /// Called by the delegate once a download finishes successfully.
    /// `tempURL` is the OS-temporary file the task wrote to; we move it
    /// into its final destination, mark the manifest entry complete,
    /// drop any resume data for it, and kick the next file.
    fileprivate func handleFileFinished(fileIndex: Int, tempURL: URL) {
        guard var m = manifest, fileIndex < m.files.count else { return }
        let entry = m.files[fileIndex]
        let destURL = URL(fileURLWithPath: entry.destinationPath)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: destURL.path) {
                try? fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: tempURL, to: destURL)
        } catch {
            state = .failed("Couldn't save \(destURL.lastPathComponent): \(error.localizedDescription)")
            return
        }
        m.files[fileIndex].completed = true
        // Advance the current index past completed files. Files may
        // complete out of order in theory (the background session can run
        // tasks in parallel after a relaunch even though we serialize new
        // ones), so walk forward.
        if fileIndex == m.currentFileIndex {
            m.currentFileIndex += 1
            while m.currentFileIndex < m.files.count, m.files[m.currentFileIndex].completed {
                m.currentFileIndex += 1
            }
        }
        manifest = m
        bytesCompletedFromPriorFiles = m.bytesCompletedFromCompletedFiles
        try? Self.saveManifest(m)
        try? Self.clearResumeData(forFileIndex: fileIndex)
        kickNextFile()
    }

    /// Called by the delegate on byte-level progress. We throttle to
    /// ~10 Hz on the main actor to keep the UI smooth without taxing
    /// the run loop.
    fileprivate func handleProgress(fileIndex: Int, bytesWritten: Int64, totalBytesExpectedForFile: Int64) {
        let now = Date()
        if now.timeIntervalSince(lastProgressDispatch) < 0.1 { return }
        lastProgressDispatch = now

        let totalDownloaded = bytesCompletedFromPriorFiles + bytesWritten
        // Sliding-window rate samples. Drop anything older than 5s.
        rateSamples.append((at: now, bytes: totalDownloaded))
        let cutoff = now.addingTimeInterval(-5)
        while let first = rateSamples.first, first.at < cutoff {
            rateSamples.removeFirst()
        }
        let bytesPerSecond: Double
        if let first = rateSamples.first, let last = rateSamples.last,
           last.at > first.at {
            let dt = last.at.timeIntervalSince(first.at)
            let db = Double(last.bytes - first.bytes)
            bytesPerSecond = max(0, db / dt)
        } else {
            bytesPerSecond = 0
        }

        let totalForProgress: Int64
        if totalBytesExpected > 0 {
            totalForProgress = totalBytesExpected
        } else if totalBytesExpectedForFile > 0 {
            // Fallback when the manifest had no size info — at least show
            // the current file's progress so the bar isn't pinned at zero.
            totalForProgress = totalBytesExpectedForFile + bytesCompletedFromPriorFiles
        } else {
            totalForProgress = 0
        }

        let progress = Progress(
            bytesDownloaded: totalDownloaded,
            bytesTotal: totalForProgress,
            bytesPerSecond: bytesPerSecond,
            currentFileIndex: fileIndex,
            totalFiles: manifest?.files.count ?? 0
        )
        state = .downloading(progress)
    }

    /// Called by the delegate when a task fails (network drop, server
    /// error, etc.). We hold onto the resume data so the next
    /// `startDownload` picks up where we left off.
    fileprivate func handleTaskError(fileIndex: Int, resumeData: Data?, error: Error) {
        if let resumeData = resumeData {
            persistResumeData(resumeData, forFileIndex: fileIndex)
        }
        let progress = Progress(
            bytesDownloaded: bytesCompletedFromPriorFiles,
            bytesTotal: totalBytesExpected,
            bytesPerSecond: 0,
            currentFileIndex: fileIndex,
            totalFiles: manifest?.files.count ?? 0
        )
        // Cancellations (user-initiated pause / cancel) come through here
        // too; we surface them as paused with no error message so the UI
        // can show "Resume" rather than a red error banner.
        let nsError = error as NSError
        let userCancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        if userCancelled {
            state = .paused(progress, reason: nil)
        } else {
            state = .failed(error.localizedDescription)
        }
    }

    /// Called by the delegate when the OS has finished delivering all
    /// background-session events to us. Invoke the stored system handler
    /// so iOS knows it's safe to put us back to sleep / update the
    /// snapshot.
    fileprivate func handleEventsDelivered() {
        let handler = systemCompletionHandler
        systemCompletionHandler = nil
        handler?()
    }

    // MARK: - Manifest discovery

    /// Walk the HuggingFace tree API for the given Parakeet model and
    /// produce a flat list of files to download. Mirrors the patterns
    /// FluidAudio uses internally so the resulting layout is identical.
    private func buildManifest(modelID: String) async throws -> Manifest {
        guard let descriptor = ParakeetRepoDescriptor.forModelID(modelID) else {
            throw DownloaderError.unknownModel(modelID)
        }
        let listing = try await listAllFiles(remotePath: descriptor.remotePath)

        // Filter to only the directories matching the required model files
        // (plus root-level metadata like the vocab JSON), matching what
        // FluidAudio's downloader does. The patterns end with `/` so we
        // include all files inside each `<modelname>.mlmodelc/` dir.
        let patterns = descriptor.requiredModelDirs.map { "\($0)/" }
        let filtered = listing.filter { item in
            if item.size <= 0 { return false }
            if patterns.contains(where: { item.path.hasPrefix($0) }) { return true }
            // Root-level json / txt are usually metadata (vocab, config).
            // Be generous here so we don't miss the vocab file FluidAudio
            // needs at load time.
            if !item.path.contains("/"), item.path.hasSuffix(".json") || item.path.hasSuffix(".txt") {
                return true
            }
            return false
        }

        let repoDir = ParakeetService.storageURL(forID: modelID)
            .deletingLastPathComponent()
            .appendingPathComponent(descriptor.folderName, isDirectory: true)

        let entries: [FileEntry] = filtered.map { item in
            let remote = "\(ParakeetRepoDescriptor.baseURL)/\(descriptor.remotePath)/resolve/main/\(item.path.urlPathEncoded)"
            let dest = repoDir.appendingPathComponent(item.path).path
            // Mark already-present files complete so we don't redownload.
            let alreadyOnDisk = FileManager.default.fileExists(atPath: dest)
            return FileEntry(
                remoteURL: remote,
                localPath: item.path,
                destinationPath: dest,
                size: Int64(item.size),
                completed: alreadyOnDisk
            )
        }

        return Manifest(
            modelID: modelID,
            repoFolderName: descriptor.folderName,
            files: entries,
            currentFileIndex: entries.firstIndex(where: { !$0.completed }) ?? entries.count
        )
    }

    private func listAllFiles(remotePath: String) async throws -> [(path: String, size: Int)] {
        // Foreground URLSession just for this small JSON walk — the
        // background session is only worthwhile for the multi-MB files.
        var results: [(path: String, size: Int)] = []
        try await listDirectory(remotePath: remotePath, subPath: "", into: &results)
        return results
    }

    private func listDirectory(remotePath: String, subPath: String, into results: inout [(path: String, size: Int)]) async throws {
        let apiPath = subPath.isEmpty ? "tree/main" : "tree/main/\(subPath)"
        let urlString = "\(ParakeetRepoDescriptor.baseURL)/api/models/\(remotePath)/\(apiPath)"
        guard let url = URL(string: urlString) else {
            throw DownloaderError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloaderError.listingFailed("Non-HTTP response from \(urlString)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloaderError.listingFailed("HTTP \(http.statusCode) listing \(subPath.isEmpty ? "root" : subPath)")
        }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloaderError.listingFailed("Unexpected listing payload for \(subPath)")
        }
        for item in items {
            guard let itemPath = item["path"] as? String,
                  let itemType = item["type"] as? String else { continue }
            if itemType == "directory" {
                try await listDirectory(remotePath: remotePath, subPath: itemPath, into: &results)
            } else if itemType == "file" {
                let size = item["size"] as? Int ?? -1
                results.append((path: itemPath, size: size))
            }
        }
    }

    // MARK: - Manifest persistence

    private struct FileEntry: Codable, Equatable, Sendable {
        var remoteURL: String
        /// Repo-relative path (e.g. "Preprocessor.mlmodelc/coremldata.bin").
        var localPath: String
        /// Absolute path on disk where the file should land.
        var destinationPath: String
        var size: Int64
        var completed: Bool
    }

    private struct Manifest: Codable, Equatable, Sendable {
        var modelID: String
        var repoFolderName: String
        var files: [FileEntry]
        var currentFileIndex: Int

        var totalBytes: Int64 {
            files.reduce(0) { $0 + max(0, $1.size) }
        }

        var bytesCompletedFromCompletedFiles: Int64 {
            files.reduce(0) { $0 + ($1.completed ? max(0, $1.size) : 0) }
        }

        var isComplete: Bool {
            files.allSatisfy { $0.completed }
        }
    }

    private static func downloadsRoot() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Dictator/Downloads/parakeet", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let manifestFilename = "manifest.json"

    private static func saveManifest(_ manifest: Manifest) throws {
        let url = downloadsRoot().appendingPathComponent(manifestFilename)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private static func loadManifest() -> Manifest? {
        let url = downloadsRoot().appendingPathComponent(manifestFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func clearManifest() throws {
        let url = downloadsRoot().appendingPathComponent(manifestFilename)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Resume data persistence

    private func persistResumeData(_ data: Data, forFileIndex index: Int) {
        let url = Self.downloadsRoot().appendingPathComponent("file_\(index).resume")
        try? data.write(to: url, options: .atomic)
    }

    private static func loadResumeData(forFileIndex index: Int) -> Data? {
        let url = downloadsRoot().appendingPathComponent("file_\(index).resume")
        return try? Data(contentsOf: url)
    }

    private static func clearResumeData(forFileIndex index: Int) throws {
        let url = downloadsRoot().appendingPathComponent("file_\(index).resume")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func clearAllResumeData() throws {
        let fm = FileManager.default
        let dir = downloadsRoot()
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in entries where name.hasSuffix(".resume") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    enum DownloaderError: LocalizedError {
        case unknownModel(String)
        case invalidURL(String)
        case listingFailed(String)

        var errorDescription: String? {
            switch self {
            case .unknownModel(let id): return "Unknown model: \(id)"
            case .invalidURL(let s): return "Invalid URL: \(s)"
            case .listingFailed(let s): return "Couldn't list files: \(s)"
            }
        }
    }
}

// MARK: - Repository descriptor

/// Minimal description of a HuggingFace repo for one Parakeet model
/// variant. Kept local instead of leaning on FluidAudio's types so the
/// background downloader doesn't have to import FluidAudio modules (we
/// build URLs by hand, then hand the resulting on-disk layout to
/// FluidAudio's loader at the end).
private struct ParakeetRepoDescriptor {
    let remotePath: String
    /// Local subdirectory name FluidAudio expects under
    /// `parakeetRoot()`. Must match `Repo.folderName` for the matching
    /// version exactly, otherwise FluidAudio won't find the model on
    /// load.
    let folderName: String
    /// Top-level directories the loader needs present. We use these as
    /// the prefix patterns to filter the HuggingFace tree listing.
    let requiredModelDirs: [String]

    static let baseURL = "https://huggingface.co"

    static func forModelID(_ id: String) -> ParakeetRepoDescriptor? {
        switch id {
        case "parakeet-tdt-0.6b-v3":
            // v3 layout: preprocessor + int8 encoder + decoder + v3 joint
            // (top-K) + vocab. Encoder precision defaults to int8 in
            // ParakeetService.swift; we match that here.
            return ParakeetRepoDescriptor(
                remotePath: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                folderName: "parakeet-tdt-0.6b-v3",
                requiredModelDirs: [
                    "Preprocessor.mlmodelc",
                    "EncoderInt8.mlmodelc",
                    "Decoder.mlmodelc",
                    "JointDecisionv3.mlmodelc",
                ]
            )
        case "parakeet-tdt-0.6b-v2":
            return ParakeetRepoDescriptor(
                remotePath: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
                folderName: "parakeet-tdt-0.6b-v2",
                requiredModelDirs: [
                    "Preprocessor.mlmodelc",
                    "Encoder.mlmodelc",
                    "Decoder.mlmodelc",
                    "JointDecision.mlmodelc",
                ]
            )
        default:
            return nil
        }
    }
}

// MARK: - URL path encoding helper

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}

// MARK: - Session delegate

/// URLSession delegate proxy. Held strongly by the background session, so
/// it can't be `@MainActor`; it bounces every callback back to the main
/// actor via the weak `owner` reference.
private final class SessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Weak so a teardown of the owner doesn't leak the session.
    /// `nonisolated(unsafe)` because URLSession delegate methods aren't
    /// MainActor-isolated; we read the property without crossing actors
    /// and immediately hop to main inside the Task.
    nonisolated(unsafe) weak var owner: BackgroundModelDownloader?

    init(owner: BackgroundModelDownloader) {
        self.owner = owner
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file at `location` is deleted by the OS shortly after
        // this method returns, so we have to copy it to a holding spot
        // BEFORE bouncing to the main actor. Otherwise the @MainActor hop
        // can lose the race and the file vanishes mid-move.
        let fileIndex = Int(downloadTask.taskDescription ?? "") ?? -1
        let fm = FileManager.default
        let holding = fm.temporaryDirectory.appendingPathComponent("dictator-dl-\(UUID().uuidString)")
        do {
            if fm.fileExists(atPath: holding.path) {
                try fm.removeItem(at: holding)
            }
            try fm.moveItem(at: location, to: holding)
        } catch {
            // If we couldn't even stage the file, surface as a task error
            // so the downloader retries.
            Task { @MainActor [weak self] in
                self?.owner?.handleTaskError(fileIndex: fileIndex, resumeData: nil, error: error)
            }
            return
        }
        Task { @MainActor [weak self] in
            self?.owner?.handleFileFinished(fileIndex: fileIndex, tempURL: holding)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fileIndex = Int(downloadTask.taskDescription ?? "") ?? -1
        Task { @MainActor [weak self] in
            self?.owner?.handleProgress(
                fileIndex: fileIndex,
                bytesWritten: totalBytesWritten,
                totalBytesExpectedForFile: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }  // success is handled by didFinishDownloadingTo
        let fileIndex = Int(task.taskDescription ?? "") ?? -1
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor [weak self] in
            self?.owner?.handleTaskError(fileIndex: fileIndex, resumeData: resumeData, error: error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.owner?.handleEventsDelivered()
        }
    }
}

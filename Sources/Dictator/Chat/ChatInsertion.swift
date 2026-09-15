import AppKit
import Observation

/// Sends a chat reply back to the app the user came from.
///
/// Assistant Mode has always been able to put text at your cursor, because the
/// hotkey fires while the target app is still in front. The chat window is the
/// opposite: by the time there's a reply worth inserting, Dictator itself is
/// frontmost and the cursor the user means is in an app that lost focus some
/// minutes ago. So the target has to be remembered rather than discovered — and
/// then handed focus back before anything is pasted.
///
/// This is the half of the merge that doesn't exist anywhere else: a
/// conversation with tools and files that can still finish by typing into the
/// document you were working on.
@MainActor
@Observable
final class ChatInsertion {
    static let shared = ChatInsertion()

    /// The last app that wasn't us. Updated as the user moves around, so it's
    /// current at the moment they ask, not at the moment the window opened.
    private(set) var target: NSRunningApplication?

    /// Result of the last attempt, shown next to the button that caused it.
    /// Transient: it's feedback, not history.
    private(set) var lastOutcome: Outcome?

    enum Outcome: Equatable {
        case inserted(app: String)
        case copiedOnly(reason: String)

        var isFailure: Bool { if case .copiedOnly = self { return true }; return false }

        var message: String {
            switch self {
            case .inserted(let app): "Inserted into \(app)"
            case .copiedOnly(let reason): reason
            }
        }
    }

    /// A name for the button, so it can say where the text is going rather than
    /// just "Insert". nil when there's nowhere to send it.
    var targetName: String? {
        guard let target, !target.isTerminated else { return nil }
        return target.localizedName
    }

    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private let injector = TextInjector()
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    private init() {
        // `didActivateApplicationNotification` rather than reading
        // `frontmostApplication` when asked: by then we are the frontmost
        // application, and the one we want is whatever was there before.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            MainActor.assumeIsolated { self?.target = app }
        }
    }

    /// Records the frontmost app right now, if it isn't us.
    ///
    /// The observer covers everything that happens while Dictator is running,
    /// but not the app that was in front when it launched — and on a Mac where
    /// Dictator starts at login, that first app is exactly the one someone is
    /// working in. Called just before the chat window takes focus.
    func rememberFrontmost() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        target = front
    }

    /// Hands focus back to the remembered app and pastes at its cursor.
    ///
    /// Everything is on the clipboard before focus moves, so every failure path
    /// below still leaves the user one ⌘V away from what they asked for. That
    /// matters more here than in Assistant Mode: the user has deliberately
    /// switched apps to get this text, and "it didn't work" must not also mean
    /// "and now you have to come back and copy it".
    func insert(_ text: String) async {
        clearTask?.cancel()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        guard let target, !target.isTerminated else {
            return finish(.copiedOnly(reason: "No app to insert into — copied instead"))
        }
        let name = target.localizedName ?? "the other app"

        guard TextInjector.hasAccessibilityPermission() else {
            TextInjector.requestAccessibilityPrompt()
            return finish(.copiedOnly(
                reason: "Accessibility permission needed to paste — copied instead"))
        }

        guard target.activate() else {
            return finish(.copiedOnly(reason: "Couldn't bring \(name) forward — copied instead"))
        }

        // Activation is a request, not a fact: the paste has to wait for the
        // app to actually own the focus, or ⌘V lands back in the chat window.
        // Polling beats a fixed sleep — a small app is forward in a frame or
        // two and shouldn't be made to wait for the slowest case.
        guard await waitUntilFrontmost(target) else {
            return finish(.copiedOnly(reason: "\(name) didn't come forward — copied instead"))
        }

        // The same guard Assistant Mode uses. Without it the paste can land in
        // a URL bar or a search field the user wasn't typing in.
        guard TextInjector.focusedElementIsEditableText() else {
            return finish(.copiedOnly(
                reason: "No text field focused in \(name) — copied instead"))
        }

        switch injector.deliver(text: text, selectAfterPaste: true) {
        case .pasted:
            finish(.inserted(app: name))
        case .copiedOnly(let reason):
            finish(.copiedOnly(reason: reason))
        }
    }

    private static let activationTimeout = Duration.milliseconds(1200)

    private func waitUntilFrontmost(_ app: NSRunningApplication) async -> Bool {
        let deadline = ContinuousClock.now + Self.activationTimeout
        while ContinuousClock.now < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == app.processIdentifier { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return false
    }

    private func finish(_ outcome: Outcome) {
        lastOutcome = outcome
        clearTask = Task { [weak self] in
            // Long enough to read a sentence; a failure gets longer because it
            // has something to say.
            try? await Task.sleep(for: .seconds(outcome.isFailure ? 6 : 3))
            guard !Task.isCancelled else { return }
            self?.lastOutcome = nil
        }
    }
}

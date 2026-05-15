import AppKit

/// NSServices provider for the right-click \u{2192} Services \u{2192}
/// "Learn Word in Dictator…" menu entry. The matching NSServices
/// declaration lives in `project.yml` and is generated into the bundled
/// Info.plist; this class is the receiver bound to `NSApp.servicesProvider`
/// in `AppDelegate.applicationDidFinishLaunching`.
///
/// macOS's pasteboard server (`pbs`) caches the services-menu contents per
/// signed app. After a fresh install the entry doesn't appear until pbs
/// rescans — `NSUpdateDynamicServices()` is called at launch to nudge it.
/// During development, if the entry still doesn't show up after a build,
/// run `/System/Library/CoreServices/pbs -update` or log out.
final class LearnWordProvider: NSObject {
    /// The selector name here must match `NSMessage` in the Info.plist
    /// NSServices entry. macOS appends `:userData:error:` automatically,
    /// so the registered name is just `learnWord`.
    @objc
    func learnWord(_ pboard: NSPasteboard,
                   userData: String?,
                   error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let text = pboard.string(forType: .string) ?? ""
        // Services invocations come in on the main thread for AppKit
        // apps, but the static analyser can't prove that — hop onto
        // MainActor explicitly so the @MainActor panel is happy.
        Task { @MainActor in
            LearnWordPanelController.shared.present(prefill: text)
        }
    }
}

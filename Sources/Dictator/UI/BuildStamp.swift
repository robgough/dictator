import Foundation

/// When this copy of Dictator was built — for development builds only.
///
/// Exists to answer one question quickly: *am I running the build I just
/// made?* Sparkle can replace a local build with a released one, several
/// builds can be installed in a session, and the symptom of testing the wrong
/// one is a change that "doesn't work" because it isn't there. A timestamp in
/// the menu settles it in a glance.
///
/// Taken from the executable's modification date rather than baked in at
/// compile time. A `#define`-style stamp needs a build phase that rewrites a
/// source file or Info.plist on every build, which dirties the tree and defeats
/// incremental builds; the binary's own mtime is written by the linker, needs
/// no plumbing, and is exactly the moment being asked about.
enum BuildStamp {
    /// Nil in release builds — this is a development affordance and should
    /// never appear in a shipped copy.
    static var label: String? {
        #if DEBUG
            guard let builtAt else { return nil }
            let clock = DateFormatter()
            clock.dateFormat = Calendar.current.isDateInToday(builtAt)
                ? "HH:mm" : "d MMM HH:mm"
            return "Built \(clock.string(from: builtAt)) · \(relative(builtAt))"
        #else
            return nil
        #endif
    }

    /// The linker's timestamp on the running binary.
    ///
    /// Computed once: it cannot change while the process that it describes is
    /// still running.
    static let builtAt: Date? = {
        guard let url = Bundle.main.executableURL,
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        else { return nil }
        return values.contentModificationDate
    }()

    /// "just now", "14 min ago", "3 hours ago". Deliberately coarse — the
    /// question is which build, not how long precisely.
    private static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 90 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

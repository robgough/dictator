import Darwin
import Foundation

/// Tracks every MCP subprocess we've spawned so they can be killed
/// synchronously at quit.
///
/// `applicationWillTerminate` is synchronous and the process exits the moment
/// it returns, so the graceful async `MCPClient.stop()` path — close stdin,
/// wait, SIGTERM, wait, SIGKILL — cannot be relied on to finish there. Closing
/// our end of the pipes does make well-behaved servers exit on EOF, but "well
/// behaved" is not a property of arbitrary third-party code, and the failure
/// mode is a user's Mac accumulating orphaned `node` processes every time they
/// quit Dictator.
///
/// So: a flat, lock-guarded set of pids maintained alongside the actor, which
/// a signal-sending sweep can read without awaiting anything.
enum MCPProcessReaper {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids: Set<pid_t> = []

    static func register(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pids.insert(pid)
    }

    static func unregister(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pids.remove(pid)
    }

    /// SIGTERM everything still registered, then SIGKILL whatever ignored it.
    /// Safe to call from `applicationWillTerminate`: no awaits, bounded by a
    /// fixed 300ms grace.
    static func terminateAll() {
        lock.lock()
        let targets = pids
        pids.removeAll()
        lock.unlock()
        guard !targets.isEmpty else { return }

        for pid in targets { kill(pid, SIGTERM) }
        // A short, fixed grace period. Long enough for a node process to run
        // its exit handlers, short enough that quitting still feels instant.
        usleep(300_000)
        for pid in targets where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }
}

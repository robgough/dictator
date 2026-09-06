import Foundation
import Observation
import CoreAudio

@MainActor
@Observable
final class AudioDeviceManager {
    static let shared = AudioDeviceManager()

    /// Devices currently connected to the machine, in CoreAudio's reported order.
    private(set) var connectedDevices: [AudioDevice] = []

    /// Priority-ordered list of devices the user has ever seen / cared about.
    /// First entry is highest preference.
    private(set) var knownDevices: [AudioDevice] = []

    private static let storageKey = "AudioDeviceManager.knownDevices.v1"

    /// How long a device may go unseen before it's dropped from the priority
    /// list — unless the user has ranked it above the "System default" sentinel,
    /// which marks it as one they deliberately prefer (a mic that's merely
    /// unplugged right now, say). Stops the list silently accreting every
    /// transient device the machine has ever exposed.
    private static let staleDeviceTTL: TimeInterval = 7 * 24 * 60 * 60

    private var listenerToken: AudioDevicesListenerToken?

    private init() {
        loadKnown()
    }
    // Singleton lives for the app's lifetime; no deinit needed.

    /// Called once at app launch.
    func bootstrap() {
        refresh()
        listenerToken = AudioDeviceEnumerator.addDevicesChangedListener { [weak self] in
            // Listener block hops to main via DispatchQueue.main.async inside the
            // enumerator. We still need to bridge back into @MainActor isolation.
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Re-scan the hardware. Merges any newly-seen device into `knownDevices`
    /// (appended to the end, so user-ordered devices stay where they are).
    /// Always ensures the synthetic "System default" entry is present so the
    /// user can rank it against real hardware.
    func refresh() {
        let connected = AudioDeviceEnumerator.listInputDevices()
        connectedDevices = connected

        var merged = knownDevices
        let now = Date()
        for c in connected {
            if let i = merged.firstIndex(where: { $0.uid == c.uid }) {
                merged[i].name = c.name
                merged[i].manufacturer = c.manufacturer
                merged[i].lastSeen = now
            } else {
                merged.append(AudioDevice(uid: c.uid, name: c.name, manufacturer: c.manufacturer, lastSeen: now))
            }
        }
        if !merged.contains(where: { $0.isSystemDefault }) {
            merged.append(AudioDevice.systemDefault)
        }
        // Drop leaked meeting-tap aggregates and devices that have aged out (see
        // `cleaned`). Currently-connected devices were just stamped with `now`
        // above, so they're never the ones pruned here.
        merged = Self.cleaned(merged, now: now)
        if merged != knownDevices {
            knownDevices = merged
            persist()
        }
    }

    /// Removes entries that shouldn't linger in the priority list:
    ///
    /// - Our own meeting-capture aggregates (`Dictator Meeting Tap` and the
    ///   `CADefaultDeviceAggregate` shims). These are private devices we leak
    ///   into our own enumeration; they're never user-facing hardware.
    /// - Devices unseen for longer than `staleDeviceTTL`, **unless** the user
    ///   ranked them above the "System default" sentinel — anything above the
    ///   sentinel is a deliberate preference and is kept even while unplugged.
    ///
    /// The sentinel itself is always preserved. `now` is threaded in (rather
    /// than read here) so the caller controls the clock for the whole pass.
    private static func cleaned(_ devices: [AudioDevice], now: Date) -> [AudioDevice] {
        let sentinelIndex = devices.firstIndex(where: { $0.isSystemDefault }) ?? devices.count
        return devices.enumerated().compactMap { offset, device -> AudioDevice? in
            if device.isSystemDefault { return device }
            if AudioDeviceEnumerator.looksLikePrivateAggregate(name: device.name, uid: device.uid) { return nil }
            if offset < sentinelIndex { return device }   // user-prioritised → keep regardless of age
            return now.timeIntervalSince(device.lastSeen) < staleDeviceTTL ? device : nil
        }
    }

    /// True when the given UID is currently plugged in. The synthetic
    /// "System default" entry is always treated as connected — there is
    /// always a system default input (even if it's the built-in mic).
    func isConnected(_ uid: String) -> Bool {
        if uid == AudioDevice.systemDefaultUID { return true }
        return connectedDevices.contains(where: { $0.uid == uid })
    }

    /// The first known device that is currently connected. With the
    /// always-present "System default" sentinel this is non-nil whenever
    /// the list isn't empty — anything ranked below the sentinel is
    /// effectively unreachable.
    func preferredConnectedDevice() -> AudioDevice? {
        knownDevices.first(where: { isConnected($0.uid) })
    }

    /// Resolves the preferred device to a live `AudioDeviceID`. If the
    /// "System default" sentinel wins, defers to whatever input macOS is
    /// currently configured to use. Returns nil if even that doesn't exist.
    func activeInputDeviceID() -> AudioDeviceID? {
        guard let pref = preferredConnectedDevice() else {
            return AudioDeviceEnumerator.systemDefaultInputDeviceID()
        }
        if pref.isSystemDefault {
            return AudioDeviceEnumerator.systemDefaultInputDeviceID()
        }
        return AudioDeviceEnumerator.deviceID(forUID: pref.uid)
            ?? AudioDeviceEnumerator.systemDefaultInputDeviceID()
    }

    /// Display name for the device currently in use. When the System default
    /// sentinel wins we resolve through to whatever mic macOS is actually
    /// using right now (e.g. "MacBook Pro Microphone"), so the HUD / active-
    /// device card always tells the user *which* physical mic is live —
    /// "System default" alone leaves them guessing.
    func activeInputDeviceName() -> String {
        guard let pref = preferredConnectedDevice() else {
            return AudioDevice.systemDefault.name
        }
        if pref.isSystemDefault {
            if let id = AudioDeviceEnumerator.systemDefaultInputDeviceID(),
               let name = AudioDeviceEnumerator.name(forDeviceID: id) {
                return name
            }
            return AudioDevice.systemDefault.name
        }
        return pref.name
    }

    /// Whether the currently-active input is a Bluetooth device. Bluetooth
    /// input forces macOS into HFP profile, which downgrades headphone audio
    /// to mono 16 kHz and adds ~2–5 s of warmup latency to every
    /// `AVAudioEngine.start()` against the device.
    func activeInputIsBluetooth() -> Bool {
        guard let id = activeInputDeviceID() else { return false }
        return AudioDeviceEnumerator.isBluetooth(deviceID: id)
    }

    // MARK: - Mutation

    func move(from source: IndexSet, to destination: Int) {
        knownDevices.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Promote `uid` to the top of `knownDevices` so it wins
    /// `preferredConnectedDevice()` the next time the user records. No-op if
    /// the device isn't known. Used by quick-pick UIs (e.g. the Meetings
    /// window's toolbar mic chooser) that want "use this device now" with
    /// one click rather than a drag-and-drop reorder.
    func promote(uid: String) {
        guard let idx = knownDevices.firstIndex(where: { $0.uid == uid }) else { return }
        guard idx > 0 else { return }
        let device = knownDevices.remove(at: idx)
        knownDevices.insert(device, at: 0)
        persist()
    }

    func forget(uid: String) {
        // The "System default" sentinel is structural — refuse to drop it
        // so the user can't accidentally remove their fallback option. The
        // UI hides the forget button on this row already, but belt-and-
        // braces in case something else calls in.
        guard uid != AudioDevice.systemDefaultUID else { return }
        knownDevices.removeAll(where: { $0.uid == uid })
        persist()
    }

    // MARK: - Persistence

    private func loadKnown() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([AudioDevice].self, from: data)
        else {
            // First launch (or wiped settings): seed with just the System
            // default sentinel so the priority list is never empty.
            knownDevices = [AudioDevice.systemDefault]
            return
        }
        // Sweep leaked meeting-tap aggregates (older builds persisted one new
        // UID per meeting). Deliberately do NOT TTL-prune here: `loadKnown` runs
        // in `init`, before any `refresh()`, so it has no live-connectivity info
        // and would wrongly drop a connected-but-stale device (then re-append it
        // out of order). `refresh()` — which stamps connected devices with `now`
        // first — owns TTL pruning. See `cleaned(_:now:)`.
        var sanitised = decoded.filter {
            !AudioDeviceEnumerator.looksLikePrivateAggregate(name: $0.name, uid: $0.uid)
        }
        // Pre-existing users won't have the sentinel persisted yet. Append it at
        // the bottom so behaviour matches before the upgrade — real devices win
        // first; system default only kicks in when none are connected.
        if !sanitised.contains(where: { $0.isSystemDefault }) {
            sanitised.append(AudioDevice.systemDefault)
        }
        knownDevices = sanitised
        if sanitised != decoded {
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(knownDevices) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

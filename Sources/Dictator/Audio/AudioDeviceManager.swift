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
        if merged != knownDevices {
            knownDevices = merged
            persist()
        }
    }

    func isConnected(_ uid: String) -> Bool {
        connectedDevices.contains(where: { $0.uid == uid })
    }

    /// The first known device that is currently connected. If the user has no
    /// preference list (fresh install with no connect events yet), returns nil
    /// and the caller should fall back to the system default.
    func preferredConnectedDevice() -> AudioDevice? {
        knownDevices.first(where: { isConnected($0.uid) })
    }

    /// Resolves the preferred device to a live `AudioDeviceID`. Falls back to
    /// the system default input. Returns nil if even that doesn't exist.
    func activeInputDeviceID() -> AudioDeviceID? {
        if let pref = preferredConnectedDevice(),
           let id = AudioDeviceEnumerator.deviceID(forUID: pref.uid) {
            return id
        }
        return AudioDeviceEnumerator.systemDefaultInputDeviceID()
    }

    /// Display name for the device currently in use (or "System default").
    func activeInputDeviceName() -> String {
        if let pref = preferredConnectedDevice() { return pref.name }
        return "System default"
    }

    // MARK: - Mutation

    func move(from source: IndexSet, to destination: Int) {
        knownDevices.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func forget(uid: String) {
        knownDevices.removeAll(where: { $0.uid == uid })
        persist()
    }

    // MARK: - Persistence

    private func loadKnown() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([AudioDevice].self, from: data)
        else { return }
        // Earlier versions persisted CoreAudio's transient private-aggregate shims
        // (one new UID per session). Sweep them out so the user sees a clean list.
        let cleaned = decoded.filter { !AudioDeviceEnumerator.looksLikePrivateAggregate(name: $0.name, uid: $0.uid) }
        knownDevices = cleaned
        if cleaned.count != decoded.count {
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(knownDevices) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

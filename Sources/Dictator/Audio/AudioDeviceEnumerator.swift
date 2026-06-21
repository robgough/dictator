import Foundation
import CoreAudio

/// Thin CoreAudio wrapper. Lists input devices, resolves UID → AudioDeviceID,
/// installs / removes the hardware-devices-changed property listener.
enum AudioDeviceEnumerator {
    /// Identifiers `MeetingAudioRecorder` stamps onto its system-capture
    /// aggregate device. These are private capture devices we create ourselves
    /// — never user-facing input hardware — so they're filtered out of the
    /// priority list wherever it's built. Kept here, the device-identity layer,
    /// as the single source of truth; the meeting recorder reads them back.
    static let meetingTapUIDPrefix = "net.robgough.Dictator.meetingTap-"
    static let meetingTapDeviceName = "Dictator Meeting Tap"

    static func listInputDevices() -> [AudioDevice] {
        let ids = allDeviceIDs()
        let now = Date()
        return ids.compactMap { id -> AudioDevice? in
            guard hasInputStreams(deviceID: id) else { return nil }
            // CoreAudio creates a fresh private aggregate (name `CADefaultDeviceAggregate-…`)
            // every time anything reads from the system default input. Skip them — they're
            // implementation detail, not user-facing hardware.
            if isPrivateAggregateDevice(deviceID: id) { return nil }
            guard let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal) else { return nil }
            let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) ?? "Unknown"
            // Belt-and-braces over the runtime priv-flag check above: our own
            // meeting-capture aggregates are private, but if the flag ever fails
            // to read we still recognise them by name / UID and keep them out.
            if looksLikePrivateAggregate(name: name, uid: uid) { return nil }
            let manufacturer = stringProperty(deviceID: id, selector: kAudioObjectPropertyManufacturer, scope: kAudioObjectPropertyScopeGlobal)
            return AudioDevice(uid: uid, name: name, manufacturer: manufacturer, lastSeen: now)
        }
    }

    /// Recognises a device that should never sit in the user's input list:
    /// CoreAudio's transient `CADefaultDeviceAggregate-…` shims, and our own
    /// meeting-capture aggregates (`Dictator Meeting Tap`). Used both to sweep
    /// stale persisted `knownDevices` and to filter the live enumeration.
    static func looksLikePrivateAggregate(name: String, uid: String) -> Bool {
        name.hasPrefix("CADefaultDeviceAggregate")
            || uid.hasPrefix("CADefaultDeviceAggregate")
            || uid.hasPrefix(meetingTapUIDPrefix)
            || name == meetingTapDeviceName
    }

    /// Reads the device's display name. Used when we already have an
    /// `AudioDeviceID` in hand and want to label it (e.g. resolving the
    /// system default input back to "MacBook Pro Microphone" for the HUD).
    static func name(forDeviceID id: AudioDeviceID) -> String? {
        stringProperty(deviceID: id, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
    }

    /// Resolves a `kAudioDevicePropertyDeviceUID` string to its current `AudioDeviceID`.
    /// Returns nil when the device is not currently connected.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var cfUID: CFString = uid as CFString
        var deviceID: AudioDeviceID = kAudioObjectUnknown

        return withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            withUnsafeMutablePointer(to: &deviceID) { idPtr -> AudioDeviceID? in
                var t = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(uidPtr),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(idPtr),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDeviceForUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                let status = AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &addr,
                    0, nil,
                    &size,
                    &t
                )
                if status == noErr, idPtr.pointee != kAudioObjectUnknown {
                    return idPtr.pointee
                }
                return nil
            }
        }
    }

    /// True when the device reports a Bluetooth transport (classic or LE).
    /// Drives BT-specific behaviour: a warning in Settings, skipping the
    /// mainMixer routing in the live meter, and surfacing "Connecting…" in
    /// the HUD so the user understands the ~2–5 s HFP negotiation delay.
    static func isBluetooth(deviceID: AudioDeviceID) -> Bool {
        guard let transport = transportType(forDeviceID: deviceID) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Reads the raw transport-type code for an arbitrary device. Returns
    /// nil if the property isn't available (rare — every real device exposes
    /// it). Used by the echo-cancellation auto-detector to decide whether
    /// the active output is built-in speakers / external speakers (AEC
    /// helpful) or headphones (AEC unnecessary, and slightly degrades
    /// timbre).
    static func transportType(forDeviceID id: AudioDeviceID) -> UInt32? {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)
        return status == noErr ? transport : nil
    }

    static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0, nil,
            &size,
            &id
        )
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Resolve whatever macOS currently treats as the system default
    /// **output** device. Used by the meeting recorder's echo-cancellation
    /// auto-mode to figure out whether the user is on speakers (mic will
    /// pick up the remote side's audio, AEC wanted) or headphones (no
    /// bleed, AEC unnecessary).
    static func systemDefaultOutputDeviceID() -> AudioDeviceID? {
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0, nil,
            &size,
            &id
        )
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Best-effort "does the active output look like a headphone or a
    /// speaker?" probe used by the echo-cancellation auto-mode.
    ///
    /// The decision rule errs on the side of "treat as headphones" (and
    /// therefore leave AEC OFF) in ambiguous cases — the failure mode of
    /// unnecessary AEC on headphones (slightly thinner voice timbre) is
    /// more user-noticeable than the failure mode of missing AEC on
    /// speakers (the duplicated-remote-speech bleed, which the
    /// post-transcription dedup pass still catches as backup).
    ///
    /// Heuristics, in order:
    /// 1. Bluetooth transport → headphones (AirPods, BT headsets — the
    ///    overwhelming Bluetooth output case for a Mac on a call).
    /// 2. Device name contains "headphone" / "headset" / "earbud" /
    ///    "airpod" / "earpod" (case-insensitive) → headphones. Catches
    ///    USB headsets and the built-in 3.5 mm jack when something's
    ///    plugged in (macOS retitles the built-in output to
    ///    "Headphones").
    /// 3. Built-in transport → speakers (laptop / iMac internal speakers).
    /// 4. Anything else (external USB audio interface, HDMI, AirPlay) →
    ///    headphones, on the conservative principle above.
    static func outputLooksLikeHeadphones(deviceID: AudioDeviceID) -> Bool {
        let transport = transportType(forDeviceID: deviceID)
        if let transport,
           transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }
        let lowerName = (name(forDeviceID: deviceID) ?? "").lowercased()
        let headphoneTokens = ["headphone", "headset", "earbud", "airpod", "earpod"]
        if headphoneTokens.contains(where: { lowerName.contains($0) }) {
            return true
        }
        if let transport, transport == kAudioDeviceTransportTypeBuiltIn {
            return false
        }
        return true
    }

    // MARK: - Property listener for hardware changes

    static func addDevicesChangedListener(_ block: @Sendable @escaping () -> Void) -> AudioDevicesListenerToken {
        let context = DevicesListenerContext(block: block)
        let unmanaged = Unmanaged.passRetained(context)
        let opaque = unmanaged.toOpaque()

        let proc: AudioObjectPropertyListenerProc = { _, _, _, contextPtr in
            guard let contextPtr else { return noErr }
            let ctx = Unmanaged<DevicesListenerContext>.fromOpaque(contextPtr).takeUnretainedValue()
            let block = ctx.block
            DispatchQueue.main.async { block() }
            return noErr
        }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            proc,
            opaque
        )
        return AudioDevicesListenerToken(context: unmanaged, proc: proc)
    }

    static func removeListener(_ token: AudioDevicesListenerToken) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            token.proc,
            token.context.toOpaque()
        )
        token.context.release()
    }

    // MARK: - Private helpers

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return status == noErr ? ids : []
    }

    /// Detects CoreAudio's transient `CADefaultDeviceAggregate-…` shim devices that
    /// wrap whatever the current default input is. They have aggregate transport type
    /// and the private flag set; the name-prefix check is a belt-and-braces fallback
    /// in case `kAudioAggregateDevicePropertyIsPrivate` isn't reachable on this device.
    private static func isPrivateAggregateDevice(deviceID: AudioDeviceID) -> Bool {
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let transportStatus = AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &transportSize, &transport)
        guard transportStatus == noErr, transport == kAudioDeviceTransportTypeAggregate else { return false }

        // 'priv' — kAudioAggregateDevicePropertyIsPrivate. Hardcoded because the
        // Swift CoreAudio module doesn't surface every aggregate-only selector.
        let isPrivateSelector: AudioObjectPropertySelector = 0x70726976
        var isPrivate: UInt32 = 0
        var pSize = UInt32(MemoryLayout<UInt32>.size)
        var pAddr = AudioObjectPropertyAddress(
            mSelector: isPrivateSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(deviceID, &pAddr, 0, nil, &pSize, &isPrivate) == noErr, isPrivate != 0 {
            return true
        }

        // Fallback: any aggregate whose name starts with the CoreAudio internal prefix.
        let name = stringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) ?? ""
        return name.hasPrefix("CADefaultDeviceAggregate")
    }

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        return size > 0
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let unmanaged = cfStr else { return nil }
        return unmanaged.takeRetainedValue() as String
    }
}

/// Strong-reference holder for the property-listener block. Marked
/// `@unchecked Sendable` because the only field is itself `@Sendable`.
private final class DevicesListenerContext: @unchecked Sendable {
    let block: @Sendable () -> Void
    init(block: @Sendable @escaping () -> Void) { self.block = block }
}

struct AudioDevicesListenerToken {
    fileprivate let context: Unmanaged<DevicesListenerContext>
    fileprivate let proc: AudioObjectPropertyListenerProc
}

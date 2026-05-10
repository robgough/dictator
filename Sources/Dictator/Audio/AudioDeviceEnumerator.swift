import Foundation
import CoreAudio

/// Thin CoreAudio wrapper. Lists input devices, resolves UID → AudioDeviceID,
/// installs / removes the hardware-devices-changed property listener.
enum AudioDeviceEnumerator {
    static func listInputDevices() -> [AudioDevice] {
        let ids = allDeviceIDs()
        let now = Date()
        return ids.compactMap { id -> AudioDevice? in
            guard hasInputStreams(deviceID: id) else { return nil }
            guard let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal) else { return nil }
            let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) ?? "Unknown"
            let manufacturer = stringProperty(deviceID: id, selector: kAudioObjectPropertyManufacturer, scope: kAudioObjectPropertyScopeGlobal)
            return AudioDevice(uid: uid, name: name, manufacturer: manufacturer, lastSeen: now)
        }
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

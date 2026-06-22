import Foundation
import CoreAudio

/// Reads and writes the scalar volume on the system default output device.
///
/// Caveat: on USB / Thunderbolt audio interfaces whose driver owns the gain
/// stage, `kAudioDevicePropertyVolumeScalar` is either absent or marked
/// not-settable — the macOS volume slider is greyed out for the same
/// reason. Reads return nil and writes return false in that case; the
/// caller (AudioInterrupter) treats it as "couldn't lower the volume" and
/// simply skips restore. No noise, no error surface to the user — the
/// `pauseMedia` setting is the escape hatch for those setups.
enum SystemOutputVolume {
    /// Current scalar volume [0...1] on the default output device, or nil
    /// if the device doesn't expose a settable volume.
    static func current() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        return readVolume(deviceID: device)
    }

    /// Sets the default output device's scalar volume to `value` (clamped
    /// to [0, 1]). Returns true on success, false when the device doesn't
    /// accept volume writes.
    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        let clamped = max(0, min(1, value))
        return writeVolume(deviceID: device, value: clamped)
    }

    /// True when the default output device exposes a *settable* scalar volume —
    /// the same `HasProperty` + `IsPropertySettable` gate `writeVolume` uses, over
    /// the same elements, so "can duck" and "did duck" can never disagree. False
    /// for interfaces whose driver owns the gain stage (the macOS slider greys out
    /// for the same reason) — the signal Auto mode uses to fall back to pausing.
    static func isSettable() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        return false
    }

    // MARK: - Private

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &id
        )
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Tries the device's master volume element first; falls back to
    /// element 1 (typically left channel) when the device doesn't expose
    /// a master. Aggregate devices and a handful of older drivers don't
    /// have a main-element volume.
    private static func readVolume(deviceID: AudioDeviceID) -> Float? {
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            var value: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    private static func writeVolume(deviceID: AudioDeviceID, value: Float) -> Bool {
        var wroteSomething = false
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr,
                  settable.boolValue else { continue }
            var v = value
            let size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &v) == noErr {
                wroteSomething = true
                // Main element write covers the whole device; if we hit
                // that one, we're done. Stereo channel writes touch
                // L then R, so let the loop continue.
                if element == kAudioObjectPropertyElementMain { return true }
            }
        }
        return wroteSomething
    }
}

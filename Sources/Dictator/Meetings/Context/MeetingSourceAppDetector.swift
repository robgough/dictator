import AppKit
import CoreAudio

/// Works out which app the meeting ran in. The strong signal is Core Audio's
/// process list — which apps are actually EMITTING output audio during the
/// recording (the same API family the meeting tap already uses) — sampled at
/// start and periodically, so the meeting app wins even when it's not
/// frontmost. The frontmost app at record start is the tiebreaker.
///
/// Verdict ranking: a known meeting app with audio hits beats a browser with
/// hits (Meet/etc. run in tabs) beats anything else with hits. Media players
/// and Dictator itself never count.
@MainActor
final class MeetingSourceAppDetector {
    private var hits: [String: Int] = [:]
    private var frontmostAtStart: (bundleID: String, name: String)?
    private var samplerTask: Task<Void, Never>?

    func start() {
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleID = app.bundleIdentifier {
            frontmostAtStart = (bundleID, app.localizedName ?? bundleID)
        }
        sample()
        samplerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                self?.sample()
            }
        }
    }

    func stop() -> MeetingSourceApp? {
        samplerTask?.cancel()
        samplerTask = nil
        return verdict()
    }

    private func sample() {
        for bundleID in Self.bundleIDsEmittingOutputAudio() {
            guard !Self.excluded.contains(bundleID),
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            hits[bundleID, default: 0] += 1
        }
    }

    private func verdict() -> MeetingSourceApp? {
        func best(in table: [String: String]) -> MeetingSourceApp? {
            let candidates = hits.filter { table[$0.key] != nil }
            guard let top = candidates.max(by: { $0.value < $1.value }) else { return nil }
            return MeetingSourceApp(bundleID: top.key, name: table[top.key]!)
        }
        // Known meeting app emitting audio — the unambiguous case.
        if let app = best(in: Self.meetingApps) { return app }
        // Browser emitting audio (Meet, in-browser Teams/Zoom). Prefer the
        // one that was frontmost at start when several browsers played audio.
        if let front = frontmostAtStart,
           Self.browsers[front.bundleID] != nil,
           hits[front.bundleID] != nil {
            return MeetingSourceApp(bundleID: front.bundleID, name: Self.browsers[front.bundleID]!)
        }
        if let browser = best(in: Self.browsers) { return browser }
        // Anything else that played audio throughout — better than nothing,
        // displayed by its real name when we can resolve one.
        if let top = hits.max(by: { $0.value < $1.value }) {
            let name = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == top.key }?.localizedName ?? top.key
            return MeetingSourceApp(bundleID: top.key, name: name)
        }
        return nil
    }

    /// Bundle IDs of processes currently emitting output audio, via the
    /// system audio-process object list.
    private static func bundleIDsEmittingOutputAudio() -> [String] {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &objects) == noErr else { return [] }

        var out: [String] = []
        for object in objects {
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running == 1 else { continue }

            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var bundleRef: CFString = "" as CFString
            var bundleSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundleRef) == noErr else { continue }
            let bundleID = bundleRef as String
            if !bundleID.isEmpty { out.append(bundleID) }
        }
        return out
    }

    private static let meetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "Cisco-Systems.Spark": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.skype.skype": "Skype",
        "com.ringcentral.glip": "RingCentral",
        "com.gotomeeting.GoToMeeting": "GoToMeeting",
    ]

    private static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "org.mozilla.firefox": "Firefox",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Edge",
        "com.brave.Browser": "Brave",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    /// Apps whose output audio never indicates a meeting.
    private static let excluded: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
        "com.apple.TV",
        "com.apple.Podcasts",
        "com.apple.QuickTimePlayerX",
        "tv.plex.desktop",
        "com.colliderli.iina",
        "org.videolan.vlc",
    ]
}

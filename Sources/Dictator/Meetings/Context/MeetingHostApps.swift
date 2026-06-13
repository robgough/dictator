import Foundation

/// Single source of truth for "which apps host meetings". Shared by
/// `MeetingSourceAppDetector` (audio-process ranking) and
/// `MeetingScreenCapturer` (which window to scope screen capture to), so the
/// two context features always agree on what counts as a meeting app.
enum MeetingHostApps {
    /// Native meeting clients, bundle ID → display name.
    static let meetingApps: [String: String] = [
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

    /// Browsers — meetings run in a tab (Meet, in-browser Teams/Zoom).
    static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "org.mozilla.firefox": "Firefox",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Edge",
        "com.brave.Browser": "Brave",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    /// Apps whose output audio never indicates a meeting (media players).
    static let excluded: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
        "com.apple.TV",
        "com.apple.Podcasts",
        "com.apple.QuickTimePlayerX",
        "tv.plex.desktop",
        "com.colliderli.iina",
        "org.videolan.vlc",
    ]

    /// Every bundle ID that could host a meeting window — the candidate set the
    /// screen capturer scopes to.
    static let hostBundleIDs: Set<String> = Set(meetingApps.keys).union(browsers.keys)
}

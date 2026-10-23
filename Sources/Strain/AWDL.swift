import Foundation

/// How Strain treats AWDL (Apple Wireless Direct Link, interface awdl0): the peer-to-peer Wi-Fi link behind AirDrop,
/// AirPlay to Mac, Sidecar and Universal Control. While it's active the Wi-Fi radio hops to the AWDL channel every
/// second or so, which shows up as ping spikes in games and calls.
enum AWDLMode: String, CaseIterable, Identifiable {
    case normal, lowLatency, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: "AirDrop on"
        case .lowLatency: "Low ping"
        case .auto: "Auto"
        }
    }
}

struct AWDLDecision: Equatable {
    var hold: Bool
    var reason: String  // why, in plain words, for the card
}

enum AWDL {
    static let otherApp = "com.jh.AWDLControl"  // AWDL Control: holds awdl0 down on its own, fights AirDrop

    /// Latency-sensitive apps that aren't filed under Games: cloud gaming, remote play, calls, recording.
    static let autoApps: Set<String> = [
        "com.nvidia.gfnpc.mall", "com.moonlight-stream.Moonlight", "tv.parsec.www",
        "us.zoom.xos", "com.apple.FaceTime", "fm.riverside.studio", "com.valvesoftware.steam",
    ]

    /// The app in front, as Auto sees it.
    struct App: Equatable { var bundleID: String, name: String, category: String?, path: String? = nil }

    /// A game (Games category, or installed by Steam) or a listed latency-sensitive app.
    static func wantsLowLatency(_ app: App) -> Bool {
        autoApps.contains(app.bundleID) || app.category?.hasSuffix("games") == true || app.path?.contains("/steamapps/common/") == true
    }

    /// Auto looks at the front app only: Steam idling in the Dock or Zoom left open after a call must not block AirDrop all day.
    static func decide(_ mode: AWDLMode, front: App?, pausedUntil: Date?, now: Date = .now) -> AWDLDecision {
        if let pausedUntil, pausedUntil > now {
            return AWDLDecision(hold: false, reason: "AirDrop allowed until \(pausedUntil.formatted(date: .omitted, time: .shortened)).")
        }
        switch mode {
        case .normal:
            return AWDLDecision(hold: false, reason: "AirDrop, AirPlay to Mac and Sidecar work. Wi-Fi may briefly hop channels for them, which can spike ping in games and calls.")
        case .lowLatency:
            return AWDLDecision(hold: true, reason: "For games and calls: Wi-Fi stays on one channel, so no ping spikes. AirDrop, AirPlay to Mac and Sidecar are off until you switch back.")
        case .auto:
            guard let front, wantsLowLatency(front) else {
                return AWDLDecision(hold: false, reason: "AirDrop stays on, and pauses by itself while a game, GeForce NOW, Zoom or FaceTime is the app in front.")
            }
            return AWDLDecision(hold: true, reason: "AirDrop paused for low ping while \(front.name) is in front. It comes back when you switch away.")
        }
    }
}

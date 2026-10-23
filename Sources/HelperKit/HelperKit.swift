import Foundation

/// What Strain and its root helper agree on: names, who may talk to whom, and the only things the helper does.
public enum HelperKit {
    public static let label = "com.josephgoksu.strain.helper"
    public static let plist = label + ".plist"
    public static let team = "J9GF96BYUX"  // Reaktif LLC; build.sh signs both binaries with this team's Developer ID

    /// The helper accepts only Strain signed by our team; Strain talks only to a helper signed by our team.
    public static let appRequirement = requirement("com.josephgoksu.strain")
    public static let helperRequirement = requirement(label)
    static func requirement(_ id: String) -> String {
        "identifier \"\(id)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The only commands the helper runs as root, by name. Strain can't send a command line.
    public static let actions: [String: [[String]]] = [
        "dns": [["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"]],
        "purge": [["/usr/sbin/purge"]],
        "audio": [["/usr/bin/killall", "coreaudiod"]],
        "bluetooth": [["/usr/bin/killall", "bluetoothd"]],
    ]

    /// The fallback for macOS's password sheet: the same commands as `actions[id]`, as one shell line.
    public static func shell(_ id: String) -> String {
        (actions[id] ?? []).map { $0.joined(separator: " ") }.joined(separator: "; ")
    }

    /// Exists while the helper has awdl0 down. /var/run is root-only and empties at boot, so a helper that crashed
    /// while holding finds it on its next start and gives AirDrop back.
    public static let heldMarker = "/var/run/com.josephgoksu.strain.awdl-held"

    /// awdl0's UP flag from getifaddrs: no process spawn, safe every second. nil = this Mac has no awdl0.
    public static func awdlIsUp() -> Bool? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var next = list
        while let a = next {
            if String(cString: a.pointee.ifa_name) == "awdl0" { return a.pointee.ifa_flags & UInt32(IFF_UP) != 0 }
            next = a.pointee.ifa_next
        }
        return nil
    }
}

/// The helper's once-a-second AirDrop decision, pure so it can be tested without root.
public struct AWDLGuard: Equatable {
    public var held: Bool  // we took awdl0 down and haven't given it back
    public enum Step: Equatable { case none, down, up }
    public init(held: Bool) { self.held = held }

    /// Keep the link down while anyone holds; bring it up once, when the last hold goes.
    public mutating func step(holding: Bool, linkUp: Bool?) -> Step {
        defer { held = holding }
        if holding { return linkUp == true ? .down : .none }
        return held ? .up : .none
    }
}

@objc public protocol StrainHelperProtocol {
    /// Runs `HelperKit.actions[action]`; false for an unknown name or a failed command.
    func run(_ action: String, reply: @escaping (Bool) -> Void)
    /// Holds the AirDrop link (awdl0) down while any connected Strain asks; released when it says so or disconnects.
    func holdAWDL(_ hold: Bool, reply: @escaping () -> Void)
    /// `sfltool dumpbtm` as root: no Touch ID prompt. Empty on failure.
    func loginItems(reply: @escaping (String) -> Void)
}

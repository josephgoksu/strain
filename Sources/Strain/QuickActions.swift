import Foundation
import HelperKit

/// One-click maintenance. Every one is a stock macOS command; nothing here is irreversible
/// except Empty Trash, and every tile needs a second click to run.
struct QuickAction: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let command: String   // /bin/sh; with `admin`, the password-sheet fallback for HelperKit.actions[id]
    var admin = false
    var group = Group.fix

    /// Where a tile sits in the Controls tab.
    enum Group: String, CaseIterable { case fix = "Fix something", network = "Network", utilities = "Utilities" }

    static let all: [QuickAction] = [
        .init(id: "dns", title: "Flush DNS", detail: "Clears cached DNS lookups. Fixes a site that moved or won't resolve after a network change.",
              symbol: "network.badge.shield.half.filled", command: HelperKit.shell("dns"), admin: true, group: .network),
        .init(id: "purge", title: "Free memory", detail: "Drops the disk cache from RAM. Rarely needed: macOS reclaims it on its own; quitting the culprit helps more.",
              symbol: "memorychip", command: HelperKit.shell("purge"), admin: true, group: .utilities),
        .init(id: "dock", title: "Restart Dock", detail: "Fixes a stuck Dock, Launchpad, Mission Control or Spaces.",
              symbol: "dock.rectangle", command: "killall Dock"),
        .init(id: "finder", title: "Restart Finder", detail: "Fixes a frozen Finder or desktop icons that won't update.",
              symbol: "folder", command: "killall Finder"),
        .init(id: "menubar", title: "Restart menu bar", detail: "Fixes missing or frozen menu bar icons and Control Center.",
              symbol: "menubar.rectangle", command: "killall SystemUIServer ControlCenter"),
        .init(id: "openwith", title: "Fix \"Open With\"", detail: "Rebuilds the Launch Services database: duplicate or missing apps in Open With menus.",
              symbol: "arrow.up.forward.app",
              command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -r -domain local -domain system -domain user"),
        .init(id: "quicklook", title: "Reset Quick Look", detail: "Fixes blank or stale file previews and thumbnails.",
              symbol: "eye", command: "qlmanage -r; qlmanage -r cache"),
        .init(id: "simulators", title: "Stop simulators", detail: "Shuts down every booted iOS Simulator. Each one holds GBs of RAM.",
              symbol: "iphone.slash", command: "xcrun simctl shutdown all", group: .utilities),
        .init(id: "audio", title: "Restart audio", detail: "Fixes no sound, crackling, or a missing output device: restarts Core Audio.",
              symbol: "speaker.wave.2", command: HelperKit.shell("audio"), admin: true),
        .init(id: "bluetooth", title: "Restart Bluetooth", detail: "Fixes AirPods, keyboards or mice that won't connect: restarts the Bluetooth daemon.",
              symbol: "dot.radiowaves.left.and.right", command: HelperKit.shell("bluetooth"), admin: true, group: .network),
        .init(id: "trash", title: "Empty Trash", detail: "Empties the Trash through Finder. Permanent.",
              symbol: "trash", command: "osascript -e 'tell application \"Finder\" to empty trash'", group: .utilities),
    ]

    /// Runs off the main thread. Admin: through Strain's helper when it's on (no prompt), else macOS's password sheet.
    /// Returns false on failure or when the user cancels the password prompt.
    func run() async -> Bool {
        guard admin else { return await Task.detached { [command] in exitStatus("/bin/sh", ["-c", command]) == 0 }.value }
        if let ok = await HelperClient.run(id) { return ok }
        return await QuickAction.asRoot(command)
    }

    /// Runs `command` as root through macOS's password sheet; Strain never sees the password. Commands are fixed
    /// strings, so no escaping: a quote or backslash would break out of the AppleScript literal.
    static func asRoot(_ command: String) async -> Bool {
        let script = "do shell script \"\(command)\" with administrator privileges"
        return await Task.detached { exitStatus("/usr/bin/osascript", ["-e", script]) == 0 }.value
    }
}

func exitStatus(_ exe: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

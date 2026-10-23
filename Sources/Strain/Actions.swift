import AppKit

enum Action: Equatable {
    case shutdownSimulators
    case quitApp(String)     // bundle path
    case terminate([Int32])  // SIGTERM, user-owned processes only
    case none                // root or other users' services: macOS restarts them anyway
}

func action(for g: Group, me: UInt32, isRunningApp: Bool) -> Action {
    if g.name == simulatorGroup { return .shutdownSimulators }
    if isMacOSPath(g.path), !isAppleApp(g.bundle) { return .none }  // Finder, Dock, daemons: macOS restarts them
    if let bundle = g.bundle, isRunningApp { return .quitApp(bundle) }
    if g.uids == [me] { return .terminate(g.pids) }
    return .none
}

@MainActor func action(for g: Group) -> Action {
    action(for: g, me: getuid(), isRunningApp: runningApp(g.bundle) != nil)
}

@MainActor func runningApp(_ bundle: String?) -> NSRunningApplication? {
    guard let bundle else { return nil }
    return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == bundle }
}

func formatDuration(_ s: Int) -> String {
    let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return m > 0 ? "\(m)m" : "\(s)s"
}

/// The executable a PID runs right now, nil once it's gone.
func pidPath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
}

/// The PIDs that still belong to `name` now. Rows are up to 10 s old, and macOS reuses PIDs.
/// ponytail: matches the program, not its start time; a PID reused by the same program still passes.
func stillOwned(_ pids: [Int32], by name: String, path: (Int32) -> String? = pidPath) -> [Int32] {
    pids.filter { pid in
        guard let p = path(pid) else { return false }
        return owner(of: p).name == name || (p as NSString).lastPathComponent == name
    }
}

/// Runs an action the user already confirmed in the panel (two-step button). Never called without that.
@MainActor func perform(_ a: Action, on g: Group) {
    switch a {
    case .shutdownSimulators:
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl", "shutdown", "all"]
        try? p.run()
    case .quitApp:
        runningApp(g.bundle)?.terminate()
    case .terminate(let pids):
        for pid in stillOwned(pids, by: g.name) { kill(pid, SIGTERM) }
    case .none:
        break
    }
}

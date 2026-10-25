import AppKit
import os

/// One thing you started and forgot, and why Strain thinks so.
struct Lost: Identifiable, Equatable {
    enum Reason: Equatable {
        case terminalClosed            // running after its terminal closed
        case unused(since: Date)       // an app not brought to the front since
        case idle(since: Date)         // holding memory at ~0% CPU since
        case server(ports: [Int])      // a dev server up for hours
    }
    var group: Group
    var reason: Reason
    var label: String? = nil       // a server's project name; the group keeps the process name Quit matches on
    var id: String { "\(group.name)|\(group.pids.first ?? 0)" }
    /// What Keep remembers: the project for servers, else the group name.
    var keepKey: String { label ?? group.name }

    func why(now: Date = .now) -> String {
        func ago(_ d: Date) -> String { formatDuration(max(0, Int(now.timeIntervalSince(d)))) }
        switch reason {
        case .terminalClosed: return "Terminal closed · running \(formatDuration(group.seconds))"
        case .unused(let since): return "Not used for \(ago(since))"
        case .idle(let since): return "Idle for \(ago(since))"
        case .server(let ports): return "Server on :\(ports.map(String.init).joined(separator: ", :")) · up \(formatDuration(group.seconds))"
        }
    }

    /// For the digest: "vite 3h", "Docker 6h".
    func short(_ title: String, now: Date = .now) -> String {
        let age: Int = switch reason {
        case .unused(let d), .idle(let d): Int(now.timeIntervalSince(d))
        case .terminalClosed, .server: group.seconds
        }
        return "\(title) \(formatDuration(max(0, age)))"
    }
}

/// Things you started and forgot, even when they're quiet. Four signals, each from data Strain already has.
enum Forgotten {
    /// Tools that detach from their terminal on purpose. Pre-kept; the ⋯ menu can un-keep them.
    static let defaultKept = ["tmux", "screen", "gpg-agent", "keyboxd", "ssh-agent"]
    /// Never listed: the desktop, and Strain itself.
    static let neverBundles: Set<String> = ["com.apple.finder", "com.josephgoksu.strain"]

    // MARK: 1. Terminal closed

    /// Mine, parent launchd, no terminal, a command-line program (not inside an app, not part of macOS), old enough.
    static func candidates(_ procs: [Proc], me: UInt32, minSeconds: Int = Int(Thresholds.forgottenAfter)) -> [Proc] {
        procs.filter {
            $0.uid == me && $0.ppid == 1 && $0.tty == "??" && $0.seconds >= minSeconds
                && !$0.path.contains(".app/") && !isMacOSPath($0.path)
        }
    }

    /// Terminal-closed processes, grouped like the Apps list, minus kept names and launchd jobs (LaunchAgents look
    /// the same: parent launchd, no terminal). `jobs` runs only when something is left to check.
    static func terminalClosed(_ procs: [Proc], me: UInt32, kept: Set<String>, jobs: () -> Set<Int32> = launchdJobs) -> [Group] {
        let left = candidates(procs, me: me).filter { !kept.contains(owner(of: $0.path).name) }
        guard !left.isEmpty else { return [] }
        let agents = jobs()
        return group(left.filter { !agents.contains($0.pid) })
    }

    // MARK: 2. Unused apps

    struct App { let bundlePath: String, bundleID: String, launched: Date? }

    /// Apps with a Dock icon not brought to the front for `hours`. Unknown last-front time = launch time.
    static func unusedApps(_ apps: [App], lastFront: [String: Date], groups: [Group], skip: Set<String>, now: Date,
                           hours: Double = Thresholds.unusedAppHours) -> [Lost] {
        apps.compactMap { app in
            // Never earlier than this launch: an app relaunched in the background isn't days unused.
            guard !neverBundles.contains(app.bundleID), !skip.contains(app.bundlePath),
                  let since = [lastFront[app.bundleID], app.launched].compactMap({ $0 }).max(), now.timeIntervalSince(since) >= hours * 3600,
                  let g = groups.first(where: { $0.bundle == app.bundlePath }) else { return nil }
            return Lost(group: g, reason: .unused(since: since))
        }
    }

    // MARK: 3. Idle memory

    /// Which groups hold `Thresholds.idleMemoryMB`+ at under 1% CPU, and since when. Call each tick.
    static func trackIdle(_ groups: [Group], _ since: [String: Date], now: Date) -> [String: Date] {
        var next: [String: Date] = [:]
        for g in groups where g.rssKB >= Int(Thresholds.idleMemoryMB) * 1024 && g.cpu < Thresholds.idleCPU { next[g.name] = since[g.name] ?? now }
        return next
    }

    /// Group names with a process an app started, at any depth (an editor → its extension host → gopls).
    static func appOwned(_ procs: [Proc], appPIDs: Set<Int32>) -> Set<String> {
        let parents = parentMap(procs)
        return Set(procs.filter { descends($0.pid, from: appPIDs, parents: parents) }.map { owner(of: $0.path).name })
    }

    static func parentMap(_ procs: [Proc]) -> [Int32: Int32] { Dictionary(procs.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a }) }

    /// Whether `pid` or one of its ancestors (up to launchd) is in `ancestors`.
    static func descends(_ pid: Int32, from ancestors: Set<Int32>, parents: [Int32: Int32]) -> Bool {
        var p = pid
        for _ in 0..<8 {
            if ancestors.contains(p) { return true }
            guard let up = parents[p], up > 1 else { return false }
            p = up
        }
        return false
    }

    /// Idle long enough, mine, and not an app or an app's helper: apps are judged by use (signal 2), and a helper
    /// (a language server under an editor) sits idle while its app is in use.
    static func idleMemory(_ groups: [Group], idleSince: [String: Date], appOwned: Set<String>, me: UInt32, now: Date,
                           after: Double = Thresholds.forgottenAfter) -> [Lost] {
        groups.compactMap { g in
            guard let since = idleSince[g.name], now.timeIntervalSince(since) >= after, g.uids == [me],
                  !appOwned.contains(g.name), !isMacOSPath(g.path) || g.name == simulatorGroup else { return nil }
            return Lost(group: g, reason: .idle(since: since))
        }
    }

    // MARK: 4. Old dev servers

    /// Your dev servers up `hours`+ that launchd doesn't run (those are meant to stay). Only the server's own
    /// process, so Quit never reaches other processes of the same tool.
    static func oldServers(_ servers: [Server], parents: [Int32: Int32], me: UInt32, jobs: () -> Set<Int32> = launchdJobs,
                           hours: Double = Thresholds.oldServerHours) -> [Lost] {
        let old = servers.filter { $0.kind == .dev && $0.uid == me && Double($0.seconds) >= hours * 3600 }
        guard !old.isEmpty else { return [] }
        let agents = jobs()
        // A launchd job often runs a script that starts the server: check the chain up to launchd.
        return old.filter { !descends($0.pid, from: agents, parents: parents) }.map { s in
            Lost(group: Group(name: owner(of: s.path).name, path: s.path, rssKB: s.rssKB, seconds: s.seconds, pids: [s.pid], uids: [s.uid]),
                 reason: .server(ports: s.ports), label: s.project)
        }
    }

    // MARK: All together

    /// First signal wins for a process (a terminal-closed vite that's also an old server shows once), kept out,
    /// largest memory first.
    static func merge(_ lists: [[Lost]], kept: Set<String>) -> [Lost] {
        var seen = Set<Int32>()
        return lists.joined().filter { l in
            guard !kept.contains(l.keepKey), seen.isDisjoint(with: l.group.pids) else { return false }
            seen.formUnion(l.group.pids)
            return true
        }
        .sorted { $0.group.rssKB > $1.group.rssKB }
    }

    /// PIDs of your launchd jobs (`launchctl list`: "PID Status Label", "-" when not running). Cached a minute: a
    /// long-running launchd server would otherwise cost a spawn every tick, and every rule waits hours anyway.
    static func launchdJobs() -> Set<Int32> {
        if let (at, pids) = jobsCache.withLock({ $0 }), Date.now.timeIntervalSince(at) < 60 { return pids }
        let pids = Set(run("/bin/launchctl", ["list"]).split(separator: "\n").compactMap { Int32($0.split(separator: "\t").first ?? "") })
        jobsCache.withLock { $0 = (.now, pids) }
        return pids
    }
    private static let jobsCache = OSAllocatedUnfairLock<(Date, Set<Int32>)?>(initialState: nil)

    /// The digest text: "vite 3h, Docker 6h, Ollama 2h · 3.1 GB".
    static func digest(_ items: [Lost], title: (Group) -> String, now: Date = .now) -> String {
        let kb = items.reduce(0) { $0 + $1.group.rssKB }
        return items.prefix(4).map { $0.short($0.label ?? title($0.group), now: now) }.joined(separator: ", ")
            + (items.count > 4 ? " and \(items.count - 4) more" : "") + " · \(formatMemory(kb: kb))"
    }
}

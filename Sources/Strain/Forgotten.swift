import Foundation

/// Things you started and forgot. Signal 1: a command-line program still running after its terminal closed. macOS
/// hands such a process to launchd (parent pid 1) and it loses its terminal, so no window or tab shows it anymore.
enum Forgotten {
    /// Tools that detach from their terminal on purpose. Pre-kept; the ⋯ menu can un-keep them.
    static let defaultKept = ["tmux", "screen", "gpg-agent", "keyboxd", "ssh-agent"]

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

    /// PIDs of your launchd jobs (`launchctl list`: "PID Status Label", "-" when not running).
    static func launchdJobs() -> Set<Int32> {
        Set(run("/bin/launchctl", ["list"]).split(separator: "\n").compactMap { Int32($0.split(separator: "\t").first ?? "") })
    }
}

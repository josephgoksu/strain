import Foundation
import Testing
@testable import Strain

/// libproc must see exactly what `lsof` (without sudo) sees: same processes, ports and exposure. Read-only, live.
@Test func listenersMatchLsof() throws {
    var lsof: [Int32: (ports: Set<Int>, exposed: Bool)] = [:], pid: Int32 = 0
    for line in run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]).split(separator: "\n") {
        if line.first == "p" { pid = Int32(line.dropFirst()) ?? 0 }
        guard line.first == "n", let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) else { continue }
        let host = line.dropFirst()[..<colon]
        lsof[pid, default: ([], false)].ports.insert(port)
        if !["127.0.0.1", "[::1]"].contains(String(host)) { lsof[pid]!.exposed = true }
    }
    let mine = Dictionary(uniqueKeysWithValues: readListeners().map { ($0.pid, (Set($0.ports), $0.exposed)) })
    #expect(Set(mine.keys) == Set(lsof.keys))
    for (pid, l) in lsof { #expect(mine[pid]?.0 == l.ports && mine[pid]?.1 == l.exposed, "pid \(pid)") }
    // Command lines and working folders match ps and lsof too.
    for pid in lsof.keys {
        let ps = run("/bin/ps", ["-o", "args=", "-p", String(pid)]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(readArgs(pid) == ps, "args \(pid)")
        let cwd = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", String(pid)]).split(separator: "\n").first { $0.first == "n" }
        #expect(readCwd(pid) == cwd.map { String($0.dropFirst()) }, "cwd \(pid)")
    }
}

@Test func readsOwnCwdAndArgs() {
    #expect(readCwd(getpid()) == FileManager.default.currentDirectoryPath)
    #expect(readArgs(getpid())?.hasPrefix(CommandLine.arguments[0]) == true)
    #expect(readArgs(1) == nil && readCwd(1) == nil)  // launchd is root's: not ours to read, like lsof without sudo
    #expect(processName(getpid()).isEmpty == false)
}

@Test func projectNamesComeFromTheWorkingFolder() {
    let home = "/Users/me"
    #expect(project(cwd: "/Users/me/Development/personal/acme/web", home: home) == "acme/web")
    #expect(project(cwd: "/Users/me/Development/products/widget", home: home) == "widget")
    #expect(project(cwd: "/Users/me/code/thing", home: home) == "code/thing")
    #expect(project(cwd: "/", home: home) == nil)
    #expect(project(cwd: "/Users/me/Library/Containers/x/Data", home: home) == nil)
    #expect(project(cwd: "/Users/me", home: home) == nil)
}

@Test func serversSortDevFirstThenAppsThenMacOS() {
    let procs = [
        Proc(pid: 622, uid: 501, cpu: 0, rssKB: 1000, seconds: 10, path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"),
        Proc(pid: 2076, uid: 501, cpu: 0, rssKB: 16000, seconds: 10, path: "/opt/homebrew/bin/cloudflared"),
        Proc(pid: 89567, uid: 501, cpu: 1, rssKB: 90000, seconds: 300, path: "node"),
    ]
    let listeners = [Listener(pid: 622, command: "ControlCenter", uid: 501, ports: [5000, 7000], exposed: true),
                     Listener(pid: 2076, command: "cloudflared", uid: 501, ports: [20241], exposed: false),
                     Listener(pid: 89567, command: "node", uid: 501, ports: [5195], exposed: false)]
    let s = servers(listeners, procs: procs,
                    cwds: [89567: "/Users/me/Development/personal/acme/web", 2076: "/", 622: "/"],
                    args: [2076: "/opt/homebrew/bin/cloudflared tunnel run"], home: "/Users/me")
    #expect(s.map(\.pid) == [89567, 2076, 622])
    #expect(s[0].kind == .dev && s[0].project == "acme/web" && s[0].rssKB == 90000)
    #expect(s[1].kind == .tool && s[1].args == "/opt/homebrew/bin/cloudflared tunnel run")
    #expect(s[2].kind == .macOS)
}

@Test func liveServersRead() {
    let s = sampleServers(procs: sampleProcesses())
    #expect(s.allSatisfy { !$0.ports.isEmpty })  // may be empty: a CI runner listens on nothing
}

@Test func userToolsUnderUsrLocalAreNotMacOS() {
    let l = [Listener(pid: 9, command: "redis-server", uid: 501, ports: [6379], exposed: false)]
    let p = [Proc(pid: 9, uid: 501, cpu: 0, rssKB: 1, seconds: 1, path: "/usr/local/bin/redis-server")]
    #expect(servers(l, procs: p, cwds: [:], args: [:], home: "/Users/me")[0].kind == .tool)
}

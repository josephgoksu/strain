import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Strain

@Test func keepAwakeHoldsTheRightAssertion() {
    #expect(Awake.type(on: false, locked: false, letDisplaySleep: false, letLockedSleep: false) == nil)
    #expect(Awake.type(on: true, locked: false, letDisplaySleep: false, letLockedSleep: false) == kIOPMAssertionTypePreventUserIdleDisplaySleep)
    #expect(Awake.type(on: true, locked: false, letDisplaySleep: true, letLockedSleep: false) == kIOPMAssertionTypePreventUserIdleSystemSleep)
    #expect(Awake.type(on: true, locked: true, letDisplaySleep: false, letLockedSleep: false) == kIOPMAssertionTypePreventUserIdleDisplaySleep)
    #expect(Awake.type(on: true, locked: true, letDisplaySleep: false, letLockedSleep: true) == nil)  // locked: let it sleep
}

@MainActor @Test func checkLineNamesTheThreeLargest() {
    let parts: [(title: String, bytes: Int64)] = [("Simulators", 4_300_000_000), ("Go build cache", 1_000_000_000), ("npm cache", 2_000_000), ("Bun cache", 1)]
    #expect(Store.checkLine(parts) == "Simulators 4.3 GB, Go build cache 1 GB, npm cache 2 MB")
    #expect(Store.checkLine([]) == "")
}

@Test func onlyRuntimesNoSimulatorUsesAreDeletable() {
    let json = Data("""
    {"A": {"identifier": "A", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "build": "24A434", "deletable": true, "sizeBytes": 8067000161},
     "B": {"identifier": "B", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-2", "build": "22C150", "deletable": true, "sizeBytes": 7000000000},
     "C": {"identifier": "C", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-11-0", "deletable": false, "sizeBytes": 4000000000}}
    """.utf8)
    let sims = [Simulator(udid: "1", name: "iPhone 17", runtime: "iOS 27.0", size: 0, lastUsed: nil, booted: false, available: true)]
    let unused = DevCleanup.parseUnusedRuntimes(json, simulators: sims)
    #expect(unused.map(\.id) == ["B"] && unused[0].name == "iOS 18.2 (22C150)")  // A is in use, C isn't deletable
}

@Test func aiCachesAreOnlyChromiumCacheFolders() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("strain-ai-\(UUID())").path
    defer { try? FileManager.default.removeItem(atPath: home) }
    let claude = home + "/Library/Application Support/Claude"
    for dir in ["Cache", "Cookies", "Local Storage", "vm_bundles", "Partitions/preview/Code Cache", "Partitions/preview/IndexedDB"] {
        try FileManager.default.createDirectory(atPath: claude + "/" + dir, withIntermediateDirectories: true)
    }
    let item = Cleanup.items.first { $0.id == "claude" }!
    #expect(Set(Cleanup.chromiumFolders(item, home: home).map(\.lastPathComponent)) == ["Cache", "Code Cache"])
    #expect(Cleanup.allowed(URL(fileURLWithPath: claude + "/Partitions/preview/Code Cache"), home: home))
    for kept in ["", "/Cookies", "/vm_bundles", "/Local Storage", "/Partitions/preview/IndexedDB"] {
        #expect(!Cleanup.allowed(URL(fileURLWithPath: claude + kept), home: home), "\(kept) must never be emptied")
    }
    // An open app keeps its caches: nothing deleted, every folder reported as left.
    #expect(Cleanup.clean(item, home: home, running: [RunningApp(name: "Claude", bundleID: "com.anthropic.claudefordesktop")]) == 2)
    #expect(FileManager.default.fileExists(atPath: claude + "/Cache"))
}

@Test func ollamaModelsAreNamedLikeOllama() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("strain-ollama-\(UUID())").path
    defer { try? FileManager.default.removeItem(atPath: home) }
    let m = home + "/.ollama/models/manifests/registry.ollama.ai"
    for tag in ["library/nomic-embed-text/latest", "library/llama3.2/3b", "someone/coder/q4"] {
        try FileManager.default.createDirectory(atPath: m + "/" + tag, withIntermediateDirectories: true)
    }
    let ollama = AIData.all.first { $0.id == "ollama" }!
    #expect(ollama.modelNames(home: home) == ["llama3.2:3b", "nomic-embed-text:latest", "someone/coder:q4"])
}

@Test func spaceRanksSubfoldersAndSkipsOtherAppsData() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("strain-space-\(UUID())").path
    defer { try? FileManager.default.removeItem(atPath: home) }
    let fm = FileManager.default
    for (dir, kb) in [("Development/big", 400), ("Development/small", 8), ("Library/Developer", 200), ("Library/Containers", 900)] {
        try fm.createDirectory(atPath: home + "/" + dir, withIntermediateDirectories: true)
        fm.createFile(atPath: home + "/" + dir + "/f", contents: Data(count: kb * 1024))
    }
    #expect(Space.largestFolders(home: home).map { Space.relative($0.path, home) } == ["Development/big", "Library/Developer", "Development/small"])
}

@Test func oldDownloadsAreUntouchedForNinetyDaysAndOnlyThoseCanBeTrashed() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("strain-dl-\(UUID())").path
    defer { try? FileManager.default.removeItem(atPath: home) }
    let fm = FileManager.default, dl = home + "/Downloads"
    try fm.createDirectory(atPath: dl, withIntermediateDirectories: true)
    for name in ["old.dmg", "new.pdf"] { fm.createFile(atPath: dl + "/" + name, contents: Data(count: 4096)) }
    var old = URL(fileURLWithPath: dl + "/old.dmg"), values = URLResourceValues()
    values.contentModificationDate = .now - 200 * 86400
    values.contentAccessDate = .now - 120 * 86400
    try old.setResourceValues(values)
    #expect(Space.oldDownloads(home: home).map { ($0.path as NSString).lastPathComponent } == ["old.dmg"])
    fm.createFile(atPath: home + "/keep.txt", contents: Data())
    #expect(!Space.trash(home + "/keep.txt", home: home) && fm.fileExists(atPath: home + "/keep.txt"))  // not in Downloads
}

@Test func oldLogsGoAndRecentOnesStay() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("strain-logs-\(UUID())").path
    defer { try? FileManager.default.removeItem(atPath: home) }
    let fm = FileManager.default, logs = home + "/Library/Logs/DiagnosticReports"
    try fm.createDirectory(atPath: logs, withIntermediateDirectories: true)
    for name in ["old.ips", "new.ips"] { fm.createFile(atPath: logs + "/" + name, contents: Data(count: 100)) }
    try fm.setAttributes([.modificationDate: Date.now - 40 * 86400], ofItemAtPath: logs + "/old.ips")
    let item = Cleanup.items.first { $0.id == "logs" }!
    #expect(Cleanup.clean(item, home: home, running: []) == 0)
    #expect(!fm.fileExists(atPath: logs + "/old.ips") && fm.fileExists(atPath: logs + "/new.ips") && fm.fileExists(atPath: logs))
}

@Test func helpersInsideAnAppResolveAndADeletedAppShowsAsMissing() {
    let text = """
     #1:
                     Name: Gone
               Identifier: 2.app.gone.Gone
                      URL: /Applications/Gone-\(UUID()).app
                     Type: app (0x2)
              Disposition: [disabled, allowed, notified] (0xa)

     #2:
                     Name: GoneHelper
               Identifier: 4.app.gone.GoneHelper
                      URL: Contents/Library/LoginItems/GoneHelper.app
                     Type: login item (0x4)
              Disposition: [disabled, allowed, notified] (0xa)
        Parent Identifier: 2.app.gone.Gone
    """
    let helper = parseBTM(text).first { $0.name == "GoneHelper" }!
    #expect(helper.url!.hasSuffix(".app/Contents/Library/LoginItems/GoneHelper.app") && helper.url!.hasPrefix("/Applications/Gone-"))
    #expect(helper.missing)
    #expect(localPath("/Users/\(getuid())/Library/x") == NSHomeDirectory() + "/Library/x")
}

@Test func signingBadgesMatchGatekeeper() throws {
    #expect(Signing.badge("/System/Applications/Calculator.app") == nil)  // Apple's own
    #expect(Signing.badge("/bin/ls") == nil)                              // signed program
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("strain-ls-\(UUID())").path
    defer { try? FileManager.default.removeItem(atPath: copy) }
    try FileManager.default.copyItem(atPath: "/bin/ls", toPath: copy)
    #expect(exitStatus("/usr/bin/codesign", ["--remove-signature", copy]) == 0)
    #expect(Signing.badge(copy) == "Unsigned")
    let script = copy + ".sh"
    FileManager.default.createFile(atPath: script, contents: Data("#!/bin/sh\n".utf8))
    defer { try? FileManager.default.removeItem(atPath: script) }
    #expect(Signing.badge(script) == nil)  // scripts are readable: no badge
}

@Test func terminalClosedFindsDetachedToolsOnly() {
    func p(_ pid: Int32, _ path: String, ppid: Int32 = 1, tty: String = "??", uid: UInt32 = 501, secs: Int = 9000) -> Proc {
        Proc(pid: pid, uid: uid, cpu: 0, rssKB: 50_000, seconds: secs, path: path, ppid: ppid, tty: tty)
    }
    let procs = [
        p(1, "/opt/homebrew/bin/vite"),                                  // forgotten
        p(2, "/opt/homebrew/bin/vite", ppid: 900, tty: "ttys003"),       // still in a terminal
        p(3, "/opt/homebrew/bin/tmux"),                                  // kept by default
        p(4, "/Applications/Slack.app/Contents/MacOS/Slack"),            // an app
        p(5, "/usr/libexec/trustd"),                                     // macOS
        p(6, "/opt/homebrew/bin/node", secs: 60),                        // too young
        p(7, "/opt/homebrew/bin/ollama"),                                // a launchd job (LaunchAgent)
        p(8, "/opt/homebrew/bin/vite", uid: 0),                          // not mine
    ]
    let found = Forgotten.terminalClosed(procs, me: 501, kept: Set(Forgotten.defaultKept), jobs: { [7] })
    #expect(found.map(\.name) == ["vite"] && found[0].pids == [1])
    #expect(Forgotten.terminalClosed(procs, me: 501, kept: ["vite", "tmux", "ollama"], jobs: { [] }).isEmpty)
}

@Test func unusedAppsCountFromLastFront() {
    let now = Date.now
    let apps = [Forgotten.App(bundlePath: "/Applications/Xcode.app", bundleID: "com.apple.dt.Xcode", launched: now - 86400),
                Forgotten.App(bundlePath: "/Applications/Slack.app", bundleID: "com.tinyspeck.slackmacgap", launched: now - 86400),
                Forgotten.App(bundlePath: "/System/Library/CoreServices/Finder.app", bundleID: "com.apple.finder", launched: now - 86400),
                Forgotten.App(bundlePath: "/Applications/Raycast.app", bundleID: "com.raycast.macos", launched: now - 86400)]
    let groups = apps.map { Group(name: ($0.bundlePath as NSString).lastPathComponent, bundle: $0.bundlePath, path: $0.bundlePath, rssKB: 900_000, pids: [1]) }
    let lost = Forgotten.unusedApps(apps, lastFront: ["com.apple.dt.Xcode": now - 5 * 3600, "com.tinyspeck.slackmacgap": now - 600],
                                    groups: groups, skip: ["/Applications/Raycast.app"], now: now)
    #expect(lost.map(\.group.name) == ["Xcode.app"])  // Slack used 10 min ago, Finder never, Raycast opens at login
}

@Test func idleMemoryIsForNonAppsOnly() {
    let now = Date.now
    let groups = [Group(name: "ollama", path: "/opt/homebrew/bin/ollama", cpu: 0.2, rssKB: 2_000_000, uids: [501]),
                  Group(name: "gopls", path: "/Users/x/go/bin/gopls", cpu: 0.1, rssKB: 900_000, uids: [501]),
                  Group(name: "busy", path: "/opt/x/busy", cpu: 30, rssKB: 900_000, uids: [501]),
                  Group(name: "small", path: "/opt/x/small", cpu: 0, rssKB: 10_000, uids: [501])]
    var since = Forgotten.trackIdle(groups, [:], now: now - 3 * 3600)
    #expect(Set(since.keys) == ["ollama", "gopls"])
    since = Forgotten.trackIdle(groups, since, now: now)  // the start time sticks
    let lost = Forgotten.idleMemory(groups, idleSince: since, appOwned: ["gopls"], me: 501, now: now)
    #expect(lost.map(\.group.name) == ["ollama"])  // gopls belongs to an open editor
}

@Test func oldServersSkipLaunchdJobsAndTheirChildren() {
    func srv(_ pid: Int32, _ hours: Double, kind: Server.Kind = .dev) -> Server {
        Server(pid: pid, uid: 501, command: "node", path: "/opt/homebrew/bin/node", args: "", ports: [5173], exposed: false,
               project: "app\(pid)", cwd: nil, kind: kind, rssKB: 100_000, seconds: Int(hours * 3600))
    }
    let servers = [srv(10, 20), srv(11, 20), srv(12, 2), srv(13, 20, kind: .app)]
    let lost = Forgotten.oldServers(servers, parents: [11: 50, 50: 99, 99: 1], me: 501, jobs: { [99] })  // 11 runs under a launchd job's script
    #expect(lost.map(\.label) == ["app10"] && lost[0].group.name == "node" && lost[0].group.pids == [10])
}

@Test func mergeShowsAProcessOnceAndHonoursKeep() {
    let vite = Group(name: "vite", path: "/x/vite", rssKB: 100, pids: [7])
    let lists = [[Lost(group: vite, reason: .terminalClosed)], [Lost(group: vite, reason: .server(ports: [5173]), label: "site")],
                 [Lost(group: Group(name: "ollama", path: "/x/ollama", rssKB: 900, pids: [8]), reason: .idle(since: .now))]]
    #expect(Forgotten.merge(lists, kept: []).map(\.group.name) == ["ollama", "vite"])
    #expect(Forgotten.merge(lists, kept: ["ollama"]).map(\.group.name) == ["vite"])
    let now = Date.now
    let text = Forgotten.digest([Lost(group: Group(name: "ollama", path: "", rssKB: 2_097_152, pids: [8]), reason: .idle(since: now - 7200))],
                                title: { $0.name }, now: now)
    #expect(text == "ollama 2h 0m · 2.0 GB")
}

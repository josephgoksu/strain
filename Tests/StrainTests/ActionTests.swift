import Testing
@testable import Strain

@Test func eachGroupGetsTheRightButton() {
    let me: UInt32 = 501
    #expect(action(for: Group(name: simulatorGroup, path: "/x", uids: [me]), me: me, isRunningApp: false) == .shutdownSimulators)
    #expect(action(for: Group(name: "Brave Browser", bundle: "/Applications/Brave Browser.app", path: "/x", uids: [me]), me: me, isRunningApp: true)
            == .quitApp("/Applications/Brave Browser.app"))
    #expect(action(for: Group(name: "ffmpeg", path: "/x", pids: [7, 8], uids: [me]), me: me, isRunningApp: false) == .terminate([7, 8]))
    #expect(action(for: Group(name: "logd", path: "/x", pids: [349], uids: [0]), me: me, isRunningApp: false) == .none)
    #expect(action(for: Group(name: "mixed", path: "/x", pids: [1, 2], uids: [0, me]), me: me, isRunningApp: false) == .none)
    // User-owned, but macOS's own: launchd restarts it, so no button.
    #expect(action(for: Group(name: "duetexpertd", path: "/usr/libexec/duetexpertd", pids: [3], uids: [me]), me: me, isRunningApp: false) == .none)
    #expect(action(for: Group(name: "BackgroundShortcutRunner", path: "/System/Library/PrivateFrameworks/x", pids: [4], uids: [me]), me: me, isRunningApp: false) == .none)
    // CoreServices apps restart themselves (Clean has Restart Finder); Apple's own apps quit like any app.
    let finder = "/System/Library/CoreServices/Finder.app"
    #expect(action(for: Group(name: "Finder", bundle: finder, path: finder + "/Contents/MacOS/Finder", pids: [5], uids: [me]), me: me, isRunningApp: true) == .none)
    let notes = "/System/Applications/Notes.app"
    #expect(action(for: Group(name: "Notes", bundle: notes, path: notes + "/Contents/MacOS/Notes", uids: [me]), me: me, isRunningApp: true) == .quitApp(notes))
    let safari = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
    #expect(action(for: Group(name: "Safari", bundle: safari, path: safari + "/Contents/MacOS/Safari", uids: [me]), me: me, isRunningApp: true) == .quitApp(safari))
    // /usr/local is the user's, not macOS's.
    #expect(action(for: Group(name: "node", path: "/usr/local/bin/node", pids: [6], uids: [me]), me: me, isRunningApp: false) == .terminate([6]))
}

@Test func durationsReadLikeActivityMonitor() {
    #expect(formatDuration(45) == "45s")
    #expect(formatDuration(12 * 60 + 5) == "12m")
    #expect(formatDuration(3 * 3600 + 20 * 60) == "3h 20m")
    #expect(formatDuration(4 * 86400 + 16 * 3600) == "4d 16h")
}

@Test func onlyPidsStillRunningTheSameProgramGetSignalled() {
    let now: [Int32: String] = [
        1: "/Applications/Brave Browser.app/Contents/Frameworks/x/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper",
        2: "/usr/bin/some-other-tool",  // PID 2 was reused by something else
        4: "/opt/homebrew/Cellar/node/24/bin/node",
        5: "/Applications/Setapp/CleanMyMac.app/Contents/Library/LoginItems/x.app/Contents/MacOS/com.macpaw.CleanMyMac-setapp.HealthMonitor",
    ]
    #expect(stillOwned([1, 2, 3], by: "Brave Browser", path: { now[$0] }) == [1])  // 3 is gone
    #expect(stillOwned([4], by: "node", path: { now[$0] }) == [4])
    #expect(stillOwned([5], by: "com.macpaw.CleanMyMac-setapp.HealthMonitor", path: { now[$0] }) == [5])
}

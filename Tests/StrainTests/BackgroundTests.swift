import Testing
@testable import Strain

// Trimmed real `sfltool dumpbtm` output, 2026-10-22.
let btmFixture = """
========================
 Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
========================

 Items:

 #4:
                 UUID: 1
                 Name: com.macpaw.CleanMyMac-setapp.Agent
       Developer Name: MacPaw Way Ltd
                 Type: legacy daemon (0x10010)
          Disposition: [enabled, allowed, notified] (0xb)
                  URL: /Library/LaunchDaemons/com.macpaw.CleanMyMac-setapp.Agent.plist
      Executable Path: /Library/PrivilegedHelperTools/com.macpaw.CleanMyMac-setapp.Agent
             Last Use: 2026-10-22 19:02:37+01:00

========================
 Records for UID 501 : 0E263CA9
========================

 Items:

 #1:
                 Name: bash
       Developer Name: (null)
                 Type: legacy agent (0x10008)
          Disposition: [enabled, allowed, notified] (0xb)
                  URL: /Users/501/Library/LaunchAgents/com.josephgoksu.security-audit.plist
      Executable Path: /bin/bash

 #2:
                 Name: Cursor - background tasks
       Developer Name: Hilary Stout
                 Type: background tasks (0x2000)
          Disposition: [enabled, disallowed, notified, alerted] (0x29)
                  URL: (null)

 #3:
                 Name: Raycast
       Developer Name: Raycast Technologies Inc
                 Type: app (0x2)
          Disposition: [enabled, allowed, notified] (0xb)
                  URL: /Applications/Raycast.app
    Bundle Identifier: com.raycast.macos

 #4:
                 Name: Ghostty
                 Type: app (0x2)
          Disposition: [disabled, allowed, notified] (0xa)
                  URL: /Applications/Ghostty.app

 #5:
                 Name: RiversideHelper
       Developer Name: RIVERSIDEFM, INC
                 Type: login item (0x4)
          Disposition: [disabled, allowed, notified] (0xa)

 #6:
                 Name: ObsidianQuickLook.appex
                 Type: quicklook (0x800)
          Disposition: [enabled, allowed, notified] (0xb)
"""

@Test func parsesOnlyItemsThatRunInTheBackground() {
    let items = parseBTM(btmFixture)
    #expect(items.map(\.name) == ["com.macpaw.CleanMyMac-setapp.Agent", "bash", "Cursor - background tasks", "Raycast", "RiversideHelper"])
    let cmm = items[0]
    #expect(cmm.kind == .daemon && cmm.developer == "MacPaw Way Ltd" && cmm.status == .on && cmm.asRoot)
    #expect(cmm.executable == "/Library/PrivilegedHelperTools/com.macpaw.CleanMyMac-setapp.Agent")
    let audit = items[1]
    #expect(audit.kind == .agent && audit.developer == nil && audit.label == "com.josephgoksu.security-audit" && !audit.asRoot)
    #expect(items[2].kind == .backgroundTasks && items[2].status == .blocked && items[2].app == "Cursor")
    #expect(items[3].kind == .openAtLogin && items[3].url == "/Applications/Raycast.app" && items[3].status == .on)
    #expect(items[4].kind == .loginHelper && items[4].status == .off)
}

@Test func explanationFallsBackToTheKind() {
    let table = Explanations(entries: ["Raycast": .init(what: "Launcher.", advice: "Keep.")])
    let items = parseBTM(btmFixture)
    #expect(items[3].explain(table).what == "Launcher.")
    #expect(items[2].explain(table).what == "Lets Cursor run work while its window is closed: updates, sync, notifications.")
    #expect(items[0].explain(table).what.contains("as admin"))
}

@Test func matchesRunningGroupsWithoutGuessingInterpreters() {
    let items = parseBTM(btmFixture)
    let groups = [
        Group(name: "Raycast", bundle: "/Applications/Raycast.app", path: "/Applications/Raycast.app/Contents/MacOS/Raycast", rssKB: 85_000),
        Group(name: "Cursor", bundle: "/Applications/Cursor.app", path: "/x"),
        Group(name: "com.macpaw.CleanMyMac-setapp.Agent", path: "/Library/PrivilegedHelperTools/com.macpaw.CleanMyMac-setapp.Agent"),
        Group(name: "bash", path: "/bin/bash"),
    ]
    #expect(runningGroup(for: items[0], in: groups)?.name == "com.macpaw.CleanMyMac-setapp.Agent")
    #expect(runningGroup(for: items[1], in: groups) == nil)  // "bash" agent: can't tell which bash
    #expect(runningGroup(for: items[2], in: groups)?.name == "Cursor")
    #expect(runningGroup(for: items[3], in: groups)?.rssKB == 85_000)
    #expect(runningGroup(for: items[4], in: groups) == nil)
}

@Test func titleFollowsTheKeyThatMatched() {
    let setapp = BackgroundItem(name: "Setapp", kind: .agent, status: .on,
                                url: "/Users/501/Library/LaunchAgents/com.setapp.DesktopClient.SetappAgent.plist")
    let table = Explanations(entries: ["Setapp": .init(what: "w", advice: "a")])
    #expect(setapp.title(table) == "Setapp")
    #expect(parseBTM(btmFixture)[1].title(table) == "com.josephgoksu.security-audit")  // unknown "bash" agent: label beats name
    #expect(parseBTM(btmFixture)[2].title(table) == "Cursor")
    // Interpreter entries in the table must not name or explain an agent that merely runs through them.
    let shells = Explanations(entries: ["bash": .init(what: "A bash shell.", advice: "a", title: "Bash shell")])
    let agent = BackgroundItem(name: "bash", kind: .agent, status: .on, url: "/Users/me/Library/LaunchAgents/local.backup.plist")
    #expect(agent.title(shells) == "local.backup")
    #expect(agent.explain(shells).what.hasPrefix("Runs in the background"))
    #expect(isInterpreter("python3.12") && isInterpreter("zsh") && !isInterpreter("Setapp"))
}

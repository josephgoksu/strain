import Foundation
import Testing
@testable import Strain

@Test func shippedTableParsesAndHasNoBlanks() throws {
    let table = try Explanations.load(from: Explanations.repoFile)
    #expect(table.entries.count >= 25)
    for (name, e) in table.entries {
        #expect(!name.isEmpty && !e.what.isEmpty && !e.advice.isEmpty, "\(name)")
    }
    #expect(table[simulatorGroup] != nil && table["mediaanalysisd"] != nil)
    #expect(table["definitely-not-a-process"] == nil)
}

@Test func unknownsAreLoggedOnceEach() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("strain-\(UUID()).txt")
    defer { try? FileManager.default.removeItem(at: file) }
    let table = Explanations(entries: ["known": .init(what: "w", advice: "a")])
    let groups = ["known", "mystery", "other"].map { Group(name: $0, path: "/bin/\($0)") }
    table.logUnknowns(groups, to: file)
    table.logUnknowns(groups, to: file)
    #expect(try String(contentsOf: file, encoding: .utf8) == "mystery\t/bin/mystery\nother\t/bin/other\n")
}

@Test func titlesAreFriendlierAndFallBackToTheName() throws {
    let table = try Explanations.load(from: Explanations.repoFile)
    #expect(table.title("claude") == "Claude Code")
    #expect(table.title("mds_stores") == "Spotlight index")
    #expect(table.title("some-new-daemon") == "some-new-daemon")
    #expect(table.entries.values.allSatisfy { $0.title.map { !$0.isEmpty } ?? true })
}

@Test func reverseDNSNamesGetReadable() {
    let table = Explanations(entries: [:])
    #expect(table.title("com.macpaw.CleanMyMac-setapp.HealthMonitor") == "CleanMyMac-setapp HealthMonitor")
    #expect(table.title("node.js") == "node.js")
}

@Test func applesOwnServicesGetAGenericEntry() {
    let t = Explanations(entries: ["Dock": .init(what: "the Dock", advice: "x")])
    #expect(t.entry("Dock", path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")?.what == "the Dock")  // table wins
    #expect(t.entry("runningboardd", path: "/usr/libexec/runningboardd") == Explanations.macOSService)
    #expect(t.entry("x", path: "/System/Library/PrivateFrameworks/x") == Explanations.macOSService)
    #expect(t.entry("bluetoothd", path: "/usr/sbin/bluetoothd") == Explanations.macOSService)
    #expect(t.entry("launchd", path: "/sbin/launchd") == Explanations.macOSService)
    #expect(t.entry("node", path: "/opt/homebrew/bin/node") == nil)
    #expect(t.entry("gh", path: "gh") == nil)
    #expect(t.entry("tool", path: "/usr/local/bin/tool") == nil)
}

@Test func lookupIgnoresCaseAndVersions() {
    let t = Explanations(entries: ["python": .init(what: "py", advice: "a"), "node": .init(what: "js", advice: "a"), "claude": .init(what: "cli", advice: "a"),
                                   "Claude": .init(what: "app", advice: "a")])
    #expect(t["python3.12"]?.what == "py")
    #expect(t["Python"]?.what == "py")
    #expect(t["node22"]?.what == "js")
    #expect(t["Claude"]?.what == "app" && t["claude"]?.what == "cli")  // exact match wins
    #expect(t["pythonista"] == nil)
    let titled = Explanations(entries: ["python": .init(what: "py", advice: "a", title: "Python")])
    #expect(titled.title("python3.12") == "Python")  // title follows the same lookup as the entry
    #expect(Explanations.fold("1234") == "1234")
}

@Test func appsAreDescribedFromTheirInfoPlist() {
    let t = Explanations(entries: [:])
    #expect(Explanations.app(["LSApplicationCategoryType": "public.app-category.music"]).what == "A music app.")
    #expect(Explanations.app(["LSApplicationCategoryType": "public.app-category.utilities",
                              "NSHumanReadableCopyright": "Copyright © 2026 Tailscale Inc. All Rights Reserved."]).what == "A utility by Tailscale Inc.")
    #expect(Explanations.app([:]).what == "An app.")
    #expect(Explanations.vendor("© Raycast Technologies Ltd. 2019-2026. All Rights Reserved.") == "Raycast Technologies Ltd.")
    #expect(Explanations.vendor("© 2022–2026 Orbital Labs, LLC") == "Orbital Labs, LLC")
    #expect(Explanations.vendor("Copyright (c) 2024") == nil)
    #expect(t.entry("Notes", path: "/System/Applications/Notes.app/Contents/MacOS/Notes") == Explanations.appleApp)
    #expect(t.entry("Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder") == Explanations.macOSService)
    #expect(t.entry("Mystery", path: "/Applications/Mystery.app/Contents/MacOS/Mystery")?.what == "An app.")  // missing bundle still an app
    #expect(t.entry("pmtiles", path: "/opt/homebrew/bin/pmtiles") == nil)
}

@Test func shippedTableFollowsTheStyle() throws {
    let table = try Explanations.load(from: Explanations.repoFile)
    for (name, e) in table.entries {
        for text in [e.what, e.advice] {
            #expect(!text.contains("—") && !text.contains("–"), "\(name): no dashes")
            #expect(text.last.map { ".)!?".contains($0) } ?? false, "\(name): ends a sentence")
            #expect(text.count <= 160, "\(name): short")
        }
        // One entry per tool: no keys that fold to the same name ("python" vs "python3"), except case pairs like claude/Claude.
        let twins = table.entries.keys.filter { $0 != name && Explanations.fold($0) == Explanations.fold(name) && $0.lowercased() != name.lowercased() }
        #expect(twins.isEmpty, "\(name) ~ \(twins)")
    }
}

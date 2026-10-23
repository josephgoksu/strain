import Foundation
import Testing
@testable import Strain
import HelperKit

/// A fake home with a few cache folders. Never touches the real ~/Library.
func fakeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("strain-home-\(UUID())")
    let fm = FileManager.default
    for dir in ["Library/Caches/go-build/ab", "Library/Caches/com.spotify.client", "Library/Caches/com.apple.Safari",
                "Library/Caches/com.example.Idle", "Library/Caches/BraveSoftware", "Library/Caches/JetBrains", "Library/Developer/Xcode/DerivedData/App-x",
                "Documents"] {
        try fm.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    for file in ["Library/Caches/go-build/ab/obj", "Library/Caches/com.spotify.client/data", "Library/Caches/com.apple.Safari/db",
                 "Library/Caches/com.example.Idle/blob", "Library/Caches/BraveSoftware/cache", "Library/Developer/Xcode/DerivedData/App-x/build",
                 "Documents/precious.txt"] {
        try Data(repeating: 7, count: 50_000).write(to: home.appendingPathComponent(file))
    }
    return home
}

@Test func removesContentsButKeepsTheFolder() throws {
    let home = try fakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let dir = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    let left = try Cleanup.removeContents(of: dir, home: home.path)
    #expect(left == 0)
    #expect(FileManager.default.fileExists(atPath: dir.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

@Test func neverFollowsSymlinksOut() throws {
    let home = try fakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let dir = home.appendingPathComponent("Library/Caches/go-build")
    try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: home.appendingPathComponent("Documents"))
    _ = try Cleanup.removeContents(of: dir, home: home.path)
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents/precious.txt").path))
}

@Test func refusesAnythingOutsideTheAllowlist() throws {
    let home = try fakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    for bad in ["", "Documents", "Library", "Library/Caches", "Library/Caches/../../Documents", "Library/Caches/com.apple.Safari"] {
        #expect(throws: Cleanup.Refused.self) { try Cleanup.removeContents(of: home.appendingPathComponent(bad), home: home.path) }
    }
    #expect(throws: Cleanup.Refused.self) { try Cleanup.removeContents(of: URL(fileURLWithPath: "/"), home: home.path) }
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents/precious.txt").path))
}

@Test func appCachesSkipAppleRunningAppsAndSeparateItems() throws {
    let home = try fakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let running = [RunningApp(name: "Spotify", bundleID: "com.spotify.client"), RunningApp(name: "Brave Browser", bundleID: "com.brave.Browser"),
                   RunningApp(name: "GoLand", bundleID: "com.jetbrains.goland"), RunningApp(name: "Finder", bundleID: "com.apple.finder")]
    let folders = Cleanup.appCacheFolders(home: home.path, running: running).map(\.lastPathComponent)
    // not com.apple.*, not go-build (own item), not Spotify, Brave or GoLand's JetBrains folder (running)
    #expect(folders == ["com.example.Idle"])
    #expect(Cleanup.appCacheFolders(home: home.path, running: []).map(\.lastPathComponent).contains("JetBrains"))
}

@Test func sizesCountAllocatedBytes() throws {
    let home = try fakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(Cleanup.size(of: home.appendingPathComponent("Library/Caches/go-build")) >= 50_000)
    #expect(Cleanup.size(of: home.appendingPathComponent("missing")) == 0)
}

@Test func everyFixedItemIsInsideTheAllowlist() {
    for item in Cleanup.items {
        if case .folder(let rel) = item.kind {
            #expect(Cleanup.allowed(URL(fileURLWithPath: "/Users/x/" + rel), home: "/Users/x"), "\(item.id)")
        }
    }
}

@Test func adminTilesMatchWhatTheHelperRuns() {
    for a in QuickAction.all where a.admin {
        #expect(!a.command.contains("\"") && !a.command.contains("\\"), "\(a.id)")  // password-sheet fallback literal
        #expect(a.command == HelperKit.shell(a.id) && !a.command.isEmpty, "\(a.id)")  // same commands either way
    }
    #expect(Set(QuickAction.all.filter(\.admin).map(\.id)) == Set(HelperKit.actions.keys))
    #expect(Set(QuickAction.all.map(\.id)).count == QuickAction.all.count)
}

@Test func helperTrustsOnlyOurTeam() throws {
    #expect(HelperKit.appRequirement == "identifier \"com.josephgoksu.strain\" and anchor apple generic and certificate leaf[subject.OU] = \"J9GF96BYUX\"")
    var req: SecRequirement?
    #expect(SecRequirementCreateWithString(HelperKit.appRequirement as CFString, [], &req) == errSecSuccess)
    #expect(SecRequirementCreateWithString(HelperKit.helperRequirement as CFString, [], &req) == errSecSuccess)
    // The daemon plist launchd reads: runs the binary build.sh ships, on the Mach service the app connects to.
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Helper/" + HelperKit.plist)
    let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
    #expect(plist["Label"] as? String == HelperKit.label)
    #expect(plist["BundleProgram"] as? String == "Contents/MacOS/StrainHelper")
    #expect((plist["MachServices"] as? [String: Bool])?[HelperKit.label] == true)
    #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["com.josephgoksu.strain"])
}

@Test func exitStatusReportsFailure() {
    #expect(exitStatus("/bin/sh", ["-c", "true"]) == 0)
    #expect(exitStatus("/bin/sh", ["-c", "exit 3"]) == 3)
    #expect(exitStatus("/nonexistent", []) == -1)
}

@Test func cleaningAnItemEmptiesItsFolderAndReportsWhatStayed() throws {
    let home = try fakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let go = Cleanup.items.first { $0.id == "go" }!
    #expect(Cleanup.clean(go, home: home.path, running: []) == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Library/Caches/go-build").path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/com.example.Idle/blob").path))  // other items untouched
    // Read-only folders (Go's module cache) are made writable and go too.
    let readOnly = home.appendingPathComponent("Library/Caches/go-build/mod")
    try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
    try Data([1]).write(to: readOnly.appendingPathComponent("f"))
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
    #expect(Cleanup.clean(go, home: home.path, running: []) == 0)
    // What can't be deleted at all (here: a locked file) is counted, not hidden.
    let locked = home.appendingPathComponent("Library/Caches/go-build/locked")
    try Data([1]).write(to: locked)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
    #expect(Cleanup.clean(go, home: home.path, running: []) == 1)
}

@Test func hungToolsAreKilled() {
    let start = Date.now
    _ = run("/bin/sleep", ["30"], timeout: 1)
    #expect(Date.now.timeIntervalSince(start) < 5)
}

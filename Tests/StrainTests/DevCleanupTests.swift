import Foundation
import Testing
@testable import Strain

/// A fake dev root: a JS app, a Rust crate, a stray "target" with no Cargo.toml, a symlinked node_modules.
func fakeDevRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("strain-dev-\(UUID())")
    let fm = FileManager.default
    for dir in ["web/node_modules/react", "web/.next/cache", "web/src", "crate/target/debug", "docs/target", "web/.git/objects", "other/src"] {
        try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    for file in ["web/package.json", "web/node_modules/react/index.js", "web/.next/cache/x", "crate/Cargo.toml", "crate/target/debug/bin",
                 "docs/target/page.html", "web/src/app.ts"] {
        try Data(repeating: 1, count: 20_000).write(to: root.appendingPathComponent(file))
    }
    try fm.createSymbolicLink(at: root.appendingPathComponent("other/node_modules"), withDestinationURL: root.appendingPathComponent("web/src"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("other/package.json"))
    return root
}

@Test func findsBuildFoldersOnlyBesideTheirManifest() throws {
    let root = try fakeDevRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let projects = DevCleanup.scan(roots: [root.path])
    let names = Dictionary(uniqueKeysWithValues: projects.map { (($0.path as NSString).lastPathComponent, Set($0.artifacts.map(\.name))) })
    #expect(names == ["web": ["node_modules", ".next"], "crate": ["target"]])  // docs/target has no Cargo.toml; other/node_modules is a symlink
    #expect(projects.allSatisfy { $0.size >= 20_000 })
}

@Test func deletesOnlyAllowedBuildFolders() throws {
    let root = try fakeDevRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let web = DevCleanup.scan(roots: [root.path]).first { $0.path.hasSuffix("/web") }!
    #expect(DevCleanup.remove(web.artifacts, roots: [root.path]) == 0)
    let fm = FileManager.default
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("web/node_modules").path))
    #expect(fm.fileExists(atPath: root.appendingPathComponent("web/src/app.ts").path))
    // Anything that isn't a build folder beside its manifest is refused, even if handed over directly.
    let forged = [Artifact(path: root.appendingPathComponent("web/src").path, size: 1),
                  Artifact(path: root.appendingPathComponent("docs/target").path, size: 1),
                  Artifact(path: root.appendingPathComponent("other/node_modules").path, size: 1),
                  Artifact(path: "/tmp/node_modules", size: 1)]
    #expect(DevCleanup.remove(forged, roots: [root.path]) == 4)
    #expect(fm.fileExists(atPath: root.appendingPathComponent("docs/target/page.html").path))
    #expect(fm.fileExists(atPath: root.appendingPathComponent("web/src/app.ts").path))
}

@Test func lastActiveCountsGitInstallsAndBuilds() throws {
    let root = try fakeDevRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let web = root.appendingPathComponent("web"), fm = FileManager.default
    func age() throws {
        for p in ["", "package.json", "node_modules", ".next", "src", ".git"] {
            try fm.setAttributes([.modificationDate: Date.now - 90 * 86400], ofItemAtPath: web.appendingPathComponent(p).path)
        }
    }
    func stale() -> Bool { DevProject(path: "", artifacts: [], lastActive: DevCleanup.lastActive(web.path)).stale() }
    try age()
    #expect(stale())
    try Data().write(to: web.appendingPathComponent(".git/index"))              // git status / commit
    #expect(!stale())
    try fm.removeItem(at: web.appendingPathComponent(".git/index"))
    try age()
    #expect(stale())
    try Data().write(to: web.appendingPathComponent("node_modules/.package-lock.json"))  // npm install
    #expect(!stale())
}

@Test func parsesSimctlDevices() {
    let json = """
    {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
      {"udid": "A", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true, "dataPathSize": 4800000000, "lastUsedAt": "2026-10-19T16:46:52Z"},
      {"udid": "B", "name": "iPad mini", "state": "Booted", "isAvailable": true, "dataPathSize": 17000000}],
     "com.apple.CoreSimulator.SimRuntime.watchOS-11-2": [{"udid": "C", "name": "Watch", "state": "Shutdown", "isAvailable": false}]}}
    """
    let sims = DevCleanup.parseSimulators(Data(json.utf8))
    #expect(sims.map(\.udid) == ["A", "B", "C"])
    #expect(sims[0].runtime == "iOS 27.0" && sims[0].size == 4_800_000_000 && sims[0].lastUsed != nil && !sims[0].booted)
    #expect(sims[1].booted && sims[2].runtime == "watchOS 11.2" && !sims[2].available)
    #expect(DevCleanup.parseSimulators(Data("nope".utf8)).isEmpty)
}

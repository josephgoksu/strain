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

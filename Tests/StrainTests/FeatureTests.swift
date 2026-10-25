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

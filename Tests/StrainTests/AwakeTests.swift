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

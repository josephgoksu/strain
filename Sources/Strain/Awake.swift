import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keep awake: one IOKit power assertion while a session runs. macOS drops it if Strain quits or crashes, so nothing
/// outlives the app (unlike a stray `caffeinate`). Closing the lid still sleeps a laptop; assertions can't stop that.
enum Awake {
    static let durations: [(title: String, minutes: Int?)] = [
        ("Indefinitely", nil), ("10 Minutes", 10), ("30 Minutes", 30), ("1 Hour", 60),
        ("2 Hours", 120), ("4 Hours", 240), ("8 Hours", 480), ("12 Hours", 720),
    ]

    /// Which assertion to hold right now, or nil for none. Display-sleep prevention also keeps the system up.
    static func type(on: Bool, locked: Bool, letDisplaySleep: Bool, letLockedSleep: Bool) -> String? {
        guard on, !(locked && letLockedSleep) else { return nil }
        return letDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
    }

    private nonisolated(unsafe) static var id = IOPMAssertionID(0), held: String?

    /// Holds `type` (switching if another is held), or releases with nil. Main thread only.
    static func hold(_ type: String?) {
        guard type != held else { return }
        if held != nil { IOPMAssertionRelease(id) }
        held = nil
        guard let type,
              IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "Strain: keep awake" as CFString, &id) == kIOReturnSuccess else { return }
        held = type
    }

    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue
    }
}

import Foundation
import Testing
@testable import Strain
import HelperKit

@Test func autoHoldsOnlyWhileALatencyAppIsInFront() {
    let mail = AWDL.App(bundleID: "com.apple.mail", name: "Mail", category: "public.app-category.productivity")
    let gfn = AWDL.App(bundleID: "com.nvidia.gfnpc.mall", name: "GeForce NOW", category: nil)
    let chess = AWDL.App(bundleID: "com.example.chess", name: "Chess Pro", category: "public.app-category.board-games")
    let steamGame = AWDL.App(bundleID: "com.example.hades", name: "Hades", category: nil,
                             path: "/Users/me/Library/Application Support/Steam/steamapps/common/Hades/Hades.app")
    #expect(!AWDL.decide(.auto, front: mail, pausedUntil: nil).hold)  // Zoom or Steam open behind it doesn't count
    #expect(!AWDL.decide(.auto, front: nil, pausedUntil: nil).hold)
    #expect(AWDL.decide(.auto, front: gfn, pausedUntil: nil) == AWDLDecision(hold: true, reason: "AirDrop paused for low ping while GeForce NOW is in front. It comes back when you switch away."))
    #expect(AWDL.decide(.auto, front: chess, pausedUntil: nil).hold && AWDL.decide(.auto, front: steamGame, pausedUntil: nil).hold)
    #expect(AWDL.decide(.lowLatency, front: nil, pausedUntil: nil).hold)
    #expect(!AWDL.decide(.normal, front: gfn, pausedUntil: nil).hold)
}

@Test func allowAirDropPausesTheHold() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(!AWDL.decide(.lowLatency, front: nil, pausedUntil: now + 600, now: now).hold)
    #expect(AWDL.decide(.lowLatency, front: nil, pausedUntil: now - 1, now: now).hold)
}

@Test(.enabled(if: Radios.wifiDevice != nil, "no Wi-Fi hardware (CI runners)"))
func readsTheAWDLInterface() {
    #expect(HelperKit.awdlIsUp() != nil)  // every Mac with Wi-Fi has awdl0; read-only
}

/// The root helper's decision each second: down while held, up exactly once when the last hold goes, and up at start
/// when a crashed helper left its marker (it starts with held = true).
@Test func helperGivesAirDropBackWhenTheHoldEnds() {
    var g = AWDLGuard(held: false)
    #expect(g.step(holding: false, linkUp: true) == .none)  // never touches a link it doesn't hold
    #expect(g.step(holding: true, linkUp: true) == .down)
    #expect(g.step(holding: true, linkUp: false) == .none)  // already down: no spawn
    #expect(g.step(holding: true, linkUp: true) == .down)   // macOS raised it again
    #expect(g.step(holding: false, linkUp: false) == .up)
    #expect(g.step(holding: false, linkUp: true) == .none && !g.held)
    var restarted = AWDLGuard(held: true)
    #expect(restarted.step(holding: false, linkUp: false) == .up)
}

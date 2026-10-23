import Foundation
import Testing
@testable import Strain

let calm = SystemSample(pressure: 1, swapUsedMB: 500, swapTotalMB: 1024, load: 3, cores: 10, memUsedMB: 9000, memTotalMB: 18432)
// 2026-10-22 screenshot: swap 3.2 of 4.0 GB but pressure normal and nothing swapping. Not strain.
let oldSwap = SystemSample(pressure: 1, swapUsedMB: 3277, swapTotalMB: 4096, load: 2.8, cores: 11, memUsedMB: 14000, memTotalMB: 18432)
let critical = SystemSample(pressure: 4, swapUsedMB: 6100, swapTotalMB: 7168, load: 3, cores: 10, memUsedMB: 17500, memTotalMB: 18432)
let busy = SystemSample(pressure: 1, swapUsedMB: 500, swapTotalMB: 4096, load: 25, cores: 10, memUsedMB: 9000, memTotalMB: 18432)
let sim = Group(name: simulatorGroup, path: "/x", cpu: 310, rssKB: 4_200_000)
let photos = Group(name: "mediaanalysisd", path: "/y", cpu: 99, rssKB: 160_000)
let t0 = Date(timeIntervalSince1970: 0)

@Test func instantLevelReadsEachSymptom() {
    #expect(assess(calm, swapRate: 0, [photos], hogs: []).level == .green)
    #expect(assess(oldSwap, swapRate: 0, [photos], hogs: []).level == .green)
    #expect(assess(critical, swapRate: 0, [], hogs: []) == Assessment(level: .red, reason: "Memory pressure is critical", memory: true))
    #expect(assess(calm, swapRate: 80, [], hogs: []) == Assessment(level: .amber, reason: "Swapping to disk: 80 MB/min", memory: true))
    #expect(assess(calm, swapRate: 400, [], hogs: []).level == .red)
    var warn = calm; warn.pressure = 2
    #expect(assess(warn, swapRate: 0, [], hogs: []) == Assessment(level: .amber, reason: "Memory pressure is high", memory: true))
    #expect(assess(warn, swapRate: 80, [], hogs: []).level == .red)
    var hugeSwap = calm; hugeSwap.swapUsedMB = 10_000
    #expect(assess(hugeSwap, swapRate: 0, [], hogs: []) == Assessment(level: .amber, reason: "9.8 GB swapped out, over half your RAM", memory: true))
    #expect(assess(busy, swapRate: 0, [photos], hogs: []) == Assessment(level: .amber, reason: "CPU overloaded: load 25 on 10 cores", memory: false))
    #expect(assess(calm, swapRate: 0, [photos], hogs: ["mediaanalysisd"]) == Assessment(level: .amber, reason: "mediaanalysisd busy for 30+ min", memory: false))
    #expect(assess(calm, swapRate: 0, [photos], hogs: ["mediaanalysisd"], title: { _ in "Photos analysis" }).reason == "Photos analysis busy for 30+ min")
}

@Test func swapRateComesFromTheSwapOutCounter() {
    var m = Monitor()
    var s = calm
    _ = m.step(s, [], at: t0)
    s.swapOutMB = 50  // 50 MB in 10 s = 300 MB/min
    _ = m.step(s, [], at: t0 + 10)
    #expect(m.swapRate == 300)
}

@Test func aSpikeIsIgnored() {
    var m = Monitor()
    #expect(m.step(critical, [sim], at: t0) == nil)
    #expect(m.step(calm, [sim], at: t0 + 10) == nil)
    #expect(m.step(critical, [sim], at: t0 + 20) == nil)
    #expect(m.level == .green)
}

@Test func sustainedPressureNotifiesOnceNamingTheMemoryHog() {
    var m = Monitor()
    #expect(m.step(critical, [photos, sim], at: t0) == nil)
    #expect(m.step(critical, [photos, sim], at: t0 + 10) == nil)
    #expect(m.step(critical, [photos, sim], at: t0 + 20) == Notice(level: .red, reason: "Memory pressure is critical", culprit: simulatorGroup))
    #expect(m.level == .red && m.since == t0 + 20)
    #expect(m.step(critical, [photos, sim], at: t0 + 30) == nil)
}

@Test func cooldownHoldsPerCulprit() {
    var m = Monitor()
    for i in 0..<3 { _ = m.step(critical, [sim], at: t0 + Double(i) * 10) }
    for i in 3..<6 { _ = m.step(calm, [sim], at: t0 + Double(i) * 10) }
    #expect(m.level == .green)
    var fired: Notice?
    for i in 6..<9 { fired = m.step(critical, [sim], at: t0 + Double(i) * 10) ?? fired }
    #expect(fired == nil)  // same culprit within 30 min
    for i in 9..<12 { _ = m.step(calm, [sim], at: t0 + 2000 + Double(i) * 10) }
    for i in 12..<15 { fired = m.step(critical, [sim], at: t0 + 2000 + Double(i) * 10) ?? fired }
    #expect(fired?.culprit == simulatorGroup)
}

@Test func aGroupBusyForHalfAnHourBecomesAmber() {
    var m = Monitor()
    var fired: Notice?
    for i in 0...183 { fired = m.step(calm, [photos], at: t0 + Double(i) * 10) ?? fired }
    #expect(m.level == .amber)
    #expect(fired == Notice(level: .amber, reason: "mediaanalysisd busy for 30+ min", culprit: "mediaanalysisd"))
}

@Test func samplesFasterThanTheIntervalAreIgnored() {
    var m = Monitor()
    var s = calm
    _ = m.step(critical, [sim], at: t0)
    _ = m.step(critical, [sim], at: t0 + 0.5)   // manual refresh
    _ = m.step(critical, [sim], at: t0 + 1)     // refresh after Quit
    #expect(m.level == .green)                   // three samples in 1 s must not count as a 30 s hold
    s.swapOutMB = 1
    _ = m.step(s, [], at: t0 + 1.5)
    #expect(m.swapRate == 0)                     // 1 MB in 0.5 s is not 120 MB/min
}

@Test func aNearlyFullDiskIsStrain() {
    var low = calm
    low.diskFreeMB = 8 * 1024
    #expect(assess(low, swapRate: 0, [], hogs: []) == Assessment(level: .amber, reason: "Disk nearly full: 8 GB free", memory: false, disk: true))
    low.diskFreeMB = 2 * 1024
    #expect(assess(low, swapRate: 0, [], hogs: []).level == .red)
    // The notice blames no app: the busiest one didn't fill the disk.
    var m = Monitor()
    var fired: Notice?
    for i in 0..<3 { fired = m.step(low, [sim], at: t0 + Double(i) * 10) ?? fired }
    #expect(fired == Notice(level: .red, reason: "Disk almost full: 2.0 GB free", culprit: nil))
}

@Test func easingShowsWhileALowerLevelHolds() {
    var m = Monitor()
    let t0 = Date(timeIntervalSince1970: 0)
    for i in 0..<3 { _ = m.step(critical, [], at: t0 + Double(i) * 10) }
    #expect(m.level == .red && !m.easing)
    _ = m.step(calm, [], at: t0 + 30)
    #expect(m.level == .red && m.easing)
}

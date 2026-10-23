import Testing
@testable import Strain

@Test func coreUsageIsBusyOverElapsedTicks() {
    let old = [CoreTicks(busy: 100, idle: 900), CoreTicks(busy: 0, idle: 0), CoreTicks(busy: UInt32.max - 9, idle: 10)]
    let new = [CoreTicks(busy: 150, idle: 950), CoreTicks(busy: 0, idle: 0), CoreTicks(busy: 30, idle: 20)]
    #expect(coreUsage(old, new) == [0.5, 0, 0.8])  // third core's counter wrapped: 40 busy of 50
    #expect(coreUsage(old, Array(new.prefix(2))).isEmpty)
}

@Test func liveReadingsAreSane() {
    let t = CPUTopology.current
    #expect(t.performance + t.efficiency == readCoreTicks().count)
    let m = SystemSample.read().memory
    #expect(m.totalMB > 0 && m.appMB > 0 && m.wiredMB > 0)
    #expect(m.appMB + m.wiredMB + m.compressedMB + m.cachedMB + m.freeMB >= m.totalMB * 0.99)
}

@Test func freeMemoryNeverGoesNegative() {
    #expect(MemoryBreakdown(appMB: 10, wiredMB: 10, cachedMB: 10, totalMB: 20).freeMB == 0)
}

@Test func findsTheWiFiDevice() {
    let ports = "Hardware Port: Ethernet\nDevice: en5\nEthernet Address: x\n\nHardware Port: Wi-Fi\nDevice: en0\nEthernet Address: y\n"
    #expect(Radios.parseWiFiDevice(ports) == "en0")
    #expect(Radios.parseWiFiDevice("Hardware Port: Ethernet\nDevice: en5\n") == nil)
}

@Test(.enabled(if: Radios.wifiDevice != nil, "no Wi-Fi hardware (CI runners)"))
func readsWiFiPower() {
    #expect(Radios.wifiOn() != nil)  // read-only: never switches anything
}

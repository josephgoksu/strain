import Testing
@testable import Strain

@Test func ddcPacketsCarryTheChecksum() {
    #expect(DDC.readPacket(0x10) == [0x82, 0x01, 0x10, 0xAC])  // 0x6E ^ 0x51 ^ every byte
    #expect(DDC.writePacket(0x62, 300) == [0x84, 0x03, 0x62, 0x01, 0x2C, 0xF7])
}

@Test func ddcRepliesParseOnlyWhenIntact() {
    var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x42, 0]
    reply[10] = reply[0..<10].reduce(0x50, ^)
    #expect(DDC.parseReply(reply, vcp: 0x10)! == (66, 100))
    #expect(DDC.parseReply(reply, vcp: 0x62) == nil)  // answer to another code
    var unsupported = reply
    unsupported[3] = 1
    #expect(DDC.parseReply(unsupported, vcp: 0x10) == nil)
    reply[9] = 0x43
    #expect(DDC.parseReply(reply, vcp: 0x10) == nil)  // bad checksum
}

@Test func mediaKeysDecode() {
    let up = MediaKey(data1: 2 << 16 | 0x0A00), release = MediaKey(data1: 1 << 16 | 0x0B00)
    #expect(up?.kind == .brightnessUp && up?.down == true)
    #expect(release?.kind == .volumeDown && release?.down == false)
    #expect(MediaKey(data1: 16 << 16 | 0x0A00) == nil)  // play/pause stays with macOS
    #expect(MediaKey(keyCode: 113, down: true)?.kind == .brightnessUp && MediaKey(keyCode: 107, down: false)?.kind == .brightnessDown)
    #expect(MediaKey(keyCode: 0, down: true) == nil)  // "a" and every other key pass through
}

@Test func keysStepOnTheGrid() {
    #expect(Displays.step(0.66, up: true, fine: false) == 0.75)  // snaps to 11/16 first, then one step
    #expect(Displays.step(0.66, up: false, fine: false) == 0.625)
    #expect(Displays.step(0.5, up: true, fine: true) == 0.5 + 1.0 / 64)
    #expect(Displays.step(0.02, up: false, fine: false) == 0 && Displays.step(1, up: true, fine: false) == 1)
}

@Test func aFailedOrRacedReadKeepsTheShownLevel() {
    let old = [Screen(id: 3, name: "Dell", ddc: true, brightness: 0.66, volume: 0.12, muted: true)]
    let failed = Displays.merge([Screen(id: 3, name: "Dell", ddc: true, brightness: nil, volume: nil)], old: old, touched: [])
    #expect(failed[0].brightness == 0.66 && failed[0].volume == 0.12 && failed[0].muted)
    let raced = Displays.merge([Screen(id: 3, name: "Dell", ddc: true, brightness: 0.4, volume: 0.5)], old: old, touched: ["3.16"])
    #expect(raced[0].brightness == 0.66 && raced[0].volume == 0.5)  // 16 = VCP 0x10, set by a slider mid-read
}

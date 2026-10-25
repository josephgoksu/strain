import AppKit
import AudioToolbox
import CoreGraphics
import IOKit
import os

/// One screen's controls. Built-in and Apple displays go through DisplayServices (what Control Center uses); other
/// external displays through DDC/CI over I2C, the monitor's own brightness and speaker settings.
struct Screen: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let ddc: Bool                // false = DisplayServices (brightness only)
    var brightness: Double?      // 0...1; nil = can't be read or set
    var volume: Double?          // DDC speakers only
    var muted = false
}

enum VCP: UInt8 { case brightness = 0x10, volume = 0x62, mute = 0x8D }  // DDC/CI "VCP" codes (MCCS)

/// DDC/CI over Apple silicon's IOAVService: no install, no root. Every call blocks
/// for ~50 ms and the bus takes one command at a time, so all I/O runs on one serial queue.
enum DDC {
    // MARK: Packets (pure, tested)

    /// Get VCP: length byte, opcode 0x01, code, checksum over the host (0x6E) and source (0x51) addresses.
    static func readPacket(_ vcp: UInt8) -> [UInt8] { sealed([0x82, 0x01, vcp]) }

    /// Set VCP: opcode 0x03, code, value high, value low.
    static func writePacket(_ vcp: UInt8, _ value: UInt16) -> [UInt8] { sealed([0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]) }

    private static func sealed(_ p: [UInt8]) -> [UInt8] { p + [p.reduce(0x6E ^ 0x51, ^)] }

    /// The 11-byte VCP reply: [0x6E, 0x88, 0x02, result, code, type, max hi, max lo, cur hi, cur lo, checksum].
    /// Checksum seed 0x50 is the monitor's reply address.
    static func intact(_ r: [UInt8], vcp: UInt8) -> Bool {
        r.count == 11 && r[2] == 0x02 && r[4] == vcp && r[0..<10].reduce(0x50, ^) == r[10]
    }

    /// nil on a garbled, mismatched or "unsupported" reply.
    static func parseReply(_ r: [UInt8], vcp: UInt8) -> (current: Int, max: Int)? {
        guard intact(r, vcp: vcp), r[3] == 0 else { return nil }
        let max = Int(r[6]) << 8 | Int(r[7])
        return max > 0 ? (Int(r[8]) << 8 | Int(r[9]), max) : nil
    }

    // MARK: I/O

    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private nonisolated(unsafe) static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let create = dlsym(iokit, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: Create.self) }
    private static let writeI2C = dlsym(iokit, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: I2C.self) }
    private static let readI2C = dlsym(iokit, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: I2C.self) }

    static let queue = DispatchQueue(label: "strain.ddc", qos: .userInitiated)
    private nonisolated(unsafe) static var services: [CGDirectDisplayID: CFTypeRef] = [:]  // touched on `queue` only
    private nonisolated(unsafe) static var maxima: [String: Int] = [:]                       // "display.vcp" → max, `queue` only

    /// Pairs each external display with its I2C service. In the registry an external display's framebuffer
    /// (IOMobileFramebufferShim, carrying the EDID vendor/product/serial) comes just before its DCPAVServiceProxy.
    /// Call on `queue`.
    static func attach(_ displays: [CGDirectDisplayID]) {
        guard let create else { return }
        var pairs: [(vendor: Int, model: Int, serial: Int, service: CFTypeRef)] = []
        var it = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var attrs: [String: Any]?
        while case let entry = IOIteratorNext(it), entry != 0 {
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &name)
            switch String(cString: name) {
            case "IOMobileFramebufferShim":
                let display = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any]
                attrs = display?["ProductAttributes"] as? [String: Any]
            case "DCPAVServiceProxy":
                defer { attrs = nil }  // a framebuffer's EDID belongs to the proxy right after it, paired or not
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String
                guard location == "External", let a = attrs, let s = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                pairs.append((a["LegacyManufacturerID"] as? Int ?? 0, a["ProductID"] as? Int ?? 0, a["SerialNumber"] as? Int ?? 0, s))
            default: break
            }
        }
        services = [:]
        for d in displays {
            let match = pairs.first { $0.vendor == Int(CGDisplayVendorNumber(d)) && $0.model == Int(CGDisplayModelNumber(d)) && $0.serial == Int(CGDisplaySerialNumber(d)) }
                ?? (displays.count == 1 && pairs.count == 1 ? pairs[0] : nil)  // ponytail: EDIDs without a serial, one screen only
            if let match { services[d] = match.service }
        }
    }

    static func has(_ display: CGDirectDisplayID) -> Bool { services[display] != nil }

    /// Monitors drop DDC replies now and then; four tries rides that out. Call on `queue`.
    static func read(_ display: CGDirectDisplayID, _ vcp: VCP) -> (current: Int, max: Int)? {
        guard let s = services[display], let writeI2C, let readI2C else { return nil }
        var packet = readPacket(vcp.rawValue)
        for _ in 0..<4 {
            _ = packet.withUnsafeMutableBytes { writeI2C(s, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            usleep(50_000)  // the monitor needs ~40 ms to answer
            var reply = [UInt8](repeating: 0, count: 11)
            guard reply.withUnsafeMutableBytes({ readI2C(s, 0x37, 0x51, $0.baseAddress!, 11) }) == kIOReturnSuccess,
                  intact(reply, vcp: vcp.rawValue) else { continue }
            let r = parseReply(reply, vcp: vcp.rawValue)  // nil = the monitor says it lacks this code; asking again won't change that
            if let r { maxima["\(display).\(vcp.rawValue)"] = r.max }
            return r
        }
        return nil
    }

    /// Call on `queue`.
    static func write(_ display: CGDirectDisplayID, _ vcp: VCP, raw: UInt16) {
        guard let s = services[display], let writeI2C else { return }
        var packet = writePacket(vcp.rawValue, raw)
        _ = packet.withUnsafeMutableBytes { writeI2C(s, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
        usleep(20_000)  // DDC/CI wants a gap between commands
    }

    private static let pending = OSAllocatedUnfairLock(initialState: [String: (CGDirectDisplayID, VCP, Double)]())

    /// Writes `fraction` (0...1) of the code's maximum (100 when never read). Fire and forget: a slider drag sends dozens
    /// of values; only the latest per display and code is written.
    static func set(_ display: CGDirectDisplayID, _ vcp: VCP, _ fraction: Double) {
        let key = "\(display).\(vcp.rawValue)"
        let first = pending.withLock { p in
            defer { p[key] = (display, vcp, fraction) }
            return p[key] == nil
        }
        guard first else { return }
        queue.async {
            guard let (d, v, f) = pending.withLock({ $0.removeValue(forKey: key) }) else { return }
            if v == .mute { write(d, v, raw: f > 0 ? 1 : 2); return }  // MCCS mute: 1 = on, 2 = off
            write(d, v, raw: UInt16((Double(maxima[key] ?? 100) * f).rounded()))
        }
    }
}

/// Brightness for the built-in display and Apple displays, through the private DisplayServices framework.
enum Native {
    private nonisolated(unsafe) static let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let canChange = dlsym(ds, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: (@convention(c) (UInt32) -> Bool).self) }
    private static let get = dlsym(ds, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32).self) }
    private static let setter = dlsym(ds, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: (@convention(c) (UInt32, Float) -> Int32).self) }

    static func brightness(_ d: CGDirectDisplayID) -> Double? {
        guard canChange?(d) == true, let get else { return nil }
        var v: Float = 0
        return get(d, &v) == 0 ? Double(v) : nil
    }

    static func setBrightness(_ d: CGDirectDisplayID, _ v: Double) { _ = setter?(d, Float(v)) }  // v: 0...1
}

enum Displays {
    /// NSScreen is main-thread only, so the caller lists them and `read` (off the main thread) does the slow part.
    @MainActor static func list() -> [(CGDirectDisplayID, String)] {
        NSScreen.screens.compactMap { s in (s.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID).map { ($0, s.localizedName) } }
    }

    /// Every screen with something to control, DDC values read fresh. Blocks up to ~1 s per external display.
    static func read(_ screens: [(CGDirectDisplayID, String)]) -> [Screen] {
        DDC.queue.sync {
            let native = Dictionary(screens.compactMap { id, _ in Native.brightness(id).map { (id, $0) } }, uniquingKeysWith: { a, _ in a })
            DDC.attach(screens.map(\.0).filter { CGDisplayIsBuiltin($0) == 0 && native[$0] == nil })
            return screens.compactMap { id, name in
                if let b = native[id] { return Screen(id: id, name: name, ddc: false, brightness: b) }
                guard DDC.has(id) else { return nil }
                let frac = { (r: (current: Int, max: Int)?) in r.map { min(Double($0.current) / Double($0.max), 1) } }
                return Screen(id: id, name: name, ddc: true, brightness: frac(DDC.read(id, .brightness)),
                              volume: frac(DDC.read(id, .volume)))  // ponytail: mute isn't read; monitors misreport it (a Dell read "muted" while playing)
            }
        }
    }

    /// Keeps what Strain had where the fresh read failed (a monitor still waking drops DDC replies) or a slider or
    /// key changed the level while the read was in flight (`touched`: "display.vcp").
    static func merge(_ fresh: [Screen], old: [Screen], touched: Set<String>) -> [Screen] {
        fresh.map { new in
            guard let was = old.first(where: { $0.id == new.id }) else { return new }
            var s = new
            if s.brightness == nil || touched.contains("\(s.id).\(VCP.brightness.rawValue)") { s.brightness = was.brightness }
            if s.volume == nil || touched.contains("\(s.id).\(VCP.volume.rawValue)") { s.volume = was.volume }
            s.muted = was.muted  // never read from the monitor
            return s
        }
    }

    /// One key press: snaps to the step grid, then moves one step (1/16 like macOS, 1/64 with ⇧⌥).
    static func step(_ v: Double, up: Bool, fine: Bool) -> Double {
        let step = fine ? 1.0 / 64 : 1.0 / 16
        return min(max(((v / step).rounded() + (up ? 1 : -1)) * step, 0), 1)
    }

    /// The screen under the pointer.
    static func underPointer() -> CGDirectDisplayID? {
        let p = CGEvent(source: nil)?.location ?? .zero
        var id: CGDirectDisplayID = 0, n: UInt32 = 0
        return CGGetDisplaysWithPoint(p, 1, &id, &n) == .success && n > 0 ? id : nil
    }

    /// The default output's volume is settable (built-in speakers, AirPods): macOS keeps the volume keys. HDMI and
    /// DisplayPort audio has none, which is when the keys go to the monitor's speakers instead.
    static func outputHasVolume() -> Bool {
        var device = AudioObjectID(), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return true }
        addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &addr) && AudioHardwareServiceIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    @MainActor static func monitorControlRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "app.monitorcontrol.MonitorControl").isEmpty
    }
}

/// A media key from an NX_SYSDEFINED event (subtype 8): data1 = key << 16 | state << 8 | repeat.
struct MediaKey {
    enum Kind: Int { case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7 }
    let kind: Kind, down: Bool

    init?(data1: Int) {
        guard let k = Kind(rawValue: (data1 & 0xFFFF_0000) >> 16) else { return nil }
        (kind, down) = (k, (data1 & 0xFF00) >> 8 == 0x0A)
    }

    /// The alternative brightness keys: F14/F15 (Scroll Lock/Pause on PC keyboards, brightness on some Logitech ones).
    init?(keyCode: Int64, down: Bool) {
        switch keyCode {
        case 107: kind = .brightnessDown  // kVK_F14
        case 113: kind = .brightnessUp    // kVK_F15
        default: return nil
        }
        self.down = down
    }
}

/// Brightness and volume keys for monitors macOS can't drive. Needs Accessibility (an active event tap); keys for
/// the built-in display, Apple displays and speakers with their own volume pass straight through to macOS.
@MainActor enum DisplayKeys {
    private static var tap: CFMachPort?
    static var handler: ((MediaKey, CGEventFlags) -> Bool)?  // true = handled, swallow the key

    static var running: Bool { tap != nil }

    /// Starts the tap when allowed. `prompt` shows macOS's Accessibility request once. Cheap to call every tick.
    static func start(prompt: Bool) {
        if tap != nil, !AXIsProcessTrusted() { stop() }  // Accessibility revoked: the tap gets nothing any more
        guard tap == nil else { return }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary) else { return }
        // NX_SYSDEFINED (media keys) plus key down/up for F14/F15. ponytail: every keystroke passes through this
        // callback on the main thread; a separate tap thread if typing ever lags behind a busy panel.
        let mask = CGEventMask(1 << 14 | 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { if let t = DisplayKeys.tap { CGEvent.tapEnable(tap: t, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            let key = type == .keyDown || type == .keyUp
                ? (event.flags.isDisjoint(with: [.maskCommand, .maskControl])  // ⌘F15 and the like are app shortcuts
                   ? MediaKey(keyCode: event.getIntegerValueField(.keyboardEventKeycode), down: type == .keyDown) : nil)
                : NSEvent(cgEvent: event).flatMap { $0.subtype.rawValue == 8 ? MediaKey(data1: $0.data1) : nil }
            guard let key else { return Unmanaged.passUnretained(event) }
            let handled = MainActor.assumeIsolated { DisplayKeys.handler?(key, event.flags) ?? false }
            return handled ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        tap = t
    }

    static func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
        tap = nil
    }
}

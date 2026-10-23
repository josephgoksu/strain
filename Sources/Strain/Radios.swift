import CoreBluetooth
import Foundation

/// Wi-Fi and Bluetooth power. Wi-Fi through `networksetup`; Bluetooth through the private IOBluetooth calls `blueutil`
/// uses (macOS has no command for it). Every call blocks briefly: run them off the main thread.
enum Radios {
    /// "Hardware Port: Wi-Fi" is followed by "Device: en0".
    static func parseWiFiDevice(_ ports: String) -> String? {
        let lines = ports.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let i = lines.firstIndex(of: "Hardware Port: Wi-Fi"), i + 1 < lines.count, lines[i + 1].hasPrefix("Device: ") else { return nil }
        return String(lines[i + 1].dropFirst("Device: ".count))
    }

    static let wifiDevice = parseWiFiDevice(run("/usr/sbin/networksetup", ["-listallhardwareports"]))

    static func wifiOn() -> Bool? {
        guard let d = wifiDevice else { return nil }
        let out = run("/usr/sbin/networksetup", ["-getairportpower", d])
        return out.hasSuffix("On\n") ? true : out.hasSuffix("Off\n") ? false : nil
    }

    static func setWiFi(_ on: Bool) -> Bool {
        guard let d = wifiDevice else { return false }
        return exitStatus("/usr/sbin/networksetup", ["-setairportpower", d, on ? "on" : "off"]) == 0
    }

    private nonisolated(unsafe) static let bluetooth = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)

    /// macOS kills a process that touches Bluetooth without a usage string: dev builds (`swift run`) have none.
    static let bluetoothAllowed = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil

    /// nil when not allowed (no usage string, or the user said no: the call would then just read "off"), or the
    /// private call is gone (a future macOS); the tile then hides.
    static func bluetoothOn() -> Bool? {
        guard bluetoothAllowed, ![.denied, .restricted].contains(CBManager.authorization),
              let f = dlsym(bluetooth, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return unsafeBitCast(f, to: (@convention(c) () -> Int32).self)() != 0
    }

    /// The controller switches asynchronously; wait up to 3 s for it, like blueutil does.
    static func setBluetooth(_ on: Bool) -> Bool {
        guard bluetoothAllowed, let f = dlsym(bluetooth, "IOBluetoothPreferenceSetControllerPowerState") else { return false }
        unsafeBitCast(f, to: (@convention(c) (Int32) -> Void).self)(on ? 1 : 0)
        for _ in 0..<30 where bluetoothOn() != on { usleep(100_000) }
        return bluetoothOn() == on
    }
}

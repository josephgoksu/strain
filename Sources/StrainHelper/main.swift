import Foundation
import HelperKit

/// Strain's root helper. launchd starts it on demand (SMAppService daemon inside Strain.app, approved once in System
/// Settings). Only Strain signed by our team can connect, and it can only ask for the fixed things in HelperKit.
/// It exits when idle, so an updated binary takes over on the next call, and it never leaves AirDrop down behind it.
final class Helper: NSObject, NSXPCListenerDelegate, StrainHelperProtocol, @unchecked Sendable {
    let queue = DispatchQueue(label: "awdl")
    // All touched only on `queue`:
    private var holders = Set<ObjectIdentifier>()  // connections asking to hold AWDL
    private var guardState = AWDLGuard(held: FileManager.default.fileExists(atPath: HelperKit.heldMarker))
    private var busy = 0                           // run/loginItems calls in flight
    private var lastUse = Date.now
    private var timer: DispatchSourceTimer?
    private let binary = Bundle.main.executablePath ?? ""
    private lazy var builtAt = modified(binary)

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: StrainHelperProtocol.self)
        c.exportedObject = self
        let id = ObjectIdentifier(c)
        // Strain quit or crashed: its hold goes with it, so AirDrop is never left blocked.
        c.invalidationHandler = { [self] in queue.async { self.holders.remove(id) } }  // the helper lives as long as the process
        c.resume()
        return true
    }

    func run(_ action: String, reply: @escaping (Bool) -> Void) {
        guard let steps = HelperKit.actions[action] else { return reply(false) }
        track(true)
        defer { track(false) }
        reply(steps.allSatisfy { exec($0).status == 0 })
    }

    func holdAWDL(_ hold: Bool, reply: @escaping () -> Void) {
        guard let c = NSXPCConnection.current() else { return reply() }
        let id = ObjectIdentifier(c)
        queue.sync { _ = hold ? holders.insert(id).inserted : holders.remove(id) != nil; lastUse = .now }
        reply()
    }

    func loginItems(reply: @escaping (String) -> Void) {
        track(true)
        defer { track(false) }
        let r = exec(["/usr/bin/sfltool", "dumpbtm"], timeout: 60)
        reply(r.status == 0 ? r.output : "")
    }

    private func track(_ on: Bool) { queue.sync { busy += on ? 1 : -1; lastUse = .now } }

    /// Every second: apply the AirDrop decision, then exit if nothing has needed the helper for 30 s.
    /// ponytail: 1 s polling with getifaddrs (no spawn); a route-socket watcher would react faster.
    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(500))  // lets macOS batch wakeups with others
        t.setEventHandler { [self] in
            apply(guardState.step(holding: !holders.isEmpty, linkUp: HelperKit.awdlIsUp()))
            // The marker mirrors `held` (even when the link was already down), so a crash mid-hold is undone on restart.
            if guardState.held != FileManager.default.fileExists(atPath: HelperKit.heldMarker) {
                if guardState.held { FileManager.default.createFile(atPath: HelperKit.heldMarker, contents: nil) }
                else { try? FileManager.default.removeItem(atPath: HelperKit.heldMarker) }
            }
            // Strain was reinstalled: hand over to the new binary (launchd starts it on Strain's next call, within a tick).
            if modified(binary) != builtAt { stop() }
            // launchd starts a fresh copy (the installed binary) on the next call.
            if holders.isEmpty, !guardState.held, busy == 0, Date.now.timeIntervalSince(lastUse) > 30 { exit(0) }
        }
        t.resume()
        timer = t
    }

    /// Stopped by launchd (turned off, logout, shutdown): give AirDrop back first. Runs on `queue`.
    func stop() -> Never {
        if guardState.held { apply(guardState.step(holding: false, linkUp: nil)) }
        try? FileManager.default.removeItem(atPath: HelperKit.heldMarker)
        exit(0)
    }

    private func apply(_ step: AWDLGuard.Step) {
        switch step {
        case .down:
            _ = exec(["/sbin/ifconfig", "awdl0", "down"])
        case .up:
            _ = exec(["/sbin/ifconfig", "awdl0", "up"])
        case .none:
            break
        }
    }
}

func modified(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }

/// Runs a fixed command and waits; kills it after `timeout` seconds (sfltool has hung for minutes).
func exec(_ argv: [String], timeout: Double = 20) -> (status: Int32, output: String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return (-1, "") }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// The sudo rule from before the helper: the helper replaces it, so it goes.
try? FileManager.default.removeItem(atPath: "/etc/sudoers.d/strain")

let helper = Helper()
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: helper.queue)
term.setEventHandler { helper.stop() }
term.resume()
helper.start()
let listener = NSXPCListener(machServiceName: HelperKit.label)
listener.setConnectionCodeSigningRequirement(HelperKit.appRequirement)
listener.delegate = helper
listener.resume()
dispatchMain()

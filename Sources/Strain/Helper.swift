import Foundation
import HelperKit
import ServiceManagement

/// Strain's root helper: an SMAppService daemon shipped inside Strain.app. macOS asks once, in System Settings →
/// Login Items; after that admin tiles, the AirDrop hold and Login Items need no password or Touch ID.
@MainActor enum HelperClient {
    static let service = SMAppService.daemon(plistName: HelperKit.plist)
    /// Read once per tick (`refresh`), not per call: each read asks the system.
    private(set) static var status = service.status
    private static var connection: NSXPCConnection?

    static func refresh() { status = service.status }

    /// Registers the daemon; macOS then wants the user's OK in System Settings, so that opens too.
    /// Returns why it failed, or nil.
    static func enable() -> String? {
        var failure: String?
        do { try service.register() } catch { failure = error.localizedDescription }
        refresh()
        switch status {
        case .enabled: return nil
        case .requiresApproval: SMAppService.openSystemSettingsLoginItems(); return nil
        default: return failure ?? "macOS didn't register the helper."
        }
    }

    static func disable() {
        connection?.invalidate()
        connection = nil
        try? service.unregister()  // the sync call: the async one sends SMAppService (not Sendable) off the main actor
        refresh()
    }

    /// One long-lived connection: the AirDrop hold lasts exactly as long as it does.
    private static func remote(_ failed: @escaping @Sendable () -> Void) -> StrainHelperProtocol? {
        guard status == .enabled else { return nil }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperKit.label, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: StrainHelperProtocol.self)
            c.setCodeSigningRequirement(HelperKit.helperRequirement)
            c.invalidationHandler = { Task { @MainActor in connection = nil } }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in failed() } as? StrainHelperProtocol
    }

    /// nil when the helper isn't on or didn't answer: the caller falls back.
    static func run(_ action: String) async -> Bool? {
        await withCheckedContinuation { (k: CheckedContinuation<Bool?, Never>) in
            let once = Once(k)
            guard let r = remote({ once.resume(nil) }) else { return once.resume(nil) }
            r.run(action) { once.resume($0) }
        }
    }

    static func loginItems() async -> String? {
        await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
            let once = Once(k)
            guard let r = remote({ once.resume(nil) }) else { return once.resume(nil) }
            r.loginItems { once.resume($0) }
        }
    }

    /// Fire and forget, every tick: a helper that restarted picks the hold up again within one tick.
    static func holdAWDL(_ hold: Bool) { remote({})?.holdAWDL(hold) {} }
}

/// XPC may call the error handler after the reply, or instead of it: resume the continuation once.
private final class Once<T: Sendable>: @unchecked Sendable {
    private var k: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ k: CheckedContinuation<T, Never>) { self.k = k }
    func resume(_ v: T) {
        lock.lock(); let k = self.k; self.k = nil; lock.unlock()
        k?.resume(returning: v)
    }
}

import Foundation

/// One entry from macOS's Login Items database (`sfltool dumpbtm`): what may start without you opening it.
struct BackgroundItem: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case openAtLogin = "Opens at login"
        case loginHelper = "Login helpers"
        case backgroundTasks = "App background tasks"
        case agent = "Background agents"
        case daemon = "Admin helpers"

        var singular: String {
            switch self {
            case .openAtLogin: "an app that opens at login"
            case .loginHelper: "a login helper"
            case .backgroundTasks: "an app's background task"
            case .agent: "a background agent"
            case .daemon: "an admin helper (daemon)"
            }
        }
    }
    enum Status { case on, off, blocked }

    var name: String
    var developer: String?
    var kind: Kind
    var status: Status
    var url: String?
    var executable: String?
    var bundleID: String?
    var parent: String? = nil   // BTM identifier of the app a helper sits inside
    var id: String { "\(kind.rawValue)|\(name)|\(url ?? "")" }

    /// The launchd label for plist-based agents: names like "bash" say nothing, the label does.
    var label: String? {
        guard let url, url.hasSuffix(".plist") else { return nil }
        return ((url as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// The app a "X - background tasks" entry belongs to.
    var app: String? { name.hasSuffix(" - background tasks") ? String(name.dropLast(" - background tasks".count)) : nil }

    var asRoot: Bool { kind == .daemon }

    /// The file on disk this item starts: its program, else its app. Nil when a shell runs it or the path is relative.
    var target: String? {
        if let exe = executable.map(localPath), exe.hasPrefix("/"), !isInterpreter((exe as NSString).lastPathComponent) { return exe }
        if let u = url.map(localPath), u.hasPrefix("/"), !u.hasSuffix(".plist") { return u }
        return nil
    }

    /// Its app, program or launch file is gone, so it can't run: a leftover of a removed app. macOS keeps the entry anyway.
    var missing: Bool {
        [url.map(localPath), target].compactMap { $0 }.filter { $0.hasPrefix("/") && !otherUsersPath($0) }
            .contains { !FileManager.default.fileExists(atPath: $0) }
    }

    /// The item's own name, unless it's just the interpreter that runs it ("bash" says nothing about the job).
    private var ownName: String? { isInterpreter(name) ? nil : name }

    /// Display name: the table's title for whichever key matched, else the label (it beats "bash"), else app or name.
    func title(_ table: Explanations) -> String {
        if let l = label, let e = table[l] { return e.title ?? l }
        if let n = ownName, let e = table[n] { return e.title ?? app ?? n }
        return label ?? app ?? name
    }

    func explain(_ table: Explanations) -> Explanations.Entry {
        // A background-task permission isn't the app's process: never borrow the app's process entry.
        if let e = [label, ownName].compactMap({ $0 }).lazy.compactMap({ table[$0] }).first { return e }
        switch kind {
        case .openAtLogin:
            return .init(what: "Opens when you log in.", advice: "Turn it off in Login Items if you don't need it at startup.")
        case .loginHelper:
            return .init(what: "A small helper that starts its app at login.", advice: "Turn it off if you don't want the app at startup.")
        case .backgroundTasks:
            return .init(what: "Lets \(app ?? name) run work while its window is closed: updates, sync, notifications.",
                         advice: "Turn it off for apps you rarely use. The app still works when you open it.")
        case .agent:
            return .init(what: "Runs in the background as you, started by macOS on a schedule or at login.",
                         advice: "Keep it only if you know what installed it.")
        case .daemon:
            return .init(what: "Runs in the background as admin (root), even before you log in.",
                         advice: "Keep only for apps you trust and still use.")
        }
    }
}

/// Parses `sfltool dumpbtm`. Keeps login items, agents, daemons and app background tasks;
/// enabled "app" records are the classic "Open at Login" apps. Quick Look, Spotlight and dock tile plug-ins are skipped.
func parseBTM(_ text: String) -> [BackgroundItem] {
    var items: [BackgroundItem] = []
    var f: [String: String] = [:]
    var urls: [String: String] = [:]  // every record's identifier → URL, skipped ones too: a helper's parent may be one
    func flush() {
        defer { f = [:] }
        if let id = f["Identifier"], let u = f["URL"], u != "(null)" { urls[id] = u }
        guard let name = f["Name"], let type = f["Type"], let disp = f["Disposition"] else { return }
        let enabled = disp.contains("[enabled"), allowed = !disp.contains("disallowed")
        let kind: BackgroundItem.Kind
        switch type {
        case let t where t.hasPrefix("app"): guard enabled else { return }; kind = .openAtLogin
        case let t where t.hasPrefix("login item"): kind = .loginHelper
        case let t where t.hasPrefix("background tasks"): kind = .backgroundTasks
        case let t where t.contains("agent"): kind = .agent
        case let t where t.contains("daemon"): kind = .daemon
        default: return
        }
        let value = { (k: String) in f[k].flatMap { $0 == "(null)" ? nil : $0 } }
        items.append(BackgroundItem(name: name, developer: value("Developer Name"), kind: kind,
                                    status: !allowed ? .blocked : enabled ? .on : .off,
                                    url: value("URL"), executable: value("Executable Path"), bundleID: value("Bundle Identifier"),
                                    parent: value("Parent Identifier")))
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("=") || (t.hasPrefix("#") && t.hasSuffix(":")) { flush(); continue }
        guard let colon = t.range(of: ": ") else { continue }
        f[String(t[..<colon.lowerBound])] = String(t[colon.upperBound...])
    }
    flush()
    // Helpers inside an app list paths relative to it ("Contents/Library/LoginItems/X.app"): anchor them to the app.
    return items.map { item in
        var item = item
        guard let base = item.parent.flatMap({ urls[$0] }), base.hasPrefix("/") else { return item }
        if let u = item.url, !u.hasPrefix("/") { item.url = base + "/" + u }
        if let e = item.executable, !e.hasPrefix("/") { item.executable = base + "/" + e }
        return item
    }
}

/// "/Users/<uid>/…" that `localPath` couldn't map: another account's item. Its real home isn't known, so it can't be
/// judged missing.
func otherUsersPath(_ path: String) -> Bool {
    let parts = path.split(separator: "/", maxSplits: 2)
    return parts.count > 1 && parts[0] == "Users" && parts[1].allSatisfy(\.isNumber)
}

/// Login Items writes the home folder as "/Users/<uid>"; on disk it's the real home.
func localPath(_ path: String) -> String {
    let uidHome = "/Users/\(getuid())/"
    return path.hasPrefix(uidHome) ? NSHomeDirectory() + "/" + path.dropFirst(uidHome.count) : path
}

/// Whether a background program is signed by a known developer. Apps: Gatekeeper's notarization check. Bare programs:
/// a valid signature (Gatekeeper can't assess those, it says "not an app"). Scripts: nothing, they're readable.
enum Signing {
    static func badge(_ path: String) -> String? {
        if path.hasSuffix(".app") {
            let out = run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-v", path], stderr: true)
            return out.contains(": accepted") ? nil : "Not notarized"
        }
        guard isMachO(path) else { return nil }
        return exitStatus("/usr/bin/codesign", ["--verify", path]) == 0 ? nil : "Unsigned"
    }

    /// Changes when the program does: an app's Info.plist (rewritten by every update), else the file itself.
    static func stamp(_ path: String) -> String {
        let file = path.hasSuffix(".app") ? path + "/Contents/Info.plist" : path
        let date = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
        return String(Int(date?.timeIntervalSince1970 ?? 0))
    }

    static func isMachO(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path), let d = try? h.read(upToCount: 4), d.count == 4 else { return false }
        try? h.close()
        let magic = d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [0xFEEDFACF, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA, 0xFEEDFACE, 0xCEFAEDFE].contains(magic)
    }
}

/// Runs `sfltool dumpbtm`. Since macOS 27 it asks for admin (Touch ID), so it only runs on the user's click;
/// the timeout covers a prompt left unanswered. Empty output = cancelled or failed.
func readLoginItemsText() -> String { run("/usr/bin/sfltool", ["dumpbtm"], timeout: 120) }

/// The last successful read, kept so the Touch ID prompt comes only when the user asks for a fresh list.
enum LoginItemsCache {
    static let file = Explanations.unknownFile.deletingLastPathComponent().appendingPathComponent("login-items.txt")

    static func load() -> (text: String, date: Date)? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        return (text, date)
    }

    static func save(_ text: String) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// Same item listed under several users or twice: keep one.
func dedupe(_ items: [BackgroundItem]) -> [BackgroundItem] {
    var seen = Set<String>()
    return items.filter { seen.insert($0.id).inserted }
}

/// The running group behind an item, if any. Interpreter names ("bash") match too much to trust.
func runningGroup(for item: BackgroundItem, in groups: [Group]) -> Group? {
    if let url = item.url, url.hasSuffix(".app"), let g = groups.first(where: { $0.bundle == url }) { return g }
    if let app = item.app { return groups.first { $0.name == app } }
    if let exe = item.executable {
        guard !isInterpreter((exe as NSString).lastPathComponent) else { return nil }
        if let g = groups.first(where: { $0.path == exe || ($0.bundle.map { exe.hasPrefix($0 + "/") } ?? false) }) { return g }
    }
    guard !isInterpreter(item.name) else { return nil }
    return groups.first { $0.name == item.name }
}

/// Shells and runtimes: their name says what runs a job, not what the job is. Version suffixes fold ("python3.12").
func isInterpreter(_ name: String) -> Bool {
    ["bash", "sh", "zsh", "fish", "python", "node", "ruby", "perl", "osascript", "java", "deno", "bun"].contains(Explanations.fold(name))
}

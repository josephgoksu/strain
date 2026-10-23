import Foundation

/// The "what is this?" table: Resources/explanations.json, keyed by group name. No network, no LLM.
/// Lookup ladder: the table (exact, then case- and version-insensitive), then rules read from the path itself
/// (Apple's apps, Apple's services, any other app's Info.plist). Only CLIs and helpers no rule covers stay Unknown.
struct Explanations {
    struct Entry: Codable, Equatable {
        var what: String, advice: String
        var title: String? = nil  // friendlier display name, e.g. "claude" → "Claude Code"
    }
    let entries: [String: Entry]
    private let folded: [String: Entry]  // keys lowercased, version suffix dropped

    init(entries: [String: Entry]) {
        self.entries = entries
        folded = Dictionary(entries.map { (Self.fold($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// "Python3.12" → "python", "node22" → "node": one entry covers every version of a tool.
    static func fold(_ name: String) -> String {
        let lower = name.lowercased()
        let trimmed = lower.reversed().drop { "0123456789.-_".contains($0) }
        return trimmed.isEmpty ? lower : String(trimmed.reversed())
    }

    subscript(name: String) -> Entry? { entries[name] ?? folded[Self.fold(name)] }

    /// The table's entry, else one derived from where the process lives. nil = Unknown.
    func entry(_ name: String, path: String) -> Entry? {
        if let e = self[name] { return e }
        let bundle = owner(of: path).bundle
        if isAppleApp(bundle) { return Self.appleApp }
        if Self.systemRoots.contains(where: path.hasPrefix) { return Self.macOSService }
        if let bundle { return Self.app(Bundle(path: bundle)?.infoDictionary ?? [:]) }  // Bundle caches per path
        return nil
    }

    static let systemRoots = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]
    static let macOSService = Entry(what: "A built-in macOS service.",
                                    advice: "Can't be quit; macOS restarts it. Usually busy for a short while after an update, sign-in or wake, then idles.")
    static let appleApp = Entry(what: "One of Apple's built-in apps.", advice: "Quit it when you're not using it; it reopens when you need it.")

    /// An installed app, described from its own Info.plist: App Store category and copyright holder.
    static func app(_ info: [String: Any]) -> Entry {
        var what = "An app"
        if let raw = (info["LSApplicationCategoryType"] as? String)?.split(separator: ".").last {
            let kind = ["developer-tools": "developer tool", "utilities": "utility", "games": "game", "graphics-design": "design",
                        "social-networking": "messaging", "healthcare-fitness": "fitness", "music": "music", "video": "video"][String(raw)]
                ?? raw.replacingOccurrences(of: "-", with: " ")
            what = kind == "utility" ? "A utility" : "A \(kind) app"
        }
        if let vendor = vendor(info["NSHumanReadableCopyright"] as? String) { what += " by \(vendor)" }
        return Entry(what: what.hasSuffix(".") ? what : what + ".", advice: "Quit it when you're not using it. If it's busy while idle, check its settings for sync or background work.")
    }

    /// "Copyright © 2026 Tailscale Inc. All Rights Reserved." → "Tailscale Inc."
    static func vendor(_ copyright: String?) -> String? {
        guard var s = copyright else { return nil }
        for junk in [#"(?i)all rights reserved\.?"#, #"(?i)copyright"#, "©", #"(?i)\(c\)"#, #"\d{4}\s*[-–]\s*\d{4}"#, #"\d{4}"#] {
            s = s.replacingOccurrences(of: junk, with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\s+\."#, with: "", options: .regularExpression)  // the "." left behind a removed year
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines))
        return s.isEmpty || s.count > 40 ? nil : s
    }

    /// Display name: the table's title, else the name with any reverse-DNS prefix dropped
    /// ("com.macpaw.CleanMyMac-setapp.HealthMonitor" → "CleanMyMac-setapp HealthMonitor").
    func title(_ name: String) -> String {
        if let t = self[name]?.title { return t }
        let parts = name.split(separator: ".")
        guard parts.count >= 3, ["com", "org", "io", "net", "app", "dev"].contains(parts[0]) else { return name }
        return parts.dropFirst(2).joined(separator: " ")
    }

    static let repoFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/explanations.json")

    static let unknownFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Strain/unknown.txt")

    static func load(from url: URL) throws -> Explanations {
        Explanations(entries: try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url)))
    }

    /// The app bundle's copy, or the repo's when run with `swift run`.
    static func bundled() -> Explanations {
        let url = Bundle.main.url(forResource: "explanations", withExtension: "json") ?? repoFile
        return (try? load(from: url)) ?? Explanations(entries: [:])
    }

    /// Appends `name<TAB>path` for groups missing from the table, once per name.
    /// unknown.txt as (name, path) pairs.
    static func readUnknowns(from file: URL = unknownFile) -> [(name: String, path: String)] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map {
            let f = $0.split(separator: "\t", maxSplits: 1)
            return (name: String(f[0]), path: f.count > 1 ? String(f[1]) : "")
        }
    }

    func logUnknowns(_ groups: [Group], to file: URL = unknownFile) {
        let seen = Set(Self.readUnknowns(from: file).map(\.name))
        let lines = groups.filter { entry($0.name, path: $0.path) == nil && !seen.contains($0.name) }.map { "\($0.name)\t\($0.path)\n" }
        guard !lines.isEmpty else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(lines.joined().utf8))
            try? h.close()
        } else {
            try? lines.joined().write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

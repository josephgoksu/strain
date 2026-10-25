import Foundation

/// A folder or file and the space it takes. `untouched`: when it was last opened or changed (Downloads only).
struct SpaceEntry: Identifiable, Equatable {
    let path: String, size: Int64
    var untouched: Date? = nil
    var id: String { path }
}

/// Where the space went: the largest folders two levels under home, and Downloads nobody opened in months.
/// Only on a click: the walk takes minutes, and macOS asks once for each protected folder (Desktop, Documents…).
enum Space {
    /// Never walked. Other apps' containers trigger macOS's "access data from other apps" prompt; cloud folders
    /// would size placeholders or start downloads; Trash has its own button in Finder.
    static let skipped: Set<String> = [
        "Library/Containers", "Library/Group Containers", "Library/CloudStorage", "Library/Mobile Documents",
        "Library/Mail", "Library/Messages", ".Trash",
    ]

    /// The `limit` largest folders exactly two levels down (`~/Library/Developer`, `~/Development/products`), so the
    /// list points at something you can act on, not at "Library".
    static func largestFolders(home: String = NSHomeDirectory(), limit: Int = 10) -> [SpaceEntry] {
        let found = subfolders(home).filter { !skipped.contains(relative($0, home)) }.flatMap { top in
            subfolders(top).filter { !skipped.contains(relative($0, home)) }.map { SpaceEntry(path: $0, size: Cleanup.size(of: URL(fileURLWithPath: $0))) }
        }
        return Array(found.filter { $0.size > 0 }.sorted { $0.size > $1.size }.prefix(limit))
    }

    /// Items directly in Downloads not opened or changed for `days`, largest first.
    static func oldDownloads(home: String = NSHomeDirectory(), days: Double = Thresholds.oldDownloadDays, now: Date = .now) -> [SpaceEntry] {
        let dir = URL(fileURLWithPath: home + "/Downloads")
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .contentAccessDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
        return items.compactMap { url -> SpaceEntry? in
            let v = try? url.resourceValues(forKeys: keys)
            let last = max(v?.contentModificationDate ?? .distantPast, v?.contentAccessDate ?? .distantPast)
            guard now.timeIntervalSince(last) > days * 86400 else { return nil }
            return SpaceEntry(path: url.path, size: Cleanup.size(of: url), untouched: last)
        }
        .sorted { $0.size > $1.size }
    }

    /// Moves a Downloads item to the Trash (recoverable). Refuses anything not directly in Downloads.
    static func trash(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == URL(fileURLWithPath: home + "/Downloads").standardizedFileURL.path else { return false }
        return (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }

    static func relative(_ path: String, _ home: String) -> String { path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path }

    /// Real subfolders: symlinks are skipped, so nothing is counted twice.
    private static func subfolders(_ path: String) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: path)) ?? []).map { path + "/" + $0 }.filter {
            (try? fm.attributesOfItem(atPath: $0))?[.type] as? FileAttributeType == .typeDirectory  // a symlink reports .typeSymbolicLink
        }
    }
}

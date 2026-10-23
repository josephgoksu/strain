import AppKit

struct RunningApp { var name: String, bundleID: String }

/// A place that only holds regenerable data: tools and apps rebuild it on demand.
struct CleanItem: Identifiable, Equatable {
    enum Kind: Equatable { case folder(String), appCaches }  // folder: path relative to home
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let kind: Kind
    var folder: String? { if case .folder(let rel) = kind { rel } else { nil } }
}

/// What one clean did: bytes it freed, and entries it had to leave (in use, or protected by macOS).
struct CleanResult: Equatable { var freed: Int64, left: Int }

/// Frees disk space from caches. Deletes the *contents* of a fixed allowlist of folders, never the folder,
/// never anything outside it, never following symlinks. Every call starts from a user's two-step click.
enum Cleanup {
    struct Refused: Error, CustomStringConvertible {
        let path: String
        var description: String { "Refused to clean \(path): not on Strain's allowlist" }
    }

    static let items: [CleanItem] = [
        .init(id: "go", title: "Go build cache", detail: "Go rebuilds it on the next build (slower once).",
              symbol: "hammer", kind: .folder("Library/Caches/go-build")),
        .init(id: "derived", title: "Xcode DerivedData", detail: "Build products and indexes. Xcode rebuilds them.",
              symbol: "hammer.circle", kind: .folder("Library/Developer/Xcode/DerivedData")),
        .init(id: "devicesupport", title: "iOS DeviceSupport", detail: "Debug symbols per iOS version. Xcode copies them again when a device connects.",
              symbol: "iphone", kind: .folder("Library/Developer/Xcode/iOS DeviceSupport")),
        .init(id: "bun", title: "Bun cache", detail: "Downloaded packages. Bun fetches them again on install.",
              symbol: "shippingbox", kind: .folder(".bun/install/cache")),
        .init(id: "npm", title: "npm cache", detail: "Downloaded packages. npm fetches them again on install.",
              symbol: "shippingbox", kind: .folder(".npm/_cacache")),
        .init(id: "swiftpm", title: "SwiftPM cache", detail: "Downloaded Swift packages. Fetched again on resolve.",
              symbol: "swift", kind: .folder("Library/Caches/org.swift.swiftpm")),
        .init(id: "gomod", title: "Go modules", detail: "Downloaded Go modules. Fetched again on the next build.",
              symbol: "shippingbox.fill", kind: .folder("go/pkg/mod")),
        .init(id: "cargo", title: "Cargo registry", detail: "Downloaded Rust crates. Cargo fetches them again on build.",
              symbol: "gearshape.2", kind: .folder(".cargo/registry")),
        .init(id: "pnpm", title: "pnpm store", detail: "pnpm's shared packages. Fetched again on install.",
              symbol: "shippingbox", kind: .folder("Library/pnpm/store")),
        .init(id: "yarn", title: "Yarn cache", detail: "Downloaded packages. Yarn fetches them again on install.",
              symbol: "shippingbox", kind: .folder("Library/Caches/Yarn")),
        .init(id: "uv", title: "uv cache", detail: "Python packages uv downloaded. Fetched again on install.",
              symbol: "shippingbox", kind: .folder(".cache/uv")),
        .init(id: "gradle", title: "Gradle caches", detail: "Downloaded dependencies and build caches. Gradle rebuilds them.",
              symbol: "hammer", kind: .folder(".gradle/caches")),
        .init(id: "pods", title: "CocoaPods cache", detail: "Downloaded pods. Fetched again on pod install.",
              symbol: "shippingbox", kind: .folder("Library/Caches/CocoaPods")),
        .init(id: "brew", title: "Homebrew downloads", detail: "Installer downloads Homebrew keeps after installing.",
              symbol: "mug", kind: .folder("Library/Caches/Homebrew")),
        .init(id: "apps", title: "App caches", detail: "Caches of apps that aren't running. Apps rebuild them; first launch may be slower.",
              symbol: "app.dashed", kind: .appCaches),
    ]

    /// Fixed folders that `items` names; app caches are direct children of ~/Library/Caches.
    static func allowed(_ dir: URL, home: String) -> Bool {
        let path = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let fixed = items.compactMap { $0.folder.map { home + "/" + $0 } }
        if fixed.contains(path) { return true }
        let caches = home + "/Library/Caches"
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return parent == caches && !name.hasPrefix("com.apple.") && !name.hasPrefix(".")
    }

    /// Deletes everything inside `dir`, keeps `dir`. Symlinks are removed as links, never followed.
    /// Returns how many entries it couldn't delete. No sizing here: that's a second walk of the whole tree.
    @discardableResult
    static func removeContents(of dir: URL, home: String) throws -> Int {
        guard allowed(dir, home: home) else { throw Refused(path: dir.path) }
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return children.filter { child in
            if (try? fm.removeItem(at: child)) != nil { return false }
            makeWritable(child)  // Go keeps its module cache read-only on purpose; that's not "in use"
            return (try? fm.removeItem(at: child)) == nil
        }.count
    }

    /// Adds owner write permission to every folder under `url`, so its files can be unlinked. Never follows symlinks.
    static func makeWritable(_ url: URL) {
        let fm = FileManager.default
        let dirs = [url] + ((fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [], errorHandler: { _, _ in true })?
            .compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) ?? [])
        for dir in dirs {
            let mode = (try? fm.attributesOfItem(atPath: dir.path))?[.posixPermissions] as? Int ?? 0o755
            try? fm.setAttributes([.posixPermissions: mode | 0o700], ofItemAtPath: dir.path)
        }
    }

    /// Allocated bytes under `url`, not following symlinks.
    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        var total = Int64(values.totalFileAllocatedSize ?? 0)
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return total }
        for case let file as URL in walker {
            let v = try? file.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { continue }
            total += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Cache folders of apps that aren't running, minus Apple's and the ones with their own item.
    /// ponytail: "running" = bundle ID match, or the app's first name word or its bundle ID's vendor (≥4 letters)
    /// in the folder name ("Brave" in BraveSoftware, "jetbrains" for GoLand). A cache of an unknown helper might
    /// still be in use; apps tolerate that.
    static func appCacheFolders(home: String, running: [RunningApp]) -> [URL] {
        let caches = URL(fileURLWithPath: home + "/Library/Caches")
        let own = Set(items.compactMap { $0.folder }.filter { $0.hasPrefix("Library/Caches/") }.map { String($0.dropFirst("Library/Caches/".count)) })
        let words = running.flatMap { app -> [String] in
            let id = app.bundleID.lowercased().split(separator: ".")
            return [app.name.split(separator: " ").first.map { $0.lowercased() }, id.count >= 3 ? String(id[1]) : nil].compactMap { $0 }
        }
        .filter { $0.count >= 4 && $0 != "apple" }
        let ids = Set(running.map { $0.bundleID.lowercased() })
        let folders = (try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { url in
            let name = url.lastPathComponent, lower = name.lowercased()
            guard !name.hasPrefix("com.apple."), !name.hasPrefix("."), !own.contains(name) else { return false }
            if ids.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") }) { return false }
            return !words.contains { lower.contains($0) }
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @MainActor static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier else { return nil }
            return RunningApp(name: app.localizedName ?? id, bundleID: id)
        }
    }
}

extension Cleanup {
    static func folders(_ item: CleanItem, home: String = NSHomeDirectory(), running: [RunningApp]) -> [URL] {
        switch item.kind {
        case .folder(let rel): [URL(fileURLWithPath: home + "/" + rel)]
        case .appCaches: appCacheFolders(home: home, running: running)
        }
    }

    static func size(_ item: CleanItem, running: [RunningApp]) -> Int64 {
        folders(item, running: running).reduce(0) { $0 + size(of: $1) }
    }

    static func sizes(running: [RunningApp]) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, size($0, running: running)) })
    }

    /// Empties the item's folders. Returns how many entries were left behind.
    static func clean(_ item: CleanItem, home: String = NSHomeDirectory(), running: [RunningApp]) -> Int {
        folders(item, home: home, running: running).reduce(0) { $0 + ((try? removeContents(of: $1, home: home)) ?? 0) }
    }
}

/// Free space on the startup disk, as Finder counts it (purgeable space included).
struct Disk {
    var free: Int64, total: Int64
    static func read() -> Disk {
        let v = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        guard let free = v?.volumeAvailableCapacityForImportantUsage, let total = v?.volumeTotalCapacity else { return Disk(free: 0, total: 0) }
        return Disk(free: free, total: Int64(total))  // total 0 = couldn't read
    }
    var summary: String { "\(formatBytes(free)) free of \(formatBytes(total))" }
}

func formatBytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

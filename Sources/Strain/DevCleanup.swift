import Foundation

/// A regenerable build folder inside a project: node_modules, target, .build…
struct Artifact: Identifiable, Equatable {
    let path: String, size: Int64
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// A folder that holds build folders, and when anyone last worked in it.
struct DevProject: Identifiable, Equatable {
    let path: String
    var artifacts: [Artifact]
    let lastActive: Date
    var id: String { path }
    var size: Int64 { artifacts.reduce(0) { $0 + $1.size } }
    func stale(now: Date = .now) -> Bool { now.timeIntervalSince(lastActive) > Thresholds.staleProjectDays * 86400 }
}

/// One iOS/watchOS/tvOS simulator and the space its data takes.
struct Simulator: Identifiable, Equatable {
    let udid: String, name: String, runtime: String
    let size: Int64
    let lastUsed: Date?
    let booted: Bool, available: Bool
    var id: String { udid }
}

/// Build folders in your projects and simulator data: the two biggest regenerable piles on a developer's Mac.
enum DevCleanup {
    /// Build folder name → the manifest that must sit beside it, so an unrelated "target" or ".build" is never touched.
    static let artifacts: [String: String] = [
        "node_modules": "package.json", ".next": "package.json", ".turbo": "package.json", ".nuxt": "package.json",
        ".svelte-kit": "package.json", ".parcel-cache": "package.json", "target": "Cargo.toml", ".build": "Package.swift",
    ]
    static let rootNames = ["Development", "Developer", "Projects", "code", "src", "dev", "repos", "work", "GitHub"]

    static func roots(home: String = NSHomeDirectory()) -> [String] {
        rootNames.map { home + "/" + $0 }.filter { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &dir) && dir.boolValue }
    }

    /// A build folder Strain may delete: inside a dev root, a known name, its manifest beside it, not a symlink.
    static func allowed(_ path: String, roots: [String]) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard roots.contains(where: { url.path.hasPrefix($0 + "/") }), let manifest = artifacts[url.lastPathComponent],
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false else { return false }
        return FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(manifest).path)
    }

    /// Walks the roots for build folders (never inside them, nor inside hidden folders like .git), grouped by project.
    static func scan(roots: [String], maxDepth: Int = 7) -> [DevProject] {
        var found: [String: [Artifact]] = [:]
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let name = url.lastPathComponent
                if artifacts[name] != nil {
                    walker.skipDescendants()
                    if allowed(url.path, roots: [root]) {
                        found[url.deletingLastPathComponent().path, default: []].append(Artifact(path: url.path, size: Cleanup.size(of: url)))
                    }
                } else if name.hasPrefix(".") || walker.level >= maxDepth {
                    walker.skipDescendants()
                }
            }
        }
        return found.map { DevProject(path: $0.key, artifacts: $0.value.sorted { $0.size > $1.size }, lastActive: lastActive($0.key)) }
            .sorted { $0.size > $1.size }
    }

    /// Newest of: the folder, everything directly in it (manifests, lockfiles, the build folders themselves, so installs
    /// and builds count), and the enclosing git repo's index and HEAD (bumped by status, add, commit, checkout).
    static func lastActive(_ project: String) -> Date {
        var paths = [project] + ((try? FileManager.default.contentsOfDirectory(atPath: project)) ?? []).map { project + "/" + $0 }
        var dir = project
        while dir.count > 1 {
            if FileManager.default.fileExists(atPath: dir + "/.git/index") { paths += [dir + "/.git/index", dir + "/.git/HEAD"]; break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return paths.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max() ?? .distantPast
    }

    /// Deletes the build folders. Returns how many it couldn't.
    static func remove(_ artifacts: [Artifact], roots: [String]) -> Int {
        artifacts.filter { !allowed($0.path, roots: roots) || (try? FileManager.default.removeItem(atPath: $0.path)) == nil }.count
    }

    // MARK: Simulators

    static func parseSimulators(_ json: Data) -> [Simulator] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]] else { return [] }
        let iso = ISO8601DateFormatter()
        return devices.flatMap { runtime, list in
            list.compactMap { d -> Simulator? in
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { return nil }
                return Simulator(udid: udid, name: name, runtime: runtimeName(runtime), size: (d["dataPathSize"] as? NSNumber)?.int64Value ?? 0,
                                 lastUsed: (d["lastUsedAt"] as? String).flatMap(iso.date), booted: d["state"] as? String == "Booted",
                                 available: d["isAvailable"] as? Bool ?? true)
            }
        }
        .sorted { $0.size > $1.size }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0"
    static func runtimeName(_ id: String) -> String {
        let parts = (id.split(separator: ".").last ?? "").split(separator: "-")
        guard let os = parts.first else { return id }
        return parts.count > 1 ? "\(os) \(parts.dropFirst().joined(separator: "."))" : String(os)
    }

    /// Needs Xcode; without it the list is empty and the section hides.
    static func readSimulators() -> [Simulator] { parseSimulators(Data(run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 30).utf8)) }
}

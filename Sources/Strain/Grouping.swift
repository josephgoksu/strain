import Foundation

let simulatorGroup = "iOS Simulator"

struct Owner: Equatable {
    var name: String
    var bundle: String?  // the .app path, when the process lives in one
}

/// Who a process belongs to: the simulator, the outermost .app it lives in, or its own executable name.
func owner(of path: String) -> Owner {
    if path.contains("/CoreSimulator/") { return Owner(name: simulatorGroup, bundle: nil) }
    if let r = path.range(of: ".app/") {
        let bundle = String(path[..<r.lowerBound]) + ".app"
        return Owner(name: (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""), bundle: bundle)
    }
    return Owner(name: (path as NSString).lastPathComponent, bundle: nil)
}

/// Shipped with macOS on the read-only system volume. /usr/local and /opt belong to the user.
func isMacOSPath(_ path: String) -> Bool {
    ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/", "/Library/Apple/"].contains(where: path.hasPrefix)
}

/// Apple's own apps (Notes, Safari from its cryptex): quittable, unlike Finder or Dock in CoreServices.
func isAppleApp(_ bundle: String?) -> Bool { bundle?.contains("/System/Applications/") ?? false }

/// Every process of one owner, summed.
struct Group: Equatable, Identifiable {
    var name: String
    var bundle: String?
    var path: String          // first process's path, shown for unknown groups
    var cpu = 0.0             // 100 = one core
    var rssKB = 0
    var seconds = 0           // the oldest process's running time
    var pids: [Int32] = []
    var uids: Set<UInt32> = []
    var id: String { name }
}

/// Groups by owner, busiest first.
func group(_ procs: [Proc]) -> [Group] {
    var byName: [String: Group] = [:]
    for p in procs {
        let o = owner(of: p.path)
        var g = byName[o.name] ?? Group(name: o.name, bundle: o.bundle, path: p.path)
        g.cpu += p.cpu
        g.rssKB += p.rssKB
        g.seconds = max(g.seconds, p.seconds)
        g.pids.append(p.pid)
        g.uids.insert(p.uid)
        byName[o.name] = g
    }
    return byName.values.sorted { ($0.cpu, $0.rssKB) > ($1.cpu, $1.rssKB) }
}

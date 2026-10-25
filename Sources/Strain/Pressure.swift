import Foundation

/// Every tunable number. Change here, rebuild.
enum Thresholds {
    static let hold = 3                  // samples a new level must persist (3 × 10 s)
    static let swapRateAmber = 50.0      // MB/min swapped out: actively paging to disk
    static let swapRateRed = 300.0       // MB/min: thrashing
    static let swapHuge = 0.5            // swap used above this share of RAM
    static let loadAmber = 2.0, loadRed = 4.0    // load average per core
    static let hogCPU = 80.0             // a group above this % CPU…
    static let hogSeconds = 1800.0       // …for this long is a hog
    static let cooldown = 1800.0         // no repeat notification for the same culprit
    static let interval = 10.0           // seconds between samples
    static let diskAmberGB = 10.0, diskRedGB = 3.0  // free space: below this macOS can't grow swap or caches
    static let checkDays = 7.0           // the background check runs at most this often…
    static let checkMinGB = 5.0          // …and only notifies when at least this much can go
    static let oldDownloadDays = 90.0    // a Downloads item nobody opened or changed for this long counts as old
    static let staleProjectDays = 30.0   // a project nobody touched for this long: its build folders count as stale
}

enum Level: Int, Comparable {
    case green, amber, red
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

struct Assessment: Equatable {
    var level: Level
    var reason: String
    var memory: Bool  // memory-driven: rank culprits by memory, not CPU
    var disk = false  // disk-driven: no process to blame
}

func gb(_ mb: Double) -> String { String(format: "%.1f", mb / 1024) }

func formatMemory(kb: Int) -> String {
    let mb = Double(kb) / 1024
    return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

/// The level right now, worst symptom first. Swap *size* alone is not strain: macOS grows the swap file on
/// demand and rarely shrinks it, so a big swap with normal pressure and no swapping is harmless.
func assess(_ s: SystemSample, swapRate: Double, _ groups: [Group], hogs: Set<String>,
            title: (String) -> String = { $0 }) -> Assessment {
    let load = s.load / Double(max(s.cores, 1))
    let loadReason = String(format: "CPU overloaded: load %.0f on %d cores", s.load, s.cores)
    let swapping = String(format: "Swapping to disk: %.0f MB/min", swapRate)
    let mem = { (level: Level, reason: String) in Assessment(level: level, reason: reason, memory: true) }
    if s.pressure >= 4 { return mem(.red, "Memory pressure is critical") }
    if swapRate > Thresholds.swapRateRed { return mem(.red, swapping) }
    let diskGB = s.diskFreeMB / 1024
    if diskGB < Thresholds.diskRedGB { return Assessment(level: .red, reason: String(format: "Disk almost full: %.1f GB free", diskGB), memory: false, disk: true) }
    if s.pressure >= 2, swapRate > Thresholds.swapRateAmber { return mem(.red, String(format: "Memory pressure is high, swapping %.0f MB/min", swapRate)) }
    if load > Thresholds.loadRed { return Assessment(level: .red, reason: loadReason, memory: false) }
    if s.pressure >= 2 { return mem(.amber, "Memory pressure is high") }
    if swapRate > Thresholds.swapRateAmber { return mem(.amber, swapping) }
    if s.memTotalMB > 0, s.swapUsedMB > s.memTotalMB * Thresholds.swapHuge {
        return mem(.amber, "\(gb(s.swapUsedMB)) GB swapped out, over half your RAM")
    }
    if diskGB < Thresholds.diskAmberGB { return Assessment(level: .amber, reason: String(format: "Disk nearly full: %.0f GB free", diskGB), memory: false, disk: true) }
    if load > Thresholds.loadAmber { return Assessment(level: .amber, reason: loadReason, memory: false) }
    if let hog = groups.first(where: { hogs.contains($0.name) }) {
        return Assessment(level: .amber, reason: "\(title(hog.name)) busy for \(Int(Thresholds.hogSeconds / 60))+ min", memory: false)
    }
    return Assessment(level: .green, reason: "Nothing is straining the Mac", memory: false)
}

struct Notice: Equatable {
    var level: Level, reason: String, culprit: String?  // nil: nothing running to blame (a full disk)
}

/// Turns raw samples into a steady level and decides when to notify.
struct Monitor {
    private(set) var level = Level.green
    private(set) var assessment = Assessment(level: .green, reason: "Nothing is straining the Mac", memory: false)
    private(set) var since = Date.now     // when the current level started
    private(set) var swapRate = 0.0       // MB/min swapped out over the last sample
    private var last: (swapOutMB: Double, at: Date)?
    private var pending: (level: Level, count: Int)?
    private var hogSince: [String: Date] = [:]
    private var notified: [String: Date] = [:]

    /// A lower level is waiting out its hold: the cause has eased but the level hasn't dropped yet.
    var easing: Bool { pending.map { $0.level < level } ?? false }

    /// Groups ranked for the current assessment.
    func ranked(_ groups: [Group]) -> [Group] {
        assessment.memory ? groups.sorted { $0.rssKB > $1.rssKB } : groups
    }

    /// Steps on a sample. Samples closer than ~one interval apart (a manual refresh, a refresh after Quit)
    /// are ignored: the hold count and swap rate assume the regular rhythm.
    mutating func step(_ s: SystemSample, _ groups: [Group], at now: Date, title: (String) -> String = { $0 }) -> Notice? {
        if let last, now.timeIntervalSince(last.at) < Thresholds.interval * 0.8 { return nil }
        if let last, now > last.at { swapRate = max(0, s.swapOutMB - last.swapOutMB) / now.timeIntervalSince(last.at) * 60 }
        last = (s.swapOutMB, now)
        for g in groups where g.cpu > Thresholds.hogCPU { hogSince[g.name] = hogSince[g.name] ?? now }
        let busy = Set(groups.filter { $0.cpu > Thresholds.hogCPU }.map(\.name))
        hogSince = hogSince.filter { busy.contains($0.key) }
        let hogs = Set(hogSince.filter { now.timeIntervalSince($0.value) >= Thresholds.hogSeconds }.keys)

        let raw = assess(s, swapRate: swapRate, groups, hogs: hogs, title: title)
        guard raw.level != level else {
            (pending, assessment) = (nil, raw)
            return nil
        }
        let count = pending?.level == raw.level ? pending!.count + 1 : 1
        guard count >= Thresholds.hold else {
            pending = (raw.level, count)
            return nil
        }
        let rising = raw.level > level
        (level, assessment, pending, since) = (raw.level, raw, nil, now)
        guard rising, let key = raw.disk ? "disk" : ranked(groups).first?.name else { return nil }
        if let last = notified[key], now.timeIntervalSince(last) < Thresholds.cooldown { return nil }
        notified[key] = now
        return Notice(level: raw.level, reason: raw.reason, culprit: raw.disk ? nil : key)
    }
}

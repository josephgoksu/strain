import Foundation

/// One row of `ps`. CPU is ps's own decayed %CPU (100 = one core).
struct Proc: Equatable {
    var pid: Int32, uid: UInt32, cpu: Double, rssKB: Int, seconds: Int, path: String
    var ppid: Int32 = 0, tty = ""  // tty "??": no terminal
}

let psArgs = ["-Ao", "pid=,uid=,pcpu=,rss=,etime=,ppid=,tty=,comm="]

/// Parses `ps -Ao pid=,uid=,pcpu=,rss=,etime=,ppid=,tty=,comm=`. comm is last, so a path keeps its spaces.
func parsePS(_ text: String) -> [Proc] {
    text.split(separator: "\n").compactMap { line in
        let f = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
        guard f.count == 8, let pid = Int32(f[0]), let uid = UInt32(f[1]), let cpu = Double(f[2]),
              let rss = Int(f[3]), let secs = parseElapsed(String(f[4])), let ppid = Int32(f[5]) else { return nil }
        let path = f[7].drop { $0 == " " }  // ps pads the tty column
        guard !path.hasPrefix("(") else { return nil }  // "(name)": ps's mark for a process that's exiting
        return Proc(pid: pid, uid: uid, cpu: cpu, rssKB: rss, seconds: secs, path: String(path), ppid: ppid, tty: String(f[6]))
    }
}

/// ps elapsed time: `[[dd-]hh:]mm:ss`.
func parseElapsed(_ s: String) -> Int? {
    let dayParts = s.split(separator: "-")
    guard dayParts.count <= 2 else { return nil }
    let days = dayParts.count == 2 ? Int(dayParts[0]) : 0
    let clock = dayParts.last!.split(separator: ":").map { Int($0) }
    guard let days, (2...3).contains(clock.count), !clock.contains(nil) else { return nil }
    return days * 86400 + clock.reduce(0) { $0 * 60 + $1! }
}

/// Runs ps, the one spawn left per tick (~20 ms CPU). It stays: /bin/ps is setuid root and reads every process,
/// while libproc as the user is refused for about a third of them (WindowServer, mds_stores, bluetoothd…), the
/// culprits Strain most needs to name.
func sampleProcesses() -> [Proc] { parsePS(run("/bin/ps", psArgs)) }

struct SystemSample: Equatable {
    var pressure: Int        // kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical
    var swapUsedMB: Double, swapTotalMB: Double  // total grows on demand, so used/total means little
    var load: Double         // 1-minute load average
    var cores: Int
    var memUsedMB = 0.0, memTotalMB = 0.0  // "Memory Used" as Activity Monitor counts it: app + wired + compressed
    var swapOutMB = 0.0      // cumulative since boot; the per-sample delta is the real "swapping now" signal
    var swapInMB = 0.0       // cumulative: swap read back into memory, the part you wait on
    var memory = MemoryBreakdown()
    var diskFreeMB = Double.greatestFiniteMagnitude  // startup disk, as Finder counts it; swap needs room here

    static func read() -> SystemSample {
        var pressure: Int32 = 1, cores: Int32 = 1, swap = xsw_usage(), load = [0.0], memsize: UInt64 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &cores, &size, nil, 0)
        size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memsize, &size, nil, 0)
        getloadavg(&load, 1)

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let page = Double(sysconf(_SC_PAGESIZE)) / 1_048_576
        let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
        let mb = { (b: UInt64) in Double(b) / 1_048_576 }
        let disk = Disk.read()
        return SystemSample(pressure: Int(pressure), swapUsedMB: mb(swap.xsu_used), swapTotalMB: mb(swap.xsu_total),
                            load: load[0], cores: Int(cores),
                            memUsedMB: (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page,
                            memTotalMB: mb(memsize), swapOutMB: Double(vm.swapouts) * page, swapInMB: Double(vm.swapins) * page,
                            memory: MemoryBreakdown(appMB: app * page, wiredMB: Double(vm.wire_count) * page,
                                                    compressedMB: Double(vm.compressor_page_count) * page,
                                                    compressedOriginalMB: Double(vm.total_uncompressed_pages_in_compressor) * page,
                                                    cachedMB: (Double(vm.external_page_count) + Double(vm.purgeable_count)) * page,
                                                    totalMB: mb(memsize)),
                            diskFreeMB: disk.total > 0 ? Double(disk.free) / 1_048_576 : .greatestFiniteMagnitude)  // unreadable ≠ full
    }
}

/// Activity Monitor's memory split. Used = app + wired + compressed; cached files are reclaimable on demand.
struct MemoryBreakdown: Equatable {
    var appMB = 0.0, wiredMB = 0.0, compressedMB = 0.0
    var compressedOriginalMB = 0.0  // what the compressed pages hold once expanded
    var cachedMB = 0.0, totalMB = 0.0
    var freeMB: Double { max(0, totalMB - appMB - wiredMB - compressedMB - cachedMB) }
}

/// Per-core tick counters since boot. UInt32 like the kernel's, so wrap-around subtracts cleanly.
struct CoreTicks: Equatable { var busy: UInt32, idle: UInt32 }

func readCoreTicks() -> [CoreTicks] {
    var count: natural_t = 0, infoCount: mach_msg_type_number_t = 0
    var info: processor_info_array_t?
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info
    else { return [] }
    defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
    return (0..<Int(count)).map { i in
        let t = { (state: Int32) in UInt32(bitPattern: info[i * Int(CPU_STATE_MAX) + Int(state)]) }
        return CoreTicks(busy: t(CPU_STATE_USER) &+ t(CPU_STATE_SYSTEM) &+ t(CPU_STATE_NICE), idle: t(CPU_STATE_IDLE))
    }
}

/// Busy fraction (0...1) of each core between two readings.
func coreUsage(_ old: [CoreTicks], _ new: [CoreTicks]) -> [Double] {
    guard old.count == new.count else { return [] }
    return zip(old, new).map { o, n in
        let busy = Double(n.busy &- o.busy), idle = Double(n.idle &- o.idle)
        return busy + idle > 0 ? busy / (busy + idle) : 0
    }
}

/// Apple silicon's core split. ponytail: assumes the kernel numbers Efficiency cores first (true on M1-M4,
/// checked with `ioreg -p IODeviceTree` cluster-type); Intel has one level, so every core is Performance.
struct CPUTopology {
    var performance: Int, efficiency: Int
    static let current: CPUTopology = {
        func int(_ name: String) -> Int {
            var v: Int32 = 0, size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : 0
        }
        guard int("hw.nperflevels") >= 2 else { return CPUTopology(performance: int("hw.ncpu"), efficiency: 0) }
        return CPUTopology(performance: int("hw.perflevel0.logicalcpu"), efficiency: int("hw.perflevel1.logicalcpu"))
    }()
    func isEfficiency(_ core: Int) -> Bool { core < efficiency }
}

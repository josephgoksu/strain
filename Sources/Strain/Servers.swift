import Foundation

/// One process listening on TCP ports.
struct Listener: Equatable {
    var pid: Int32, command: String, uid: UInt32
    var ports: [Int]
    var exposed: Bool  // bound beyond loopback: reachable from your network
}

/// TCP listeners, read in-process with libproc (~1 ms; lsof took ~20 ms of CPU plus a spawn every tick). Like lsof
/// without sudo, it sees only processes Strain may inspect: yours. Root-owned listeners stay invisible.
func readListeners() -> [Listener] {
    allPids().compactMap { pid -> Listener? in
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
        let got = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)) / MemoryLayout<proc_fdinfo>.size
        var ports: [Int] = [], exposed = false
        for fd in fds.prefix(max(got, 0)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let want = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, want) == want, si.psi.soi_kind == SOCKINFO_TCP,
                  si.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = si.psi.soi_proto.pri_tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            if !ports.contains(port) { ports.append(port) }
            if !isLoopback(ini) { exposed = true }
        }
        guard !ports.isEmpty else { return nil }
        var info = proc_bsdshortinfo()
        let uid = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0 ? info.pbsi_uid : 0
        return Listener(pid: pid, command: processName(pid), uid: uid, ports: ports.sorted(), exposed: exposed)
    }
}

/// 127.0.0.0/8 or ::1. Anything else (including * / 0.0.0.0) is reachable from the network.
private func isLoopback(_ ini: in_sockinfo) -> Bool {
    if ini.insi_vflag & UInt8(INI_IPV4) != 0 { return UInt32(bigEndian: ini.insi_laddr.ina_46.i46a_addr4.s_addr) >> 24 == 127 }
    var a = ini.insi_laddr.ina_6
    return withUnsafeBytes(of: &a) { $0.dropLast().allSatisfy { $0 == 0 } && $0.last == 1 }
}

func allPids() -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return pids.prefix(Int(max(n, 0))).filter { $0 > 0 }
}

func processName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    let n = Int(proc_name(pid, &buf, UInt32(buf.count)))
    return String(decoding: buf.prefix(max(n, 0)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// The process's working folder, or nil when it isn't ours to read.
func readCwd(_ pid: pid_t) -> String? {
    var v = proc_vnodepathinfo()
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
    let path = withUnsafeBytes(of: &v.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    return path.isEmpty ? nil : path
}

/// The full command line, like `ps -o args=`, from KERN_PROCARGS2: argc, the exec path, then argv, NUL-separated.
func readArgs(_ pid: pid_t) -> String? {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
    let fields = buf[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
    let argv = fields.dropFirst().prefix(Int(argc)).map { String(decoding: $0, as: UTF8.self) }  // dropFirst: the exec path
    return argv.isEmpty ? nil : argv.joined(separator: " ")
}

/// The project a server runs from, by its working folder. nil for "/", home itself and ~/Library.
/// ponytail: ~/Development/<area>/<repo> drops the area, a common layout (Development/products/app).
func project(cwd: String, home: String) -> String? {
    guard cwd.hasPrefix(home + "/") else { return nil }
    var comps = cwd.dropFirst(home.count + 1).split(separator: "/").map(String.init)
    guard let first = comps.first, first != "Library" else { return nil }
    if first == "Development", comps.count >= 3 { comps.removeFirst(2) }
    return comps.joined(separator: "/")
}

struct Server: Identifiable, Equatable {
    enum Kind: Int, Comparable {
        case dev, tool, app, macOS
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }
    var pid: Int32, uid: UInt32
    var command: String, path: String, args: String
    var ports: [Int], exposed: Bool
    var project: String?
    var cwd: String?          // working folder: the Clean tab keeps build folders of projects with a server running
    var kind: Kind
    var rssKB: Int, seconds: Int
    var id: Int32 { pid }
}

func servers(_ listeners: [Listener], procs: [Proc], cwds: [Int32: String], args: [Int32: String], home: String) -> [Server] {
    let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    return listeners.map { l in
        let p = byPid[l.pid]
        let path = p?.path ?? l.command
        let proj = cwds[l.pid].flatMap { project(cwd: $0, home: home) }
        let kind: Server.Kind = proj != nil ? .dev
            : isMacOSPath(path) ? .macOS
            : path.contains(".app/") ? .app : .tool
        return Server(pid: l.pid, uid: l.uid, command: l.command, path: path, args: args[l.pid] ?? path,
                      ports: l.ports, exposed: l.exposed, project: proj, cwd: cwds[l.pid], kind: kind,
                      rssKB: p?.rssKB ?? 0, seconds: p?.seconds ?? 0)
    }
    .sorted { ($0.kind, $0.ports.first ?? 0) < ($1.kind, $1.ports.first ?? 0) }
}

/// Listeners with their working folders and command lines: all libproc/sysctl, no spawns.
func sampleServers(procs: [Proc]) -> [Server] {
    let listeners = readListeners()
    let cwds = Dictionary(uniqueKeysWithValues: listeners.compactMap { l in readCwd(l.pid).map { (l.pid, $0) } })
    let args = Dictionary(uniqueKeysWithValues: listeners.compactMap { l in readArgs(l.pid).map { (l.pid, $0) } })
    return servers(listeners, procs: procs, cwds: cwds, args: args, home: NSHomeDirectory())
}

/// Runs a tool and returns its stdout. Killed after `timeout`: a hung tool must not freeze a tick or a tab.
func run(_ exe: String, _ args: [String], timeout: TimeInterval = 15) -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    p.qualityOfService = Thread.current.qualityOfService  // a tool started from a low-priority tick stays low-priority
    guard (try? p.run()) != nil else { return "" }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }  // isRunning: never signal a recycled pid
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return String(decoding: data, as: UTF8.self)
}

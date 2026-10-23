import Foundation

/// Ready-to-paste questions for any AI chat. Each carries the facts it needs, so the answer isn't generic.
enum Prompts {
    static func app(_ g: Group, title: String, entry: Explanations.Entry?, system s: SystemSample) -> String {
        var lines = [
            "On my Mac (\(gb(s.memTotalMB)) GB RAM, \(s.cores) cores), \"\(title)\" is using \(Int(g.cpu.rounded()))% CPU and \(formatMemory(kb: g.rssKB)), running for \(formatDuration(g.seconds)).",
            "Process name: \(g.name) (\(g.pids.count) process\(g.pids.count == 1 ? "" : "es"))",
            "Path: \(g.bundle ?? g.path)",
        ]
        if let entry { lines.append("My monitor says: \(entry.what)") }
        lines.append("What is it, is this usage normal, and should I stop it? If it's safe to stop, how?")
        return lines.joined(separator: "\n")
    }

    static func server(_ s: Server) -> String {
        let ports = s.ports.map { ":\($0)" }.joined(separator: ", ")
        var lines = [
            "A process on my Mac is listening on \(ports) (\(s.exposed ? "reachable from my network" : "local only")).",
            "Command: \(s.args)",
        ]
        if let p = s.project { lines.append("Started from project: \(p)") }
        lines.append("Running for \(formatDuration(s.seconds)), using \(formatMemory(kb: s.rssKB)).")
        lines.append("What is it, do I still need it, and how do I stop it cleanly\(s.exposed ? " or bind it to localhost only" : "")?")
        return lines.joined(separator: "\n")
    }

    static func background(_ i: BackgroundItem, title: String) -> String {
        let status = switch i.status { case .on: "allowed to run"; case .off: "turned off"; case .blocked: "blocked" }
        var lines = [
            "My Mac has a background item \"\(title)\": \(i.kind.singular), by \(i.developer ?? "an unsigned developer"), currently \(status)\(i.asRoot ? ", with admin (root) rights" : "").",
        ]
        if let path = i.url ?? i.executable { lines.append("File: \(path)") }
        lines.append("What does it do, do I need it, and how do I remove it safely?")
        return lines.joined(separator: "\n")
    }

    static func unknowns(_ list: [(name: String, path: String)]) -> String {
        """
        Add these to Resources/explanations.json in the strain repo (see context/growing-explanations.md).
        Each entry: "name": { "title": "<plain name>", "what": "<what it is>", "advice": "<what to do>" }.

        \(list.map { "\($0.name)\t\($0.path)" }.joined(separator: "\n"))
        """
    }

    static func slowMac(_ diagnostics: String) -> String {
        """
        My Mac feels slow. Here's a snapshot from my monitor, Strain:

        \(diagnostics)

        What's most likely causing it, and what should I close or change first?
        """
    }

    static func disk(_ disk: Disk, sizes: [(String, Int64)]) -> String {
        """
        My Mac's disk has \(disk.summary). Caches Strain can see:

        \(sizes.map { "  \($0.0): \(formatBytes($0.1))" }.joined(separator: "\n"))

        What else usually fills a Mac's disk, and which commands show where the rest of the space went? Only safe deletions, please.
        """
    }
}

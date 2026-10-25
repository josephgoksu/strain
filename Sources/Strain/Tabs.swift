import ServiceManagement
import SwiftUI

/// The one-line bar above each tab's list: a summary on the left, the tab's own actions on the right.
struct TabToolbar: View {
    @Environment(Store.self) private var store
    @AppStorage("showMacOSServers") private var showMacOS = false

    var body: some View {
        if let meter = store.meter { meterBar(meter) } else { tabBar }
    }

    /// While a meter's details are open, this row names them and closes them.
    private func meterBar(_ m: MeterKind) -> some View {
        HStack(spacing: 4) {
            Text(m.detailTitle)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Button { withAnimation(.snappy(duration: 0.25)) { store.meter = nil } } label: {
                Label("Close", systemImage: "xmark").font(.caption)
            }
            .buttonStyle(HoverButtonStyle()).keyboardShortcut(.cancelAction)
        }
        .frame(height: 24)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            Text(summary).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .contentTransition(.numericText()).lineLimit(1)
            Spacer()
            switch store.tab {
            case .apps:
                Menu {
                    Picker("Sort by", selection: Binding(get: { store.activeSort }, set: { store.sort = $0 })) {
                        Label("Memory", systemImage: "memorychip").tag(Sort.memory)
                        Label("CPU", systemImage: "cpu").tag(Sort.cpu)
                    }
                    .pickerStyle(.inline)
                    if store.sort != nil { Button("Follow the Strain") { store.sort = nil } }
                } label: {
                    Label(store.activeSort.rawValue, systemImage: "arrow.up.arrow.down").font(.caption)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Sort by")
            case .servers:
                IconButton(symbol: showMacOS ? "eye.fill" : "eye.slash", help: showMacOS ? "Hide macOS services" : "Show macOS services") {
                    withAnimation(.snappy) { showMacOS.toggle() }
                }
            case .background:
                if store.background != nil {
                    IconButton(symbol: "arrow.clockwise", help: store.helper == .enabled ? "Read the list again" : "Read the list again (macOS asks for Touch ID)", spinning: store.loadingBackground) {
                        Task { await store.loadBackground() }
                    }
                }
                IconButton(symbol: "gearshape", help: "Open Login Items in System Settings") { SMAppService.openSystemSettingsLoginItems() }
            case .controls:
                EmptyView()
            case .clean:
                AskAIButton(help: "Ask AI what else is filling the disk.") {
                    Prompts.disk(store.disk, sizes: Cleanup.items.map { ($0.title, store.cleanSizes?[$0.id] ?? 0) }
                                 + [("Project build folders", (store.projects ?? []).reduce(0) { $0 + $1.size }),
                                    ("Simulator data", store.simulators.reduce(0) { $0 + $1.size })])
                }
            case .unknown:
                if !store.logged.isEmpty {
                    ConfirmButton(title: "Clear", confirm: "Clear list?", symbol: "trash") { withAnimation { store.clearLog() } }
                        .help("Clear the processes logged under strain (after you've added them)")
                }
                AskAIButton(help: "Ask AI to write explanations for all of these.") { Prompts.unknowns(store.unknowns) }
                    .disabled(store.unknowns.isEmpty)
            }
        }
        .frame(height: 24)
    }

    private var summary: String {
        switch store.tab {
        case .apps:
            return store.monitor.level == .green ? "Top consumers" : "Likely culprits"
        case .servers:
            let shown = store.servers.filter { showMacOS || $0.kind != .macOS }
            return shown.isEmpty ? "Nothing listening" : "\(shown.count) listening · \(shown.filter(\.exposed).count) open to your network"
        case .background:
            guard let items = store.background else { return store.loadingBackground ? "Waiting for Touch ID…" : "Not read yet" }
            let on = items.filter { $0.status == .on }
            let running = items.filter { runningGroup(for: $0, in: store.groups) != nil }.count
            return "\(on.count) allowed · \(running) running · \(on.filter(\.asRoot).count) admin"
        case .controls:
            let parts = [store.wifi.map { "Wi-Fi \($0 ? "on" : "off")" }, store.bluetooth.map { "Bluetooth \($0 ? "on" : "off")" },
                         store.awdlUp.map { _ in "AirDrop \(store.airDropBlocker == nil ? "on" : "off")" }].compactMap { $0 }  // unknown = left out
            return parts.joined(separator: " · ")
        case .clean:
            guard store.cleanSizes != nil else { return "Measuring caches, projects and simulators…" }
            return "\(formatBytes(store.cleanable)) you can clean"
        case .unknown:
            return store.unknowns.isEmpty ? "Everything is explained" : "\(store.unknowns.count) not explained yet"
        }
    }
}

// MARK: - Apps

struct AppsTab: View {
    @Environment(Store.self) private var store
    @AppStorage("rows") private var rows = 5

    var body: some View {
        LazyVStack(spacing: 2) {
            if !store.forgotten.isEmpty {
                CleanSection(title: "Forgotten", symbol: "moon.zzz", detail: "\(store.forgotten.count)")
                ForEach(store.forgotten) { ForgottenRow(lost: $0) }
                CleanSection(title: "All apps", symbol: "square.stack.3d.up")
            }
            ForEach(store.culprits.prefix(max(rows, 12))) { AppRow(group: $0) }
        }
    }
}

/// Something started and forgotten, and why. Quit (confirmed) or Keep (never listed again).
struct ForgottenRow: View {
    @Environment(Store.self) private var store
    let lost: Lost

    var body: some View {
        let g = lost.group, title = lost.label ?? store.title(g)
        HStack(spacing: 10) {
            SwiftUI.Group {
                if g.bundle != nil { AppGroupIcon(group: g) } else { SymbolTile(symbol: symbol, tint: .orange) }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(.body.weight(.semibold)).lineLimit(1)
                    if g.pids.count > 1 { Text("×\(g.pids.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Text("\(lost.why()) · \(formatMemory(kb: g.rssKB))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(g.path)
            }
            Spacer(minLength: 6)
            Button("Keep") { withAnimation(.snappy) { store.keep(lost) } }
                .buttonStyle(HoverButtonStyle()).font(.caption)
                .help("Leave it running and never list \(title) here again. Undo in ⋯ → Kept.")
            ConfirmButton(title: "Quit", confirm: "Quit \(title)?", symbol: "xmark.circle.fill") {
                withAnimation(.snappy) { store.quitForgotten(lost) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var symbol: String {
        switch lost.reason {
        case .terminalClosed: "terminal"
        case .unused: "app.dashed"
        case .idle: "memorychip"
        case .server: "network"
        }
    }
}

struct AppRow: View {
    @Environment(Store.self) private var store
    let group: Group

    var body: some View {
        let entry = store.explanations.entry(group.name, path: group.path)
        let byMemory = store.activeSort == .memory
        let s = store.system
        ExpandableRow(id: group.name) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    AppGroupIcon(group: group).frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(store.title(group)).font(.body.weight(.semibold)).lineLimit(1)
                            if group.pids.count > 1 {
                                Text("×\(group.pids.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if entry == nil { Pill(text: "Unknown", color: .orange) }
                        }
                        Text(entry?.what ?? group.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(entry == nil ? .middle : .tail)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(byMemory ? formatMemory(kb: group.rssKB) : "\(Int(group.cpu.rounded()))%")
                            .font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                            .contentTransition(.numericText(value: byMemory ? Double(group.rssKB) : group.cpu))
                        Text(byMemory ? "\(Int(group.cpu.rounded()))% CPU" : formatMemory(kb: group.rssKB))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Bar(fraction: byMemory ? Double(group.rssKB) / 1024 / max(s.memTotalMB, 1) : group.cpu / Double(max(s.cores, 1) * 100),
                    tint: .accentColor, height: 3)
                    .padding(.leading, 40)
            }
        } details: {
            VStack(alignment: .leading, spacing: 8) {
                if let what = entry?.what, what.count > 50 {  // longer than the header's one line shows
                    Text(what).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(entry?.advice ?? "Not in Strain's table yet. Copy the prompt to ask an AI what it is.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Facts(rows: [("Running", formatDuration(group.seconds)), ("Processes", "\(group.pids.count)"), ("Path", group.bundle ?? group.path)])
                HStack(spacing: 2) {
                    let a = action(for: group)
                    switch a {
                    case .none:
                        Label("macOS service", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    default:
                        let shut = a == .shutdownSimulators
                        ConfirmButton(title: shut ? "Shut Down" : "Quit",
                                      confirm: shut ? "Shut down all?" : group.pids.count > 1 ? "Quit \(group.pids.count)?" : "Quit?",
                                      symbol: shut ? "power" : "xmark.circle.fill") {
                            perform(a, on: group)
                            Task { try? await Task.sleep(for: .seconds(1)); await store.tick() }
                        }
                    }
                    Spacer()
                    AskAIButton(help: "Ask AI what this is and whether to stop it.") {
                        Prompts.app(group, title: store.title(group), entry: entry, system: store.system)
                    }
                    if (group.bundle ?? group.path).hasPrefix("/") {
                        IconButton(symbol: "folder", help: "Reveal in Finder") { reveal(group.bundle ?? group.path) }
                    }
                    IconButton(symbol: "waveform.path.ecg.rectangle", help: "Open Activity Monitor", action: openActivityMonitor)
                }
            }
        }
        .contextMenu {
            Button("Copy Name") { copy(store.title(group)) }
            Button("Copy Path") { copy(group.bundle ?? group.path) }
            Button("Copy Prompt for AI") { copy(Prompts.app(group, title: store.title(group), entry: entry, system: store.system)) }
        }
    }
}

struct AppGroupIcon: View {
    let group: Group
    var body: some View {
        if let bundle = group.bundle {
            BundleIcon(path: bundle)
        } else {
            SymbolTile(symbol: group.name == simulatorGroup ? "iphone" : "gearshape.fill")
        }
    }
}

// MARK: - Servers

struct ServersTab: View {
    @Environment(Store.self) private var store
    @AppStorage("showMacOSServers") private var showMacOS = false

    var body: some View {
        let shown = store.servers.filter { showMacOS || $0.kind != .macOS }
        if shown.isEmpty {
            Empty(symbol: "network.slash", title: "Nothing is listening", text: "No dev servers, tunnels or apps have open ports.")
        } else {
            LazyVStack(spacing: 2) {
                ForEach(shown) { ServerRow(server: $0) }
            }
        }
    }
}

struct ServerRow: View {
    @Environment(Store.self) private var store
    let server: Server

    var body: some View {
        let s = server
        let o = owner(of: s.path)
        let canStop = s.uid == getuid() && s.kind != .macOS
        let url = s.ports.first.map { "http://localhost:\($0)" }
        ExpandableRow(id: String(s.pid)) {
            HStack(alignment: .top, spacing: 10) {
                SwiftUI.Group {
                    if s.kind == .app, let b = o.bundle { BundleIcon(path: b) } else {
                        SymbolTile(symbol: s.kind == .dev ? "chevron.left.forwardslash.chevron.right" : s.kind == .tool ? "terminal" : "gearshape.fill",
                                   tint: s.kind == .dev ? .accentColor : .secondary)
                    }
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(s.project ?? store.explanations.title(o.name)).font(.body.weight(.semibold)).lineLimit(1)
                        Pill(text: s.exposed ? "Network" : "Local", color: s.exposed ? .orange : .secondary,
                             symbol: s.exposed ? "wifi" : "lock.fill")
                    }
                    HStack(spacing: 4) {
                        ForEach(s.ports, id: \.self) { port in
                            Text(":\(String(port))").font(.caption.monospaced().weight(.medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                        }
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatMemory(kb: s.rssKB)).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                    Text("up \(formatDuration(s.seconds))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } details: {
            VStack(alignment: .leading, spacing: 8) {
                Text(s.args).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Facts(rows: [("PID", String(s.pid)), ("Reach", s.exposed ? "Other devices on your network" : "This Mac only")])
                HStack(spacing: 2) {
                    if canStop {
                        ConfirmButton(title: "Stop", confirm: "Stop :\(s.ports.first.map(String.init) ?? "")?", symbol: "stop.circle.fill") {
                            for pid in stillOwned([s.pid], by: o.name) { kill(pid, SIGTERM) }
                            Task { try? await Task.sleep(for: .seconds(1)); await store.tick() }
                        }
                    } else {
                        Label(s.kind == .macOS ? "macOS service" : "Another user's", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if s.kind != .macOS, let url {
                        IconButton(symbol: "safari", help: "Open \(url)") { NSWorkspace.shared.open(URL(string: url)!) }
                        CopyButton(symbol: "link", help: "Copy \(url)") { url }
                    }
                    AskAIButton(help: "Ask AI what this server is and whether you still need it.") { Prompts.server(s) }
                    CopyButton(symbol: "terminal", help: "Copy the command") { s.args }
                }
            }
        }
        .contextMenu {
            Button("Copy Command") { copy(s.args) }
            Button("Copy PID") { copy(String(s.pid)) }
            if let url { Button("Copy \(url)") { copy(url) } }
            Button("Copy Prompt for AI") { copy(Prompts.server(s)) }
        }
    }
}

// MARK: - Background

struct BackgroundTab: View {
    @Environment(Store.self) private var store
    private let order: [BackgroundItem.Kind] = [.openAtLogin, .backgroundTasks, .agent, .daemon, .loginHelper]

    var body: some View {
        SwiftUI.Group {
            if let items = store.background {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    ForEach(order, id: \.self) { kind in
                        let rows = items.filter { $0.kind == kind }
                        if !rows.isEmpty {
                            Label(kind.rawValue.uppercased(), systemImage: kindSymbol(kind))
                                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                            ForEach(rows) { BackgroundRow(item: $0) }
                        }
                    }
                    Text("Read \(store.backgroundRead.map { $0.formatted(.relative(presentation: .named)) } ?? "just now"). Strain never switches these off; use the gear to open Login Items in System Settings.")
                        .font(.caption).foregroundStyle(.secondary).padding(10)
                }
            } else {
                ReadLoginItems()
            }
        }
        .task { if store.background == nil, store.helper == .enabled { await store.loadBackground(prompting: false) } }  // the helper never prompts
    }
}

/// First visit: reading Login Items needs admin, so it waits for a click instead of prompting on its own.
struct ReadLoginItems: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: store.loadingBackground ? "touchid" : "lock.shield").font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary).symbolEffect(.pulse, isActive: store.loadingBackground)
            Text(store.loadingBackground ? "Waiting for Touch ID…" : "See what starts without you").font(.headline)
            Text("macOS only shares its Login Items list with admin rights, so it asks for Touch ID or your password. Strain keeps the list and asks again only when you refresh it.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if store.backgroundFailed && !store.loadingBackground {
                Label("Cancelled or timed out", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Button { Task { await store.loadBackground() } } label: {
                Label("Read Login Items", systemImage: "touchid")
            }
            .controlSize(.large).buttonStyle(.borderedProminent).disabled(store.loadingBackground)
        }
        .padding(.horizontal, 24).frame(maxWidth: .infinity).padding(.top, 36)
    }
}

func kindSymbol(_ k: BackgroundItem.Kind) -> String {
    switch k {
    case .openAtLogin: "power"
    case .loginHelper: "person.badge.key"
    case .backgroundTasks: "clock.arrow.circlepath"
    case .agent: "gearshape.2"
    case .daemon: "lock.shield"
    }
}

struct BackgroundRow: View {
    @Environment(Store.self) private var store
    let item: BackgroundItem

    var body: some View {
        let e = item.explain(store.explanations)
        let title = item.title(store.explanations)
        let running = runningGroup(for: item, in: store.groups)
        ExpandableRow(id: item.id) {
            HStack(spacing: 10) {
                ItemIcon(item: item).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title).font(.body.weight(.semibold)).lineLimit(1)
                        switch item.status {
                        case .on: EmptyView()
                        case .off: Pill(text: "Off", color: .secondary)
                        case .blocked: Pill(text: "Blocked", color: .orange, symbol: "hand.raised.fill")
                        }
                        if item.asRoot { Pill(text: "Admin", color: .purple, symbol: "lock.shield.fill") }
                        if item.missing {
                            Pill(text: "Leftover", color: .orange, symbol: "questionmark.app")
                                .help("Its app or launch file is gone, so it can't run: a leftover of a removed app. Turn it off in Login Items.")
                        } else if let badge = item.target.flatMap({ store.signing[$0] }) {
                            Pill(text: badge, color: .orange, symbol: "exclamationmark.shield")
                                .help(badge == "Unsigned" ? "No valid code signature: nobody vouches for this program. Keep it only if you know what installed it."
                                                         : "Gatekeeper wouldn't open this app as downloaded: Apple hasn't checked it. Fine for apps you built yourself.")
                        }
                    }
                    Text(e.what).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let running {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatMemory(kb: running.rssKB)).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                        HStack(spacing: 3) {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text("Running").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(item.status == .on ? "Idle" : "").font(.caption).foregroundStyle(.secondary)
                }
            }
        } details: {
            VStack(alignment: .leading, spacing: 8) {
                Text(e.advice).font(.callout).fixedSize(horizontal: false, vertical: true)
                Facts(rows: [("By", item.developer ?? "Unsigned"), ("Kind", item.kind.rawValue)]
                      + [(item.label != nil ? "Label" : "File", item.label ?? item.url ?? item.executable ?? "none")])
                HStack(spacing: 2) {
                    Button { SMAppService.openSystemSettingsLoginItems() } label: {
                        Label("Login Items", systemImage: "gearshape")
                    }
                    .buttonStyle(HoverButtonStyle())
                    Spacer()
                    AskAIButton(help: "Ask AI what this item does and how to remove it safely.") { Prompts.background(item, title: title) }
                    if let path = item.url ?? item.executable {
                        IconButton(symbol: "folder", help: "Reveal in Finder") { reveal(path) }
                    }
                }
            }
        }
        .contextMenu {
            if let path = item.url ?? item.executable { Button("Copy Path") { copy(path) } }
            Button("Copy Prompt for AI") { copy(Prompts.background(item, title: title)) }
        }
    }
}

struct ItemIcon: View {
    let item: BackgroundItem
    var body: some View {
        if let path = appPath { BundleIcon(path: path) } else {
            SymbolTile(symbol: kindSymbol(item.kind), tint: item.asRoot ? .purple : .secondary)
        }
    }

    private var appPath: String? {
        IconCache.appPath(item.id) {
            if let url = item.url, url.hasSuffix(".app") { return url }
            if let id = item.bundleID, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u.path }
            guard let app = item.app else { return nil }
            return ["/Applications", NSHomeDirectory() + "/Applications", "/Applications/Setapp"]
                .map { "\($0)/\(app).app" }.first { FileManager.default.fileExists(atPath: $0) }
        }
    }
}

// MARK: - Unknown

struct UnknownTab: View {
    @Environment(Store.self) private var store

    var body: some View {
        let list = store.unknowns
        if list.isEmpty {
            Empty(symbol: "checkmark.seal", title: "Everything is explained", text: "Every busy process has a plain-English entry.")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text("Copy the prompt, paste it into your AI coding agent in the strain repo, rebuild. These then get names and advice.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 4)
                ForEach(list, id: \.name) { u in
                    UnknownRow(name: u.name, path: u.path, logged: store.logged.contains { $0.name == u.name })
                }
            }
        }
    }
}

struct UnknownRow: View {
    let name: String, path: String, logged: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            SymbolTile(symbol: "questionmark", tint: .orange).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                    if logged { Pill(text: "Seen under strain", color: .orange, symbol: "flame.fill") }
                }
                Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            CopyButton(symbol: "sparkles", copiedLabel: "Copied", help: "Ask AI about just this one: copies a prompt to paste into an AI chat.") {
                Prompts.unknowns([(name, path)])
            }
            .opacity(hover ? 1 : 0.5)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(hover ? 0.04 : 0)))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

// MARK: - Empty state

struct Empty: View {
    let symbol: String, title: String, text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                .symbolEffect(.bounce, value: title)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 50)
    }
}

// MARK: - Clean

/// Switches and one-click fixes: radios, the AirDrop link, and stock macOS repairs, grouped by what they're for.
struct ControlsTab: View {
    @Environment(Store.self) private var store
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            CleanSection(title: "Keep awake", symbol: "cup.and.saucer")
            AwakeCard().padding(.horizontal, 10).padding(.bottom, 6)
            CleanSection(title: "Connections", symbol: "wifi")
            HStack(spacing: 6) {
                if store.wifi != nil { RadioTile(id: "wifi", title: "Wi-Fi", on: "wifi", off: "wifi.slash", state: store.wifi) }
                if store.bluetooth != nil {
                    RadioTile(id: "bluetooth", title: "Bluetooth", on: "antenna.radiowaves.left.and.right",
                              off: "antenna.radiowaves.left.and.right.slash", state: store.bluetooth)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            if store.awdlUp != nil { AWDLCard().padding(.horizontal, 10).padding(.bottom, 6) }
            if !store.screens.isEmpty {
                CleanSection(title: "Displays", symbol: "display")
                ForEach(store.screens) { ScreenCard(screen: $0).padding(.horizontal, 10).padding(.bottom, 6) }
                if store.displayKeys || store.screens.contains(where: \.ddc) {  // keys only drive external monitors
                    DisplayKeysRow().padding(.horizontal, 10).padding(.bottom, 6)
                }
            }
            ForEach(QuickAction.Group.allCases, id: \.self) { group in
                CleanSection(title: group.rawValue, symbol: symbol(group))
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(QuickAction.all.filter { $0.group == group }) { ActionTile(action: $0) }
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
            }
            HelperFooter()
        }
        .task {
            async let screens: Void = store.refreshScreens()
            await store.refreshRadios()
            await screens
        }
    }

    private func symbol(_ g: QuickAction.Group) -> String {
        switch g {
        case .fix: "wrench.and.screwdriver"
        case .network: "network"
        case .utilities: "bolt.fill"
        }
    }
}

struct CleanTab: View {
    @Environment(Store.self) private var store

    var body: some View {
        let d = store.disk
        LazyVStack(alignment: .leading, spacing: 2) {
            CleanSection(title: "Free up space", symbol: "internaldrive") {
                if store.scanning {
                    ProgressView().controlSize(.mini)
                } else if store.cleanSizes != nil {
                    Button { Task { await store.checkNow() } } label: { Label("Check now", systemImage: "arrow.clockwise") }
                        .buttonStyle(HoverButtonStyle()).font(.caption)
                        .help("Measure every section again. Strain also checks once a week on its own and tells you; it never deletes without your click.")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Bar(fraction: d.total > 0 ? 1 - Double(d.free) / Double(d.total) : 0, tint: d.free < d.total / 10 ? .red : .accentColor)
                Text(d.summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if store.cleanSizes != nil {
                    // The total already heads the tab: name the largest parts and when they were measured.
                    Text(([store.cleanParts.isEmpty ? nil : "Largest: " + Store.checkLine(store.cleanParts),
                           store.lastCheck.map { "checked \($0.formatted(.relative(presentation: .named)))" }].compactMap { $0 })
                        .joined(separator: " · "))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Measuring…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
            // Empty or missing caches (a tool you don't use) stay hidden; a row you just cleaned stays to show the result.
            ForEach(Cleanup.items.filter { $0.bundleID == nil && shown($0) }.sorted { (store.cleanSizes?[$0.id] ?? 0) > (store.cleanSizes?[$1.id] ?? 0) }) { CleanRow(item: $0) }
            AIToolsSection()
            ProjectsSection()
            SimulatorsSection()
            SpaceSection()
            Text("Only things tools rebuild on their own: caches, build folders, simulator data. Apple's and running apps' caches are skipped.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .task { if store.cleanSizes == nil { await store.checkNow() } }
    }

    private func shown(_ item: CleanItem) -> Bool {
        guard let sizes = store.cleanSizes else { return true }
        return (sizes[item.id] ?? 0) > 0 || store.cleaning.contains(item.id) || store.cleaned[item.id] != nil
    }
}

/// Section label for the Clean tab, with an optional control on the right.
struct CleanSection<Accessory: View>: View {
    let title: String, symbol: String
    var detail: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 6) {
            Label(title.uppercased(), systemImage: symbol).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            Spacer()
            accessory
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
    }
}

extension CleanSection where Accessory == EmptyView {
    init(title: String, symbol: String, detail: String? = nil) { self.init(title: title, symbol: symbol, detail: detail) { EmptyView() } }
}

/// Build folders across your projects. Stale = nobody touched the project (files, installs, git) for `Thresholds.staleProjectDays`.
/// AI tools: their web caches (Clean, while the app is closed) and their data (size and Finder only).
struct AIToolsSection: View {
    @Environment(Store.self) private var store

    var body: some View {
        let caches = Cleanup.items.filter { $0.bundleID != nil && ((store.cleanSizes?[$0.id] ?? 0) > 0 || store.cleaned[$0.id] != nil) }
        let data = AIData.all.filter { (store.aiData[$0.id]?.size ?? 0) > 0 }
        if !caches.isEmpty || !data.isEmpty {
            let total = caches.reduce(0) { $0 + (store.cleanSizes?[$1.id] ?? 0) } + data.reduce(0) { $0 + (store.aiData[$1.id]?.size ?? 0) }
            CleanSection(title: "AI tools", symbol: "sparkles", detail: formatBytes(total))
            ForEach(caches) { CleanRow(item: $0) }
            ForEach(data.sorted { (store.aiData[$0.id]?.size ?? 0) > (store.aiData[$1.id]?.size ?? 0) }) { AIDataRow(place: $0) }
        }
    }
}

/// A tool's data: models or transcripts. Strain never deletes it; Finder (or the tool) does, one choice at a time.
struct AIDataRow: View {
    @Environment(Store.self) private var store
    let place: AIData

    var body: some View {
        let entry = store.aiData[place.id], models = entry?.models ?? []
        HStack(spacing: 10) {
            SymbolTile(symbol: place.symbol, tint: .purple).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(place.title).font(.body.weight(.semibold)).lineLimit(1)
                    Pill(text: "Your data", color: .secondary)
                }
                Text(models.isEmpty ? place.detail : models.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(place.detail + (models.isEmpty ? "" : "\n" + models.joined(separator: "\n")))
            }
            Spacer(minLength: 6)
            Text(formatBytes(entry?.size ?? 0)).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
            IconButton(symbol: "folder", help: "Show in Finder") { reveal(place.url().path) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

/// Where the space went: largest folders and old downloads. Measured only on a click, never in the total.
struct SpaceSection: View {
    @Environment(Store.self) private var store

    var body: some View {
        CleanSection(title: "Where the space went", symbol: "chart.pie") {
            if store.measuringSpace {
                ProgressView().controlSize(.mini)
            } else {
                Button { Task { await store.measureSpace() } } label: { Label(store.space == nil ? "Measure" : "Again", systemImage: "ruler") }
                    .buttonStyle(HoverButtonStyle()).font(.caption)
                    .help("Sizes every folder in your home folder. Takes a minute or two; macOS may ask once for Desktop, Documents or Downloads.")
            }
        }
        if let space = store.space {
            ForEach(space.folders) { entry in
                SpaceRow(entry: entry, title: "~/" + Space.relative(entry.path, NSHomeDirectory()), caption: nil)
            }
            if !space.downloads.isEmpty {
                CleanSection(title: "Old downloads", symbol: "arrow.down.circle",
                             detail: "\(formatBytes(space.downloads.reduce(0) { $0 + $1.size })) untouched \(Int(Thresholds.oldDownloadDays))+ days")
                ForEach(space.downloads) { entry in
                    SpaceRow(entry: entry, title: (entry.path as NSString).lastPathComponent,
                             caption: entry.untouched.map { "Last opened " + $0.formatted(.relative(presentation: .named)) }, trash: true)
                }
            }
        } else if !store.measuringSpace {
            Text("Largest folders in your home folder, and downloads you haven't opened in \(Int(Thresholds.oldDownloadDays)) days.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
        } else {
            Text("Measuring your home folder…").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
        }
    }
}

struct SpaceRow: View {
    @Environment(Store.self) private var store
    let entry: SpaceEntry, title: String, caption: String?
    var trash = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if store.cleaned["dl." + entry.path] != nil { Text("Couldn't move it to the Trash").font(.caption).foregroundStyle(.orange) }
            }
            Spacer(minLength: 6)
            Text(formatBytes(entry.size)).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
            if trash {
                ConfirmButton(title: "Trash", confirm: "Move to Trash?", symbol: "trash") { withAnimation(.snappy) { store.trashDownload(entry) } }
                    .help("Moves it to the Trash. Empty the Trash to free the space; until then you can put it back.")
            }
            IconButton(symbol: "folder", help: "Show in Finder") { reveal(entry.path) }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

struct ProjectsSection: View {
    @Environment(Store.self) private var store

    var body: some View {
        if store.devRoots.isEmpty { EmptyView() } else if let projects = store.projects {
            let stale = projects.filter { $0.stale() && !store.running($0) }
            let total = projects.reduce(0) { $0 + $1.size }
            CleanSection(title: "Project build folders", symbol: "folder.badge.gearshape",
                         detail: projects.isEmpty ? nil : "\(formatBytes(total)) in \(projects.count)") {
                if store.cleaning.contains("proj.stale") {
                    ProgressView().controlSize(.mini)
                } else if !stale.isEmpty {
                    ConfirmButton(title: "Clean \(stale.count) stale", confirm: "Delete \(formatBytes(stale.reduce(0) { $0 + $1.size }))?",
                                  symbol: "sparkles") { withAnimation(.snappy) { store.deleteBuildFolders(stale, id: "proj.stale") } }
                        .help("Delete build folders of projects untouched for \(Int(Thresholds.staleProjectDays))+ days. They come back on the next install or build.")
                }
            }
            if let r = store.cleaned["proj.stale"] {
                Label("Freed \(formatBytes(r.freed)) from stale projects" + (r.left > 0 ? ", \(r.left) left" : ""), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).padding(.horizontal, 10)
            }
            if projects.isEmpty {
                Text("No node_modules, target or .build folders in \(store.devRoots.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            ForEach(projects.prefix(30)) { ProjectRow(project: $0) }
            if projects.count > 30 {
                Text("\(projects.count - 30) smaller projects not shown.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
        } else {
            CleanSection(title: "Project build folders", symbol: "folder.badge.gearshape", detail: "measuring…")
        }
    }
}

struct ProjectRow: View {
    @Environment(Store.self) private var store
    let project: DevProject

    var body: some View {
        let id = "proj." + project.path, busy = store.cleaning.contains(id), running = store.running(project)
        let root = store.devRoots.first { project.path.hasPrefix($0 + "/") }
        let name = root.map { String(project.path.dropFirst($0.count + 1)) } ?? project.path
        ExpandableRow(id: id) {
            HStack(spacing: 10) {
                SymbolTile(symbol: symbol, tint: project.stale() ? .secondary : .accentColor).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(name).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.head)
                        if running { Pill(text: "Running", color: .green, symbol: "play.fill") }
                    }
                    Text(project.artifacts.map(\.name).joined(separator: " · ") + " · touched " + project.lastActive.formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if busy { ProgressView().controlSize(.mini) } else {
                    Text(formatBytes(project.size)).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                        .foregroundStyle(project.size > 1_000_000_000 ? .primary : .secondary)
                }
            }
        } details: {
            VStack(alignment: .leading, spacing: 8) {
                Facts(rows: project.artifacts.map { ($0.name, formatBytes($0.size)) } + [("Folder", project.path)])
                HStack(spacing: 2) {
                    if running {
                        Label("A server runs from here; stop it first", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    } else if !busy {
                        ConfirmButton(title: "Delete build folders", confirm: "Delete \(formatBytes(project.size))?", symbol: "sparkles") {
                            withAnimation(.snappy) { store.deleteBuildFolders([project], id: id) }
                        }
                    }
                    Spacer()
                    IconButton(symbol: "folder", help: "Reveal in Finder") { reveal(project.path) }
                }
                Text("They come back with the next npm/bun install, cargo build or swift build.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var symbol: String {
        let names = Set(project.artifacts.map(\.name))
        return names.contains("target") ? "gearshape.2" : names.contains(".build") ? "swift" : "shippingbox"
    }
}

/// iOS simulators: each one's data grows with every app run on it. Erase keeps the simulator, drops its data.
struct SimulatorsSection: View {
    @Environment(Store.self) private var store

    var body: some View {
        let sims = store.simulators.filter { $0.size > 0 || !$0.available }
        let unavailable = store.simulators.filter { !$0.available }.count
        if !store.runtimes.isEmpty {
            CleanSection(title: "Unused simulator runtimes", symbol: "externaldrive.badge.minus",
                         detail: formatBytes(store.runtimes.reduce(0) { $0 + $1.size }))
            ForEach(store.runtimes) { RuntimeRow(runtime: $0) }
        }
        if store.archives > 0 {
            CleanSection(title: "Xcode Archives", symbol: "archivebox", detail: formatBytes(store.archives)) {
                Button { NSWorkspace.shared.open(Store.archivesURL) } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(HoverButtonStyle()).font(.caption)
                    .help("The builds you archived for TestFlight or the App Store. Yours to keep: Strain won't delete them. Remove old ones in Finder or Xcode's Organizer.")
            }
        }
        if !sims.isEmpty {
            CleanSection(title: "Simulators", symbol: "iphone", detail: formatBytes(sims.reduce(0) { $0 + $1.size })) {
                if unavailable > 0 {
                    ConfirmButton(title: "Delete \(unavailable) unavailable", confirm: "Delete \(unavailable)?", symbol: "trash") {
                        store.deleteUnavailableSimulators()
                    }
                    .help("Simulators for iOS versions no longer installed. Xcode can't run them anyway.")
                }
            }
            ForEach(sims) { SimulatorRow(sim: $0) }
        }
    }
}

struct SimulatorRow: View {
    @Environment(Store.self) private var store
    let sim: Simulator

    var body: some View {
        let id = "sim." + sim.udid, busy = store.cleaning.contains(id), result = store.cleaned[id]
        ExpandableRow(id: id) {
            HStack(spacing: 10) {
                SymbolTile(symbol: sim.name.hasPrefix("iPad") ? "ipad" : sim.name.contains("Watch") ? "applewatch" : "iphone",
                           tint: sim.booted ? .green : .accentColor).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(sim.name).font(.body.weight(.semibold)).lineLimit(1)
                        if sim.booted { Pill(text: "Booted", color: .green, symbol: "play.fill") }
                        if !sim.available { Pill(text: "Unavailable", color: .orange) }
                        if let result, !busy { Pill(text: result.left > 0 ? "Erase failed" : "Freed \(formatBytes(result.freed))",
                                                     color: result.left > 0 ? .orange : .green) }
                    }
                    Text(sim.runtime + (sim.lastUsed.map { " · used " + $0.formatted(.relative(presentation: .named)) } ?? " · never used"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if busy { ProgressView().controlSize(.mini) } else {
                    Text(formatBytes(sim.size)).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                        .foregroundStyle(sim.size > 1_000_000_000 ? .primary : .secondary)
                }
            }
        } details: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Erase removes the apps you installed on it and their data, like a factory reset. The simulator stays in Xcode.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 2) {
                    if sim.booted {
                        Label("Shut it down first (Controls → Stop simulators)", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    } else if !busy, sim.size > 0 {
                        ConfirmButton(title: "Erase", confirm: "Erase \(formatBytes(sim.size))?", symbol: "eraser") {
                            withAnimation(.snappy) { store.erase(sim) }
                        }
                    }
                    Spacer()
                    CopyButton(symbol: "number", help: "Copy the simulator's UDID") { sim.udid }
                }
            }
        }
    }
}

/// A simulator runtime no simulator uses. Delete goes through `simctl runtime delete`, never rm.
struct RuntimeRow: View {
    @Environment(Store.self) private var store
    let runtime: SimRuntime

    var body: some View {
        let id = "runtime." + runtime.id, busy = store.cleaning.contains(id), result = store.cleaned[id]
        HStack(spacing: 10) {
            SymbolTile(symbol: "iphone.gen3", tint: .accentColor).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(runtime.name).font(.body.weight(.semibold)).lineLimit(1)
                    if let result, !busy { Pill(text: result.left > 0 ? "Delete failed" : "Freed \(formatBytes(result.freed))",
                                                 color: result.left > 0 ? .orange : .green) }
                }
                Text("No simulator uses it" + (runtime.lastUsed.map { " · used " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if busy { ProgressView().controlSize(.mini) } else {
                Text(formatBytes(runtime.size)).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                ConfirmButton(title: "Delete", confirm: "Delete \(formatBytes(runtime.size))?", symbol: "trash") {
                    withAnimation(.snappy) { store.deleteRuntime(runtime) }
                }
                .help("Xcode downloads it again if you add a simulator for this version.")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

/// Bottom of Controls: whether the lock tiles go through Strain's helper or the password sheet, and the switch.
struct HelperFooter: View {
    @Environment(Store.self) private var store

    var body: some View {
        let on = store.helper == .enabled, pending = store.helper == .requiresApproval
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            (Text(on ? "Lock = runs through Strain's helper, no password. It only runs these few commands."
                 : pending ? "Lock = asks for your password until you allow the helper: System Settings → Login Items → Allow in the Background → “Reaktif LLC”."
                 : "Lock = needs admin: macOS asks for your password each time.")
                + Text(" Every action needs a second click."))
                .fixedSize(horizontal: false, vertical: true)
            if let e = store.helperError, !on { Text(e).foregroundStyle(.orange).lineLimit(2) }
            Spacer(minLength: 4)
            Button(on ? "Turn off helper" : pending ? "Open Settings" : "Turn on helper") { store.setHelper(!on) }
                .buttonStyle(HoverButtonStyle()).foregroundStyle(on ? Color.secondary : Color.accentColor)
                .disabled(store.switching.contains("helper"))
                .help(on ? "Admin tiles go back to asking for your password; AirDrop holds stop."
                      : "Strain's helper runs the lock tiles, holds AirDrop off and reads Login Items without asking each time. macOS asks you to allow it once.")
        }
        .font(.caption).foregroundStyle(.secondary).padding(10)
    }
}

/// AirDrop's radio link (AWDL): three plain modes instead of on/off, the live state, and why it's in that state.
struct AWDLCard: View {
    @Environment(Store.self) private var store
    @State private var why = false

    var body: some View {
        @Bindable var store = store
        let up = store.airDropBlocker == nil, busy = store.switching.contains("helper")
        let needsGuard = store.awdlMode != .normal && store.helper != .enabled
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(up ? Color.accentColor : Color.primary.opacity(0.12))
                    Image(systemName: up ? "dot.radiowaves.left.and.right" : "wave.3.right.circle")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(up ? .white : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("AirDrop or low ping").font(.callout.weight(.semibold))
                        Button { why.toggle() } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).help("Why AirDrop and ping clash")
                            .popover(isPresented: $why, arrowEdge: .bottom) { AWDLExplainer() }
                    }
                    Text(store.airDropBlocker.map { "AirDrop off now: \($0)" } ?? "AirDrop available now").font(.caption).foregroundStyle(.secondary).contentTransition(.opacity)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            Picker("AWDL", selection: $store.awdlMode) {
                ForEach(AWDLMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(needsGuard ? (store.helper == .requiresApproval ? "Allow the helper: System Settings → Login Items → Allow in the Background → “Reaktif LLC”."
                                                                : "Needs Strain's helper to hold the link off. macOS asks once, in System Settings.")
                            : store.awdl.reason)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            HStack(spacing: 6) {
                if needsGuard {
                    Button { store.setHelper(true) } label: { Label("Turn on helper", systemImage: "lock.open") }
                        .disabled(store.switching.contains("helper"))
                } else if store.awdl.hold {
                    Button { store.awdlPausedUntil = .now + 600 } label: { Label("Allow AirDrop 10 min", systemImage: "airplayaudio") }
                } else if store.awdlPausedUntil != nil {
                    Button { store.awdlPausedUntil = nil } label: { Label("Hold off again", systemImage: "arrow.uturn.backward") }
                }
                Spacer()
            }
            .buttonStyle(HoverButtonStyle()).font(.caption)
            if store.awdlConflict {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("AWDL Control is also managing the link, with its own admin helper that forces it off. That's what blocks AirDrop even when you allow it. In its menu choose AWDL On, quit it, then remove it under Login Items so the two don't fight.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(HoverButtonStyle())
                }
                .font(.caption).padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.orange.opacity(0.12)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.04)))
        .animation(.snappy, value: store.awdl)
        .animation(.snappy, value: store.airDropBlocker)
    }
}

struct AWDLExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AWDL: Apple Wireless Direct Link").font(.headline)
            Text("A private Wi-Fi link between Apple devices. AirDrop, AirPlay to this Mac, Sidecar, Universal Control and Continuity Camera ride on it.")
            Text("While it's active, the Wi-Fi radio briefly hops to the AWDL channel about every second. Browsing doesn't notice; games, calls and remote desktops see ping spikes and stutter.")
            Text("macOS turns it back on whenever something nearby asks, so a one-off \"off\" doesn't stick. Strain's helper holds it off for as long as you choose, and gives it back the moment you pick AirDrop on or allow AirDrop.")
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow { Text("AirDrop on").bold(); Text("macOS decides. AirDrop works.") }
                GridRow { Text("Low ping").bold(); Text("AirDrop off until you switch back.") }
                GridRow { Text("Auto").bold(); Text("Held off only while a game, GeForce NOW, Zoom or FaceTime is in front.") }
            }
        }
        .font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        .padding(14).frame(width: 320)
    }
}

/// A radio's power switch, styled like Control Center: tinted when on, one click flips it. Bluetooth off takes a
/// second click, as in macOS: Bluetooth keyboards and mice drop, maybe the one you'd click it back on with.
struct RadioTile: View {
    @Environment(Store.self) private var store
    let id: String, title: String, on: String, off: String
    let state: Bool?
    @State private var hover = false
    @State private var armedAt: Date?

    var body: some View {
        let isOn = state == true, busy = store.switching.contains(id)
        Button {
            if id == "bluetooth", isOn {
                guard let at = armedAt else { armedAt = .now; return }
                guard Date.now.timeIntervalSince(at) > 0.4 else { return }  // second click of a double-click
            }
            armedAt = nil
            withAnimation(.snappy) { store.setRadio(id, on: !isOn) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(isOn ? Color.accentColor : Color.primary.opacity(0.12))
                    Image(systemName: isOn ? on : off).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isOn ? .white : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(busy ? "Switching…" : armedAt != nil ? "Click again to turn off" : store.radioFailed.contains(id) ? "macOS refused" : isOn ? "On" : "Off")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(hover ? 0.08 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(busy)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .task(id: armedAt) { if armedAt != nil, (try? await Task.sleep(for: .seconds(3))) != nil { armedAt = nil } }
        .animation(.snappy, value: armedAt)
        .help(isOn ? "Turn \(title) off" + (id == "bluetooth" ? ". Bluetooth keyboards, mice and AirPods disconnect." : ".") : "Turn \(title) on")
        .accessibilityLabel(title).accessibilityValue(isOn ? "On" : "Off").accessibilityAddTraits(.isToggle)
    }
}

/// Keeps the Mac awake for a while or until stopped: the switch, how long is left, and when to let it sleep anyway.
struct AwakeCard: View {
    @Environment(Store.self) private var store
    @State private var hover = false

    var body: some View {
        @Bindable var store = store
        let until = store.awakeUntil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { withAnimation(.snappy) { until == nil ? store.keepAwake(minutes: nil) : store.stopAwake() } } label: {
                    ZStack {
                        Circle().fill(until != nil ? Color.accentColor : Color.primary.opacity(hover ? 0.18 : 0.12))
                        Image(systemName: until != nil ? "cup.and.saucer.fill" : "cup.and.saucer")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(until != nil ? .white : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(PressScale())
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
                .help(until == nil ? "Keep this Mac awake until you stop it" : "Let this Mac sleep again")
                .accessibilityLabel("Keep awake").accessibilityValue(until != nil ? "On" : "Off").accessibilityAddTraits(.isToggle)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep this Mac awake").font(.callout.weight(.semibold))
                    SwiftUI.Group {
                        if let until, until != .distantFuture {
                            Text("Until \(until.formatted(date: .omitted, time: .shortened)) · ") + Text(timerInterval: Date.now...max(until, .now), countsDown: true) + Text(" left")
                        } else {
                            Text(until == nil ? "Off: the Mac sleeps as usual" : "On until you stop it")
                        }
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).contentTransition(.opacity)
                }
                Spacer(minLength: 4)
                Menu {
                    ForEach(Awake.durations, id: \.title) { d in Button(d.title) { withAnimation(.snappy) { store.keepAwake(minutes: d.minutes) } } }
                    if until != nil {
                        Divider()
                        Button("Stop") { withAnimation(.snappy) { store.stopAwake() } }
                    }
                } label: {
                    Text(until == nil ? "Start" : "Change")
                }
                .menuStyle(.borderlessButton).fixedSize().font(.caption)
                .help("Keep awake for a set time")
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Let the display sleep", isOn: $store.awakeLetDisplaySleep)
                    .help("The Mac keeps running (downloads, builds, servers) while the screen turns off as usual.")
                Toggle("Let it sleep while the screen is locked", isOn: $store.awakeLetLockedSleep)
                    .help("Locking the screen pauses keep awake; unlocking resumes it.")
                Toggle("Stop when switching to battery", isOn: $store.awakeStopOnBattery)
                    .help("Unplugging the charger ends keep awake, to save the battery.")
            }
            .toggleStyle(.checkbox).controlSize(.small).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.04)))
    }
}

/// One display's brightness, and for monitors with speakers, volume and mute. A value DDC couldn't read hides its row.
struct ScreenCard: View {
    @Environment(Store.self) private var store
    let screen: Screen

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(screen.name).font(.callout.weight(.semibold))
            if let b = screen.brightness {
                LevelRow(symbol: "sun.max.fill", value: b, label: "Brightness") { store.setLevel(screen.id, .brightness, $0) }
            }
            if let v = screen.volume {
                LevelRow(symbol: screen.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", value: screen.muted ? 0 : v, label: "Volume",
                         toggle: (screen.muted ? "Unmute" : "Mute", { store.setLevel(screen.id, .mute, screen.muted ? 0 : 1) })) {
                    store.setLevel(screen.id, .volume, $0)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.04)))
    }
}

struct LevelRow: View {
    let symbol: String, value: Double, label: String
    var toggle: (label: String, action: () -> Void)? = nil
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            SwiftUI.Group {
                if let toggle {
                    Button(action: toggle.action) { Image(systemName: symbol) }.buttonStyle(.plain).help(toggle.label).accessibilityLabel(toggle.label)
                } else {
                    Image(systemName: symbol)
                }
            }
            .foregroundStyle(.secondary).frame(width: 18).contentTransition(.symbolEffect(.replace))
            Slider(value: Binding(get: { value }, set: set)).controlSize(.small).accessibilityLabel(label)
            Text("\(Int((value * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }
}

/// The switch that hands the brightness and volume keys to Strain, and what's stopping it.
struct DisplayKeysRow: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Brightness and volume keys control these", isOn: $store.displayKeys).toggleStyle(.switch).controlSize(.mini).font(.caption)
            SwiftUI.Group {
                if store.keysBlocked {
                    HStack(spacing: 4) {
                        Text(AXIsProcessTrusted() ? "Accessibility is allowed, but macOS refused the key listener."
                                                  : "Allow Strain under Privacy & Security → Accessibility.")
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .buttonStyle(HoverButtonStyle()).foregroundStyle(Color.accentColor)
                    }
                } else if store.displayKeys, Displays.monitorControlRunning() {
                    Text("MonitorControl is running too: quit it, or both answer the keys.").foregroundStyle(.orange)
                } else {
                    Text("Keys follow the pointer: the built-in screen and speakers with their own volume stay with macOS. Hold ⇧⌥ for fine steps.")
                }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A quick action: click arms it, a second click within 3 s runs it, then it shows ✓ or ✗.
struct ActionTile: View {
    let action: QuickAction
    enum Phase { case idle, armed, running, ok, failed }
    @State private var phase = Phase.idle
    @State private var armedAt = Date.distantPast
    @State private var hover = false
    @State private var generation = 0

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                ZStack {
                    if phase == .running { ProgressView().controlSize(.small) } else {
                        Image(systemName: icon).font(.system(size: 15, weight: .medium))
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: phase == .ok)
                    }
                }
                .frame(height: 18)
                Text(phase == .armed ? (action.admin ? "Run as admin?" : "Run?") : action.title)
                    .font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.85)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(phase == .armed ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.primary.opacity(hover ? 0.08 : 0.04))))
            .overlay(alignment: .topTrailing) {
                if action.admin { Image(systemName: "lock.fill").font(.system(size: 7)).foregroundStyle(.tertiary).padding(5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(phase == .running)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(action.detail + (action.admin ? " Asks for your password." : "") + " Click twice to run.")
        .accessibilityLabel(phase == .armed ? "Confirm \(action.title)" : action.title)
        .animation(.snappy, value: phase)
    }

    private var icon: String {
        switch phase {
        case .ok: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .armed: "exclamationmark.circle.fill"
        default: action.symbol
        }
    }

    private var tint: Color {
        switch phase {
        case .ok: .green
        case .failed: .red
        case .armed: .accentColor
        default: .primary
        }
    }

    private func tap() {
        switch phase {
        case .idle, .ok, .failed:
            (phase, armedAt) = (.armed, .now)
            settle(after: 3, from: .armed)
        case .armed:
            guard Date.now.timeIntervalSince(armedAt) > 0.4 else { return }  // second click of a double-click
            phase = .running
            Task {
                phase = await action.run() ? .ok : .failed
                settle(after: 2.5, from: phase)
            }
        case .running:
            break
        }
    }

    /// Back to idle after a delay, unless a newer click moved on.
    private func settle(after seconds: Double, from p: Phase) {
        generation += 1
        let mine = generation
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if mine == generation, phase == p { phase = .idle }
        }
    }
}

struct CleanRow: View {
    @Environment(Store.self) private var store
    let item: CleanItem

    var body: some View {
        let size = store.cleanSizes?[item.id], busy = store.cleaning.contains(item.id), result = store.cleaned[item.id]
        let folder = item.folder.map { NSHomeDirectory() + "/" + $0 }
        ExpandableRow(id: "clean." + item.id) {
            HStack(spacing: 10) {
                SymbolTile(symbol: item.symbol, tint: .accentColor).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(item.title).font(.body.weight(.semibold)).lineLimit(1)
                        if let result, !busy {
                            Pill(text: "Freed \(formatBytes(result.freed))", color: .green, symbol: "checkmark")
                            if result.left > 0 { Pill(text: "\(result.left) in use", color: .orange).help("Entries an app was using or macOS protects. Quit the app and clean again.") }
                        }
                    }
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if busy {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Cleaning…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let size {
                    Text(size > 0 ? formatBytes(size) : "Empty")
                        .font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                        .foregroundStyle(size > 1_000_000_000 ? .primary : .secondary)
                        .contentTransition(.numericText(value: Double(size)))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
        } details: {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let folder { Facts(rows: [("Folder", folder)]) }
                HStack(spacing: 2) {
                    if busy {
                        Label("Deleting… big caches take a minute", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                    } else if let id = item.bundleID, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 0 {
                        Label("Quit \(item.title) to clean", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    } else if (size ?? 0) > 0 {
                        ConfirmButton(title: "Clean", confirm: "Delete \(formatBytes(size ?? 0))?", symbol: "sparkles") {
                            withAnimation(.snappy) { store.clean(item) }
                        }
                    }
                    Spacer()
                    IconButton(symbol: "folder", help: "Reveal in Finder") { reveal(folder ?? NSHomeDirectory() + "/Library/Caches") }
                }
            }
        }
    }
}

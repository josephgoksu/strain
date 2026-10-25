import ServiceManagement
import SwiftUI

/// The whole app in one menu bar panel: status, meters, four tabs, footer. Fixed height, so switching tabs
/// or expanding a row never resizes the window (the menu bar window doesn't resize cleanly).
struct Panel: View {
    @Environment(Store.self) private var store
    @Environment(\.colorScheme) private var scheme
    @AppStorage("rows") private var rows = 5

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Meters()
                .padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            TabBar().padding(.horizontal, 10).padding(.top, 8)
            TabToolbar().padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 2)
            FixedScroll(height: CGFloat(rows) * 64 + 20) {
                SwiftUI.Group {
                    if let meter = store.meter { MeterDetail(kind: meter) } else {
                    switch store.tab {
                    case .apps: AppsTab()
                    case .servers: ServersTab()
                    case .background: BackgroundTab()
                    case .controls: ControlsTab()
                    case .clean: CleanTab()
                    case .unknown: UnknownTab()
                    }
                    }
                }
                .id(store.meter?.rawValue ?? store.tab.rawValue)
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
            Divider()
            Footer()
        }
        .frame(width: 420)
        // The menu bar window's material washes out in light mode; an opaque white base keeps text and cards legible.
        .background(scheme == .light ? Color(nsColor: .textBackgroundColor) : .clear)
        .animation(.snappy(duration: 0.22), value: store.tab)
        .animation(.snappy(duration: 0.22), value: store.meter)
    }
}

/// A scroll area of constant height.
struct FixedScroll<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView { content.padding(.horizontal, 6).padding(.bottom, 6) }
            .frame(height: height)
    }
}

// MARK: - Header

struct Header: View {
    @Environment(Store.self) private var store
    @State private var why = false

    var body: some View {
        let m = store.monitor
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(m.level.color.opacity(0.16))
                Image(systemName: m.level.symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(m.level.color)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: m.level)
                    .symbolEffect(.pulse, isActive: m.level == .red)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.level.title).font(.title3.weight(.semibold)).contentTransition(.opacity)
                HStack(spacing: 4) {
                    Text(m.assessment.reason).lineLimit(1).truncationMode(.tail).help(m.assessment.reason)
                    Button { why.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("When does Strain warn?")
                        .popover(isPresented: $why, arrowEdge: .bottom) { WhyPopover() }
                }
                .font(.callout).foregroundStyle(.secondary)
                // Always present, so the header (and the panel) keeps one height across levels.
                Text(m.level > .green ? "Since \(m.since.formatted(date: .omitted, time: .shortened))\(m.easing ? " · easing off" : "")" : "Checking every \(Int(Thresholds.interval)) s")
                    .font(.caption).foregroundStyle(.secondary).contentTransition(.opacity)
            }
            Spacer(minLength: 6)
            MoreMenu()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }
}

struct WhyPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("When Strain warns").font(.headline)
            rule(.orange, "Under strain", "High memory pressure, swapping > \(Int(Thresholds.swapRateAmber)) MB/min, swap over half your RAM, load > \(Int(Thresholds.loadAmber))× cores, or one app over \(Int(Thresholds.hogCPU))% CPU for \(Int(Thresholds.hogSeconds / 60)) min.")
            rule(.red, "Struggling", "Critical memory pressure, swapping > \(Int(Thresholds.swapRateRed)) MB/min, or load > \(Int(Thresholds.loadRed))× cores.")
            Text("A level must hold for \(Int(Thresholds.interval) * Thresholds.hold) s before it changes. A big but idle swap file is not strain.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 300)
    }

    private func rule(_ c: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(c).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Everything that used to live in a Settings window.
struct MoreMenu: View {
    @Environment(Store.self) private var store
    @AppStorage("notify") private var notify = "all"
    @AppStorage("menuBarText") private var menuBarText = true
    @AppStorage("rows") private var rows = 5

    var body: some View {
        @Bindable var store = store
        Menu {
            Menu(store.awakeUntil == nil ? "Keep This Mac Awake" : "Keeping This Mac Awake") {
                ForEach(Awake.durations, id: \.title) { d in Button(d.title) { store.keepAwake(minutes: d.minutes) } }
                if store.awakeUntil != nil {
                    Divider()
                    Button("Stop") { store.stopAwake() }
                }
            }
            Menu("Kept (\(store.kept.count))") {
                Text("Never listed as forgotten. Click to list again.")
                ForEach(store.kept, id: \.self) { name in Button(name) { store.unkeep(name) } }
            }
            Divider()
            Toggle("Launch at Login", isOn: $store.launchAtLogin)
            Toggle("Show Culprit in Menu Bar", isOn: $menuBarText)
            Picker("Notifications", selection: $notify) {
                Text("Under Strain or Worse").tag("all")
                Text("Only When Struggling").tag("red")
                Text("Off").tag("off")
            }
            Picker("Rows", selection: $rows) {
                ForEach(Set([4, 5, 6, 8, rows]).sorted(), id: \.self) { Text("\($0) Rows").tag($0) }
            }
            Divider()
            Button("Copy Diagnostics") { copy(store.diagnostics()) }
            Button("Open Activity Monitor", action: openActivityMonitor)
            Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
            Divider()
            Text("Strain \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
            Button("Quit Strain") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 16))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Options")
    }
}

// MARK: - Meters

/// The three cards under the header. Click one to open its details in the list area (the panel keeps its height).
struct Meters: View {
    @Environment(Store.self) private var store

    var body: some View {
        let s = store.system, swapRate = store.monitor.swapRate
        let load = s.load / Double(max(s.cores, 1))
        // Real utilization once two core readings exist; the load average until then.
        let busy = store.cores.isEmpty ? min(load, 1) : store.cores.reduce(0, +) / Double(store.cores.count)
        HStack(spacing: 8) {
            Meter(kind: .memory, symbol: "memorychip", value: s.memUsedMB / 1024, format: "%.1f GB",
                  detail: "of \(gb(s.memTotalMB)) GB · \(s.pressureName)", fraction: s.memTotalMB > 0 ? s.memUsedMB / s.memTotalMB : 0,
                  tint: s.pressure >= 4 ? .red : s.pressure >= 2 ? .orange : .blue,
                  help: "Memory used (apps + wired + compressed). Click for the breakdown.")
            Meter(kind: .swap, symbol: "arrow.left.arrow.right", value: s.swapUsedMB / 1024, format: "%.1f GB",
                  detail: swapRate >= 1 ? String(format: "Writing %.0f MB/min", swapRate) : "Idle",
                  fraction: s.memTotalMB > 0 ? s.swapUsedMB / s.memTotalMB : 0,
                  tint: swapRate > Thresholds.swapRateRed ? .red : swapRate > Thresholds.swapRateAmber ? .orange : .blue,
                  help: "Swap on disk. Click to see whether it's active.")
            Meter(kind: .cpu, symbol: "cpu", value: busy * 100, format: "%.0f%%",
                  detail: String(format: "Load %.1f · %d cores", s.load, s.cores), fraction: busy,
                  tint: load > Thresholds.loadRed ? .red : load > Thresholds.loadAmber ? .orange : .blue,
                  help: "How busy the cores are right now. Click for every core.")
        }
    }
}

struct Meter: View {
    @Environment(Store.self) private var store
    let kind: MeterKind, symbol: String
    let value: Double, format: String
    let detail: String
    let fraction: Double
    let tint: Color
    let help: String
    @State private var hover = false

    var body: some View {
        let open = store.meter == kind
        Button {
            withAnimation(.snappy(duration: 0.25)) { store.meter = open ? nil : kind }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 0) {
                    Label(kind.rawValue.uppercased(), systemImage: symbol)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
                        .opacity(hover || open ? 1 : 0)
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(open ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                Text(String(format: format, value))
                    .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText(value: value))
                    .animation(.snappy, value: value)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Bar(fraction: fraction, tint: tint)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.quaternary.opacity(hover || open ? 0.9 : 0.55)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(open ? 0.7 : 0), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PressScale())
        .scaleEffect(hover && !open ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: hover)
        .onHover { hover = $0 }
        .help(open ? "Close details" : help)
        .accessibilityLabel("\(kind.rawValue): \(String(format: format, value)), \(detail)")
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// Plain button that dips a little while pressed.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Tab bar

struct TabBar: View {
    @Environment(Store.self) private var store
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { tab in
                let selected = store.tab == tab && store.meter == nil  // an open meter takes the list area
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        store.expanded = nil
                        store.meter = nil
                        store.tab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol).symbolVariant(selected ? .fill : .none)
                        if selected {
                            Text(tab.title).lineLimit(1).fixedSize()
                                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                        }
                        if let n = badge(tab), n > 0 {
                            Text("\(n)").font(.caption2.weight(.bold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(tab == .unknown && !store.logged.isEmpty ? Color.orange.opacity(0.25) : Color.primary.opacity(0.1)))
                                .contentTransition(.numericText(value: Double(n)))
                        }
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: selected ? .infinity : nil)
                    .frame(minWidth: 52)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.09))
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func badge(_ tab: Tab) -> Int? {
        switch tab {
        case .apps: nil
        case .servers: store.servers.filter { $0.kind != .macOS }.count
        case .background: store.background?.filter { $0.status == .on }.count
        case .controls, .clean: nil
        case .unknown: store.unknowns.count
        }
    }
}

// MARK: - Footer

struct Footer: View {
    @Environment(Store.self) private var store
    @State private var refreshing = false

    var body: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 5)) { t in
                let ago = max(0, Int(t.date.timeIntervalSince(store.updated)))
                Text("Updated \(ago < 5 ? "just now" : "\(formatDuration(ago)) ago") · \(store.processCount) processes")
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            AskAIButton(help: "Ask AI what's slowing the Mac, with a full snapshot of memory, CPU, apps and servers.") {
                Prompts.slowMac(store.diagnostics())
            }
            IconButton(symbol: "arrow.clockwise", help: "Refresh now", spinning: refreshing) {
                refreshing = true
                Task {
                    await store.tick()
                    if store.tab == .clean { await store.scanClean() }
                    refreshing = false
                }
            }
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 6)
    }
}

import Charts
import SwiftUI

/// What a meter card opens into: the numbers behind it, 10 minutes of history, and who's responsible.
struct MeterDetail: View {
    @Environment(Store.self) private var store
    let kind: MeterKind

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch kind {
            case .cpu: CPUDetail()
            case .memory: MemoryDetail()
            case .swap: SwapDetail()
            }
        }
        .padding(.horizontal, 10).padding(.top, 6)
    }

}

// MARK: - CPU

struct CPUDetail: View {
    @Environment(Store.self) private var store

    var body: some View {
        let cores = store.cores, topo = CPUTopology.current
        let busy = cores.filter { $0 > 0.8 }.count
        let avg = cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(topo.efficiency > 0 ? "\(cores.count) cores: \(topo.performance) Performance + \(topo.efficiency) Efficiency" : "\(cores.count) cores")
                    .font(.callout)
                Spacer()
                Pill(text: busy == 0 ? "None maxed" : "\(busy) maxed", color: busy == 0 ? .green : busy > cores.count / 2 ? .red : .orange,
                     symbol: busy == 0 ? "checkmark" : "flame.fill")
                    .contentTransition(.numericText())
            }
            CoreGrid(cores: cores, topo: topo)
            Facts(rows: [("Busy now", String(format: "%.0f%% of all cores", avg * 100)),
                         ("Load", loadAverages()),
                         ("Heat", thermal)])
            HistoryChart(points: store.history, value: \.cpu, unit: "%", tint: .blue, max: 100)
            Note("Efficiency cores take background work; Performance cores take what you're waiting on. Load counts threads that want a core: above \(cores.count) means work is queuing.")
            TopUsers(title: "Using the most CPU", groups: Array(store.groups.prefix(3)), sort: .cpu) { "\(Int($0.cpu.rounded()))%" }
        }
    }

    private func loadAverages() -> String {
        var l = [0.0, 0, 0]
        getloadavg(&l, 3)
        return String(format: "%.1f · %.1f · %.1f  (1 · 5 · 15 min)", l[0], l[1], l[2])
    }

    private var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot: macOS is slowing the CPU"
        case .critical: "Critical: heavily throttled"
        @unknown default: "Unknown"
        }
    }
}

/// One bar per core, Efficiency cores first, as the kernel numbers them.
struct CoreGrid: View {
    let cores: [Double]
    let topo: CPUTopology

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if topo.efficiency > 0 { cluster("Efficiency", Array(cores.indices.prefix(topo.efficiency))) }
            cluster(topo.efficiency > 0 ? "Performance" : "Cores", Array(cores.indices.dropFirst(topo.efficiency)))
        }
        .frame(height: 74)
        .overlay { if cores.isEmpty { Text("Measuring…").font(.caption).foregroundStyle(.secondary) } }
    }

    private func cluster(_ name: String, _ ids: [Int]) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(ids, id: \.self) { i in
                    let u = cores[i]
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.quaternary)
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color(u).gradient).frame(height: max(3, 56 * u))
                    }
                    .frame(height: 56)
                    .animation(.snappy, value: u)
                    .help("Core \(i + 1) (\(name)): \(Int((u * 100).rounded()))%")
                }
            }
            Text(name.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func color(_ u: Double) -> Color { u > 0.8 ? .red : u > 0.5 ? .orange : .green }
}

// MARK: - Memory

struct MemoryDetail: View {
    @Environment(Store.self) private var store

    var body: some View {
        let s = store.system, m = s.memory
        let parts: [(String, Double, Color, String)] = [
            ("Apps", m.appMB, .blue, "What apps are using now."),
            ("Wired", m.wiredMB, .purple, "Locked by macOS itself; can't be freed."),
            ("Compressed", m.compressedMB, .orange, String(format: "Squeezed to save room; holds %@ GB.", gb(m.compressedOriginalMB))),
            ("Cached files", m.cachedMB, .teal, "Recently read files; freed instantly when needed."),
            ("Free", m.freeMB, .gray, "Unused."),
        ]
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2.gradient).frame(width: max(0, geo.size.width * p.1 / max(m.totalMB, 1) - 1.5))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            .animation(.snappy, value: m)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                ForEach(parts, id: \.0) { p in
                    GridRow {
                        Circle().fill(p.2).frame(width: 8, height: 8)
                        Text(p.0).font(.callout.weight(.medium))
                        Text("\(gb(p.1)) GB").font(.callout.monospacedDigit()).gridColumnAlignment(.trailing)
                            .contentTransition(.numericText(value: p.1))
                        Text(p.3).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Facts(rows: [("Pressure", "\(s.pressureName): " + (s.pressure >= 2 ? "macOS is compressing and swapping to keep up" : "plenty of room"))])
            HistoryChart(points: store.history, value: \.memGB, unit: " GB", tint: .blue, max: s.memTotalMB / 1024)
            Note("Used = Apps + Wired + Compressed. High \"used\" is fine; macOS fills memory on purpose. Pressure is what matters.")
            TopUsers(title: "Using the most memory", groups: Array(store.groups.sorted { $0.rssKB > $1.rssKB }.prefix(3)), sort: .memory) { formatMemory(kb: $0.rssKB) }
        }
    }
}

// MARK: - Swap

struct SwapDetail: View {
    @Environment(Store.self) private var store

    var body: some View {
        let s = store.system, m = s.memory, out = store.monitor.swapRate, inRate = store.swapInRate
        let active = out >= 1 || inRate >= 1
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("\(gb(s.swapUsedMB)) GB on disk").font(.callout)
                Spacer()
                Pill(text: active ? "Active" : "Idle, harmless", color: out > Thresholds.swapRateAmber ? .orange : active ? .blue : .green,
                     symbol: active ? "arrow.left.arrow.right" : "checkmark")
            }
            Facts(rows: [("Writing", String(format: "%.0f MB/min", out)),
                         ("Reading back", String(format: "%.0f MB/min", inRate)),
                         ("Swap files", "\(gb(s.swapTotalMB)) GB allocated"),
                         ("Compressor", m.compressedMB > 0 ? String(format: "%@ GB squeezed into %@ GB (%.1f×)", gb(m.compressedOriginalMB), gb(m.compressedMB), m.compressedOriginalMB / m.compressedMB) : "Empty")])
            HistoryChart(points: store.history, value: \.swapRate, unit: " MB/min", tint: .orange, max: nil,
                         rule: (Thresholds.swapRateAmber, "Strain warns"))
            Note("macOS first compresses memory, then moves it to swap on disk. Swap only slows you while it's being written or read back. A big idle swap is harmless and empties after a restart.")
            TopUsers(title: active ? "Quit one of these to stop swapping" : "Biggest memory users", groups: Array(store.groups.sorted { $0.rssKB > $1.rssKB }.prefix(3)), sort: .memory) { formatMemory(kb: $0.rssKB) }
        }
    }
}

// MARK: - Shared pieces

/// 10 minutes of one metric, as a soft area under a line.
struct HistoryChart: View {
    let points: [HistoryPoint]
    let value: KeyPath<HistoryPoint, Double>
    let unit: String
    let tint: Color
    let max: Double?
    var rule: (Double, String)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LAST 10 MIN").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let last = points.last {
                    Text(String(format: "%.1f", last[keyPath: value]) + unit).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if points.count < 2 {
                Text("Collecting… a point every \(Int(Thresholds.interval)) s").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            } else {
                Chart {
                    ForEach(points) { p in
                        AreaMark(x: .value("Time", p.t), y: .value("Value", p[keyPath: value]))
                            .foregroundStyle(tint.opacity(0.18).gradient).interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.t), y: .value("Value", p[keyPath: value]))
                            .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
                    }
                    if let rule, (points.map { $0[keyPath: value] }.max() ?? 0) > rule.0 / 2 {
                        RuleMark(y: .value(rule.1, rule.0)).foregroundStyle(.orange.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartYScale(domain: 0...(max ?? Swift.max(10, (points.map { $0[keyPath: value] }.max() ?? 0) * 1.2)))
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisValueLabel() } }
                .frame(height: 64)
                .animation(.snappy, value: points.count)
            }
        }
    }
}

/// The top few groups for a meter; a click opens that app's row in the Apps tab.
struct TopUsers: View {
    @Environment(Store.self) private var store
    let title: String
    let groups: [Group]
    let sort: Sort  // the Apps order these came from, so the opened row is where it was ranked
    let metric: (Group) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
            ForEach(groups) { g in
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        if store.activeSort != sort { store.sort = sort }
                        (store.meter, store.tab, store.expanded) = (nil, .apps, g.name)
                    }
                } label: {
                    HStack(spacing: 8) {
                        AppGroupIcon(group: g).frame(width: 18, height: 18)
                        Text(store.title(g)).lineLimit(1)
                        Spacer()
                        Text(metric(g)).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(HoverButtonStyle())
                .help("Show in Apps")
            }
        }
    }
}

struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: "lightbulb").foregroundStyle(.yellow) }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

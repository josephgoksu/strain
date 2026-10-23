import SwiftUI

// MARK: - Buttons

/// Copies text and confirms with a checkmark that swaps back after a moment.
struct CopyButton: View {
    var label: String? = nil
    var symbol = "doc.on.doc"
    var copiedLabel = "Copied"
    var help = "Copy"
    let text: () -> String
    @State private var copied = false
    @State private var generation = 0

    var body: some View {
        Button {
            copy(text())
            generation += 1
            let mine = generation
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                if mine == generation { withAnimation(.snappy) { copied = false } }  // a newer copy owns the reset
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : symbol)
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                if let label { Text(copied ? copiedLabel : label).contentTransition(.opacity) }
            }
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
        .accessibilityLabel(label ?? help)
    }
}

/// "Ask AI": copies a ready-made prompt to paste into any AI chat. Labeled, never a bare icon.
struct AskAIButton: View {
    var label = "Ask AI"
    let help: String
    let prompt: () -> String
    var body: some View {
        CopyButton(label: label, symbol: "sparkles", copiedLabel: "Copied, paste in your AI",
                   help: help + " Copies a prompt; paste it into an AI chat (Claude, ChatGPT…).", text: prompt)
    }
}

/// Two-step destructive button: the first click arms it ("Quit 12?"), a second click 0.4-3 s later acts.
/// Replaces modal alerts, which close the menu bar panel. A double-click only arms it.
struct ConfirmButton: View {
    let title: String
    let confirm: String
    var symbol = "xmark.circle.fill"
    let action: () -> Void
    @State private var armedAt: Date?
    @State private var done = false
    @State private var generation = 0

    var body: some View {
        let armed = armedAt != nil
        Button {
            if let armedAt {
                guard Date.now.timeIntervalSince(armedAt) > 0.4 else { return }  // second click of a double-click
                action()
                withAnimation(.snappy) { (self.armedAt, done) = (nil, true) }
                reset(after: 1.5) { done = false }
            } else {
                withAnimation(.snappy) { armedAt = .now }
                reset(after: 3) { armedAt = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: done ? "checkmark" : armed ? "exclamationmark.triangle.fill" : symbol)
                    .contentTransition(.symbolEffect(.replace))
                Text(done ? "Done" : armed ? confirm : title).contentTransition(.opacity)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(armed ? .white : .red)
            .background(Capsule().fill(armed ? AnyShapeStyle(.red) : AnyShapeStyle(.red.opacity(0.14))))
        }
        .buttonStyle(.plain)
        .help(armed ? "Click again to confirm" : title)
        .accessibilityLabel(armed ? confirm : title)
    }

    /// Runs `body` after a delay unless a newer click has taken over.
    private func reset(after seconds: Double, _ body: @escaping () -> Void) {
        generation += 1
        let mine = generation
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if mine == generation { withAnimation(.snappy) { body() } }
        }
    }
}

/// Borderless icon or label button with a soft hover fill and press scale.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.callout)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(hover && enabled ? 0.08 : 0)))
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hover)
                .onHover { hover = $0 }
                .contentShape(Rectangle())
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spinning)
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Bits

struct Pill: View {
    let text: String
    let color: Color
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            Text(text)
        }
        .font(.caption2.weight(.semibold)).foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(Capsule().fill(color.opacity(0.15)))
        .fixedSize()
    }
}

struct Bar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.gradient).frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.snappy, value: fraction)
    }
}

/// A rounded square with an SF Symbol: the icon for anything that isn't an app bundle.
struct SymbolTile: View {
    let symbol: String
    var tint: Color = .secondary
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.15))
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
        }
    }
}

struct BundleIcon: View {
    let path: String
    var body: some View { Image(nsImage: IconCache.icon(path)).resizable() }
}

/// App icons, fetched once per path and shrunk to 64 px. NSWorkspace returns a fresh multi-resolution image
/// on every call; asking per render cost hundreds of MB and constant CPU while the panel was open.
@MainActor enum IconCache {
    private static var icons: [String: NSImage] = [:]
    private static var appPaths: [String: String?] = [:]

    static func icon(_ path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let source = NSWorkspace.shared.icon(forFile: path)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(rep)
        icons[path] = image
        return image
    }

    /// Memoized lookup (LaunchServices and file checks are too slow to repeat per render).
    static func appPath(_ key: String, _ resolve: () -> String?) -> String? {
        if let cached = appPaths[key] { return cached }
        let found = resolve()
        appPaths[key] = found
        return found
    }
}

/// Tap-to-expand row shell shared by every tab: hover fill, rotating chevron, animated details.
struct ExpandableRow<Header: View, Details: View>: View {
    @Environment(Store.self) private var store
    let id: String
    @ViewBuilder let header: Header
    @ViewBuilder let details: Details
    @State private var hover = false

    var body: some View {
        let open = store.expanded == id
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                header
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .contentShape(Rectangle())
            // Only the header toggles: clicks inside the details (selecting text, buttons) must not collapse it.
            .onTapGesture { withAnimation(.snappy(duration: 0.25)) { store.expanded = open ? nil : id } }
            if open {
                details.padding(.leading, 40)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(open ? 0.07 : hover ? 0.04 : 0)))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(open ? "Collapse" : "Expand for details and actions")
    }
}

/// Label-value grid used in expanded rows.
struct Facts: View {
    let rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(rows, id: \.0) { r in
                GridRow {
                    Text(r.0).foregroundStyle(.secondary)
                    Text(r.1).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(r.1)
                }
            }
        }
        .font(.caption.monospacedDigit())
    }
}

// MARK: - Helpers

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

func openActivityMonitor() {
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                       configuration: .init())
}

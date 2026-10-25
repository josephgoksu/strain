import ServiceManagement
import HelperKit
import SwiftUI
import UserNotifications

enum Sort: String, CaseIterable { case memory = "Memory", cpu = "CPU" }

enum MeterKind: String {
    case memory, swap, cpu
    var detailTitle: String {
        switch self {
        case .memory: "Memory breakdown"
        case .swap: "Swap activity"
        case .cpu: "Every core"
        }
    }
}

/// One point of the meters' 10-minute history.
struct HistoryPoint: Identifiable {
    let t: Date, cpu: Double, memGB: Double, swapRate: Double  // cpu: 0...100, swapRate: MB/min written
    var id: Date { t }
}

enum Tab: String, CaseIterable, Identifiable {
    case apps, servers, background, controls, clean, unknown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apps: "Apps"
        case .servers: "Servers"
        case .background: "Background"
        case .controls: "Controls"
        case .clean: "Clean"
        case .unknown: "Unknown"
        }
    }
    var symbol: String {
        switch self {
        case .apps: "square.stack.3d.up"
        case .servers: "network"
        case .background: "clock.arrow.circlepath"
        case .controls: "switch.2"
        case .clean: "bubbles.and.sparkles"
        case .unknown: "questionmark.circle"
        }
    }
}

@MainActor @Observable final class Store {
    private(set) var monitor = Monitor()
    private(set) var system = SystemSample.read()
    private(set) var groups: [Group] = []
    private(set) var processCount = 0
    private(set) var servers: [Server] = []
    private(set) var updated = Date.now
    private(set) var background: [BackgroundItem]?   // nil until the Background tab is first opened (~3 s read)
    private(set) var loadingBackground = false
    private(set) var backgroundRead: Date?           // when the shown list was read (it may come from the cache)
    private(set) var backgroundFailed = false        // last read was cancelled or timed out
    private(set) var cores: [Double] = []            // busy fraction per core over the last interval
    private(set) var history: [HistoryPoint] = []    // last 10 minutes, one point per tick
    private(set) var swapInRate = 0.0                // MB/min read back from swap
    private var lastTicks: [CoreTicks] = []
    private var lastSample: (SystemSample, Date)?
    var meter: MeterKind?                            // the meter whose details fill the list area
    private(set) var cleanSizes: [String: Int64]?  // CleanItem.id → bytes; nil until the Clean tab is first opened
    private(set) var cleaning: Set<String> = []    // CleanItem.ids being deleted right now
    private(set) var cleaned: [String: CleanResult] = [:]
    private(set) var projects: [DevProject]?         // build folders in ~/Development and friends; nil until measured
    private(set) var simulators: [Simulator] = []
    private(set) var runtimes: [SimRuntime] = []          // simulator runtimes no simulator uses
    private(set) var archives: Int64 = 0                  // Xcode Archives: your shipped builds, data, so Reveal only
    let devRoots = DevCleanup.roots()
    private(set) var wifi: Bool?                      // nil = unknown (no Wi-Fi hardware, or not read yet)
    private(set) var bluetooth: Bool?
    private(set) var switching: Set<String> = []      // "wifi" / "bluetooth" / "helper" while a switch is flipping
    private(set) var radioFailed: Set<String> = []    // the last switch macOS refused
    private(set) var screens: [Screen] = []           // displays with brightness or volume Strain can set
    /// Brightness and volume keys drive external monitors. Needs Accessibility.
    var displayKeys = UserDefaults.standard.bool(forKey: "displayKeys") {
        didSet {
            UserDefaults.standard.set(displayKeys, forKey: "displayKeys")
            if displayKeys { DisplayKeys.start(prompt: true) } else { DisplayKeys.stop() }
            keysBlocked = displayKeys && !DisplayKeys.running
        }
    }
    private(set) var keysBlocked = false              // keys on, but Accessibility not granted yet
    /// Keep awake: nil = off, .distantFuture = indefinitely. Saved, so a relaunch (an update, say) carries on.
    private(set) var awakeUntil: Date? = UserDefaults.standard.object(forKey: "awakeUntil") as? Date {
        didSet { UserDefaults.standard.set(awakeUntil, forKey: "awakeUntil"); applyAwake() }
    }
    var awakeLetDisplaySleep = UserDefaults.standard.bool(forKey: "awakeLetDisplaySleep") {
        didSet { UserDefaults.standard.set(awakeLetDisplaySleep, forKey: "awakeLetDisplaySleep"); applyAwake() }
    }
    var awakeLetLockedSleep = UserDefaults.standard.bool(forKey: "awakeLetLockedSleep") {
        didSet { UserDefaults.standard.set(awakeLetLockedSleep, forKey: "awakeLetLockedSleep"); applyAwake() }
    }
    var awakeStopOnBattery = UserDefaults.standard.bool(forKey: "awakeStopOnBattery") {
        didSet { UserDefaults.standard.set(awakeStopOnBattery, forKey: "awakeStopOnBattery") }
    }
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var onBattery = Awake.onBattery
    @ObservationIgnored private var awakeTimer: Task<Void, Never>?
    /// When Clean was last measured in full, by Check now or the weekly check.
    private(set) var lastCheck = UserDefaults.standard.object(forKey: "lastCheck") as? Date {
        didSet { UserDefaults.standard.set(lastCheck, forKey: "lastCheck") }
    }
    /// ponytail: `--fake-week` runs the weekly check at the first tick and always notifies, to test it without waiting.
    @ObservationIgnored private var fakeWeek = CommandLine.arguments.contains("--fake-week")
    @ObservationIgnored private var refreshingScreens = false
    @ObservationIgnored private var screensStale = false    // a screen change arrived during a read
    @ObservationIgnored private var touched: Set<String> = []  // "display.vcp" set while a screen read is in flight
    var awdlMode = AWDLMode(rawValue: UserDefaults.standard.string(forKey: "awdl") ?? "") ?? .normal {
        didSet {
            UserDefaults.standard.set(awdlMode.rawValue, forKey: "awdl")
            if awdlPausedUntil == nil { applyAWDL() } else { awdlPausedUntil = nil }  // a pause belongs to the mode it was made in
        }
    }
    var awdlPausedUntil: Date? { didSet { applyAWDL() } }
    private(set) var awdl = AWDLDecision(hold: false, reason: "")
    private(set) var awdlUp: Bool?

    /// Why AirDrop can't work right now, or nil. AirDrop finds devices over Bluetooth and sends over Wi-Fi (the AWDL
    /// link), so it needs all three; the link being up alone doesn't make AirDrop available.
    var airDropBlocker: String? {
        if wifi == false { return "Wi-Fi is off" }
        if bluetooth == false { return "Bluetooth is off" }
        if awdlUp == false { return awdl.hold ? "held off for low ping" : "the link is down" }
        return nil
    }
    private(set) var helper = HelperClient.status  // Strain's root helper: .enabled once approved in System Settings
    private(set) var helperError: String?           // why the last "Turn on helper" failed
    private(set) var awdlConflict = false            // AWDL Control is running and forcing the link on its own
    private(set) var scanning = false
    private(set) var disk = Disk.read()
    private(set) var logged = Explanations.readUnknowns()  // unknown.txt, re-read only when Strain writes it
    private(set) var unknowns: [(name: String, path: String)] = []
    let explanations = Explanations.bundled()
    var sort: Sort?            // nil = follow the assessment (memory strain → memory, else CPU)
    var expanded: String?      // id of the open row
    var tab = Tab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .apps {
        didSet { if !CommandLine.arguments.contains("--snapshot") { UserDefaults.standard.set(tab.rawValue, forKey: "tab") } }
    }
    private let isApp = Bundle.main.bundleIdentifier != nil  // false under `swift run`
    /// ponytail: `--fake-red` forces critical memory pressure, to check the red state and notification without real strain.
    private let fakeRed = CommandLine.arguments.contains("--fake-red")

    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do { try launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch { launchAtLogin = !launchAtLogin }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    init() {
        if let cached = LoginItemsCache.load() {
            background = sortedBackground(dedupe(parseBTM(cached.text)))
            backgroundRead = cached.date
        }
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        if isApp { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) } }
        DisplayKeys.handler = { [weak self] key, flags in self?.handleKey(key, flags) ?? false }
        if displayKeys { DisplayKeys.start(prompt: false); Task { await refreshScreens() } }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.displayKeys { Task { await self.refreshScreens() } } }  // Controls re-reads on open
        }
        for (name, isLocked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.locked = isLocked; self?.applyAwake() }
            }
        }
        applyAwake()  // resumes a saved session, or clears an expired one
        Task { [weak self] in
            while let self {
                await self.tick()
                try? await Task.sleep(for: .seconds(Thresholds.interval))
            }
        }
    }

    /// Decides whether AWDL should be held off and tells the helper. Cheap: runs every tick. The hold lives on
    /// Strain's connection to the helper, so quitting or crashing releases it.
    func applyAWDL() {
        let was = awdl.hold
        HelperClient.refresh()
        helper = HelperClient.status
        awdl = AWDL.decide(awdlMode, front: awdlMode == .auto ? frontApp() : nil, pausedUntil: awdlPausedUntil)
        // A snapshot or dev run must never touch the real AirDrop hold (the helper refuses unsigned builds anyway).
        // Told while holding (again each tick, in case the helper restarted) and once on release; otherwise left
        // alone, so it can exit when idle.
        if helper == .enabled, isApp, !CommandLine.arguments.contains("--snapshot"), awdl.hold || was {
            HelperClient.holdAWDL(awdl.hold)
        }
        awdlUp = HelperKit.awdlIsUp()
        // The helper checks every second: read the link again once it has acted, not at the next tick.
        if awdl.hold != was { Task { try? await Task.sleep(for: .seconds(1.5)); awdlUp = HelperKit.awdlIsUp() } }
        // The app or its root helper (both live in AWDLControl.app, so they group under one name).
        awdlConflict = groups.contains { $0.name == "AWDLControl" }
            || NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == AWDL.otherApp }
    }

    /// The app in front. The menu bar's owner first: opening Strain's panel doesn't take the menu bar from a game.
    private func frontApp() -> AWDL.App? {
        let ws = NSWorkspace.shared
        guard let app = [ws.menuBarOwningApplication, ws.frontmostApplication].compactMap({ $0 })
                .first(where: { $0.processIdentifier != getpid() }),
              let id = app.bundleIdentifier else { return nil }
        return AWDL.App(bundleID: id, name: app.localizedName ?? id,
                        category: app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["LSApplicationCategoryType"] as? String },
                        path: app.bundleURL?.path)
    }

    /// Starts keeping the Mac awake for `minutes` (nil = indefinitely), replacing any running session.
    func keepAwake(minutes: Int?) { awakeUntil = minutes.map { .now + Double($0) * 60 } ?? .distantFuture }
    func stopAwake() { awakeUntil = nil }

    /// Holds or releases the assertion for the current state and schedules the end. Snapshots and dev runs never hold.
    private func applyAwake() {
        guard isApp, !CommandLine.arguments.contains("--snapshot") else { return }
        if let until = awakeUntil, until <= .now { return awakeUntil = nil }  // re-enters with nil
        Awake.hold(Awake.type(on: awakeUntil != nil, locked: locked, letDisplaySleep: awakeLetDisplaySleep, letLockedSleep: awakeLetLockedSleep))
        awakeTimer?.cancel()
        guard let until = awakeUntil, until != .distantFuture else { return }
        awakeTimer = Task { [weak self] in
            // The continuous clock counts time asleep (lid closed), so a session that ran out meanwhile ends on wake.
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
            if !Task.isCancelled, let self, self.awakeUntil == until { self.awakeUntil = nil }
        }
    }

    /// Turns Strain's root helper on (macOS then wants an OK in System Settings) or off.
    func setHelper(_ on: Bool) {
        guard switching.insert("helper").inserted else { return }
        Task {
            if on { helperError = HelperClient.enable() } else { HelperClient.disable() }
            applyAWDL()
            switching.remove("helper")
        }
    }

    func tick() async {
        // Utility QoS: low priority and energy-efficient, but not confined to the efficiency cores like background,
        // so sampling still runs when the Mac is busy: exactly when Strain matters.
        var (s, procs, srv, ticks) = await Task.detached(priority: .utility) {
            let procs = sampleProcesses()
            return (SystemSample.read(), procs, sampleServers(procs: procs), readCoreTicks())
        }.value
        if fakeRed { s.pressure = 4 }
        servers = srv
        let now = Date.now
        if let until = awdlPausedUntil, until <= now { awdlPausedUntil = nil }
        // ponytail: battery is polled each tick (10 s); an IOPS run-loop source if that lag ever matters
        let battery = Awake.onBattery
        if battery, !onBattery, awakeStopOnBattery { awakeUntil = nil }  // only on the switch, like unplugging
        onBattery = battery
        if weeklyCheckDue(at: now) { Task { await weeklyCheck() } }
        if tab == .controls { await refreshRadios() }  // the AirDrop status depends on both radios
        if displayKeys { DisplayKeys.start(prompt: false) }  // picks up an Accessibility grant, or drops a revoked one
        keysBlocked = displayKeys && !DisplayKeys.running
        applyAWDL()
        apply(s, procs, at: now)
        record(ticks, s, at: now)  // after apply: the history point carries this sample's swap rate
        if isApp {
            try? FileManager.default.createDirectory(at: Store.statusFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? diagnostics().write(to: Store.statusFile, atomically: true, encoding: .utf8)
        }
    }

    /// The running app's latest diagnostics, rewritten every tick, so `Strain --report` (say over SSH) prints the
    /// live monitor's view: its real level, hold and swap rate, not a one-off sample.
    static let statusFile = Explanations.unknownFile.deletingLastPathComponent().appendingPathComponent("status.txt")

    /// `Strain --report`: prints the running Strain's status, or why there is none.
    static func report() -> String {
        guard let text = try? String(contentsOf: statusFile, encoding: .utf8),
              let at = (try? statusFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return "No status yet: is Strain running on this Mac?" }
        let age = Date.now.timeIntervalSince(at)
        return age > Thresholds.interval * 3 ? "Strain isn't running (last status \(Int(age / 60)) min old):\n\n" + text : text
    }

    /// Per-core usage, swap-in rate and the history behind the meter details.
    private func record(_ ticks: [CoreTicks], _ s: SystemSample, at now: Date) {
        cores = coreUsage(lastTicks, ticks)
        lastTicks = ticks
        if let (prev, t) = lastSample, now.timeIntervalSince(t) > 1 {
            swapInRate = max(0, s.swapInMB - prev.swapInMB) / now.timeIntervalSince(t) * 60
        }
        lastSample = (s, now)
        guard !cores.isEmpty else { return }
        history.append(HistoryPoint(t: now, cpu: cores.reduce(0, +) / Double(cores.count) * 100, memGB: s.memUsedMB / 1024,
                                    swapRate: monitor.swapRate))
        history.removeAll { now.timeIntervalSince($0.t) > 600 }
    }

    private func apply(_ s: SystemSample, _ procs: [Proc], at now: Date) {
        let g = group(procs)
        (system, groups, processCount, updated) = (s, g, procs.count, now)
        if let notice = monitor.step(s, g, at: now, title: explanations.title) { notify(notice) }
        if monitor.level > .green {
            explanations.logUnknowns(Array(culprits.prefix(5)))
            logged = Explanations.readUnknowns()
        }
        refreshUnknowns()
    }

    /// Reads Login Items with sfltool: through the helper (no prompt) when it's on. Without it, sfltool as the user
    /// shows a Touch ID prompt, so that fallback runs only when `prompting` (the user's click).
    func loadBackground(prompting: Bool = true) async {
        guard !loadingBackground else { return }
        loadingBackground = true
        var text = await HelperClient.loginItems() ?? ""
        if text.isEmpty, prompting { text = await Task.detached { readLoginItemsText() }.value }
        let items = dedupe(parseBTM(text))
        backgroundFailed = items.isEmpty
        if !items.isEmpty {
            LoginItemsCache.save(text)
            (background, backgroundRead) = (sortedBackground(items), .now)
        }
        loadingBackground = false
    }

    /// Sizes every Clean item off the main thread (seconds on a big cache folder). One scan at a time.
    func scanClean() async {
        guard !scanning else { return }
        scanning = true
        cleaned = [:]  // "Freed …" badges belong to the last measurement
        let running = Cleanup.runningApps(), roots = devRoots
        // Utility QoS: long disk walks the user waits on, but not worth the performance cores at full tilt.
        async let sims = Task.detached(priority: .utility) { DevCleanup.readSimulators() }.value
        async let found = Task.detached(priority: .utility) { DevCleanup.scan(roots: roots) }.value
        cleanSizes = await Task.detached(priority: .utility) { Cleanup.sizes(running: running) }.value
        simulators = await sims
        let used = simulators
        async let unused = Task.detached(priority: .utility) { DevCleanup.readUnusedRuntimes(simulators: used) }.value
        archives = await Task.detached(priority: .utility) { Cleanup.size(of: Store.archivesURL) }.value
        runtimes = await unused
        projects = await found
        disk = Disk.read()
        scanning = false
    }

    /// Check now: measures every Clean section and stamps the time.
    func checkNow() async {
        guard !scanning else { return }
        await scanClean()
        lastCheck = .now
    }

    /// Once a week, on AC power, while the Mac is calm, never in a snapshot: the scan walks disks, so it must not
    /// become the strain Strain reports.
    private func weeklyCheckDue(at now: Date) -> Bool {
        if fakeWeek { return true }
        guard isApp, !CommandLine.arguments.contains("--snapshot"), !scanning, !onBattery, monitor.level == .green else { return false }
        return now.timeIntervalSince(lastCheck ?? .distantPast) >= Thresholds.checkDays * 86400
    }

    /// Measures, then sends one notification if enough can go. Deletes nothing: cleaning stays a click in Clean.
    private func weeklyCheck() async {
        let forced = fakeWeek
        fakeWeek = false
        await checkNow()
        guard forced || Double(cleanable) >= Thresholds.checkMinGB * 1e9,
              UserDefaults.standard.string(forKey: "notify") != "off" else { return }
        let title = "Strain: \(formatBytes(cleanable)) to clean"
        let body = Store.checkLine(cleanParts) + ". Open Strain's Clean tab to choose what goes."
        guard isApp else { return print("\(title)\n\(body)") }
        let content = UNMutableNotificationContent()
        (content.title, content.body) = (title, body)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "weekly-check", content: content, trigger: nil))
    }

    /// Every Clean section's total, largest first: each cache, build folders, simulators.
    var cleanParts: [(title: String, bytes: Int64)] {
        var parts = Cleanup.items.map { ($0.title, cleanSizes?[$0.id] ?? 0) }
        parts.append(("Project build folders", (projects ?? []).reduce(0) { $0 + $1.size }))
        parts.append(("Simulators", simulators.reduce(0) { $0 + $1.size }))
        parts.append(("Unused simulator runtimes", runtimes.reduce(0) { $0 + $1.size }))
        return parts.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map { (title: $0.0, bytes: $0.1) }
    }

    /// "Simulators 4.3 GB, iOS DeviceSupport 5.6 GB, Go build cache 1 GB": the three largest parts.
    static func checkLine(_ parts: [(title: String, bytes: Int64)]) -> String {
        parts.prefix(3).map { "\($0.title) \(formatBytes($0.bytes))" }.joined(separator: ", ")
    }

    /// Reads both radios. Bluetooth's first read asks the user for Bluetooth access once (Info.plist explains why).
    func refreshRadios() async {
        // Separately: Bluetooth's first read waits on the permission prompt, and Wi-Fi shouldn't wait with it.
        async let bt = Task.detached { Radios.bluetoothOn() }.value
        wifi = await Task.detached { Radios.wifiOn() }.value
        bluetooth = await bt
    }

    func setRadio(_ id: String, on: Bool) {
        guard switching.insert(id).inserted else { return }
        if id == "wifi" { wifi = on } else { bluetooth = on }  // flip now; the read below corrects it if macOS refused
        Task {
            let ok = await Task.detached { id == "wifi" ? Radios.setWiFi(on) : Radios.setBluetooth(on) }.value
            if ok { radioFailed.remove(id) } else { radioFailed.insert(id) }
            await refreshRadios()
            switching.remove(id)
        }
    }

    /// Re-reads every screen's levels: the monitor's own buttons may have changed them.
    /// Screen changes come in bursts (wake, resolution): one read at a time, plus one more if any arrived meanwhile.
    func refreshScreens() async {
        guard !refreshingScreens else { screensStale = true; return }
        refreshingScreens = true
        repeat {
            (screensStale, touched) = (false, [])
            let list = Displays.list()
            let fresh = await Task.detached { Displays.read(list) }.value
            screens = Displays.merge(fresh, old: screens, touched: touched)
        } while screensStale
        refreshingScreens = false
    }

    /// Slider or key: updates the shown value now and writes it in the background (DDC) or directly (built-in).
    func setLevel(_ id: CGDirectDisplayID, _ vcp: VCP, _ value: Double) {
        guard let i = screens.firstIndex(where: { $0.id == id }) else { return }
        let v = min(max(value, 0), 1)
        touched.insert("\(id).\(vcp.rawValue)")
        switch vcp {
        case .brightness:
            screens[i].brightness = v
            if screens[i].ddc { DDC.set(id, .brightness, v) } else { Native.setBrightness(id, v) }
        case .volume:
            screens[i].volume = v
            DDC.set(id, .volume, v)
            if screens[i].muted, v > 0 { setLevel(id, .mute, 0) }  // turning it up unmutes, like macOS
        case .mute:
            screens[i].muted = v > 0
            DDC.set(id, .mute, v)
        }
    }

    /// A media key. Returns true when Strain handled it (macOS never sees it). Brightness goes to the external
    /// monitor under the pointer; volume to the monitor's speakers only when the audio output has no volume of its own.
    func handleKey(_ key: MediaKey, _ flags: CGEventFlags) -> Bool {
        let fine = flags.contains(.maskShift) && flags.contains(.maskAlternate), pointer = Displays.underPointer()
        switch key.kind {
        case .brightnessUp, .brightnessDown:
            guard let s = screens.first(where: { $0.id == pointer && $0.ddc }), let b = s.brightness else { return false }
            if key.down { setLevel(s.id, .brightness, Displays.step(b, up: key.kind == .brightnessUp, fine: fine)) }
        case .volumeUp, .volumeDown, .mute:
            let speakers = screens.filter { $0.ddc && $0.volume != nil }
            // CoreAudio last: it's IPC to coreaudiod, and this runs inside the key tap
            guard let s = speakers.first(where: { $0.id == pointer }) ?? (speakers.count == 1 ? speakers[0] : nil), let v = s.volume,
                  !Displays.outputHasVolume() else { return false }
            guard key.down else { return true }
            if key.kind == .mute { setLevel(s.id, .mute, s.muted ? 0 : 1) } else { setLevel(s.id, .volume, Displays.step(v, up: key.kind == .volumeUp, fine: fine)) }
        }
        return true
    }

    /// Bytes every Clean section can free right now.
    var cleanable: Int64 {
        (cleanSizes?.values.reduce(0, +) ?? 0) + (projects ?? []).reduce(0) { $0 + $1.size } + simulators.reduce(0) { $0 + $1.size }
            + runtimes.reduce(0) { $0 + $1.size }
    }

    /// A project is in use while a server runs from inside it: its build folders stay.
    func running(_ p: DevProject) -> Bool { servers.contains { $0.cwd.map { $0 == p.path || $0.hasPrefix(p.path + "/") } ?? false } }

    /// Deletes the build folders of these projects (one click, already confirmed). `id` keys the busy and result state.
    func deleteBuildFolders(_ list: [DevProject], id: String) {
        let list = list.filter { !running($0) }  // a server may have started since the list was drawn
        guard !list.isEmpty, cleaning.insert(id).inserted else { return }
        let roots = devRoots, before = list.reduce(0) { $0 + $1.size }
        Task {
            let left = await Task.detached { DevCleanup.remove(list.flatMap(\.artifacts), roots: roots) }.value
            let gone = Set(list.flatMap(\.artifacts).map(\.path).filter { !FileManager.default.fileExists(atPath: $0) })
            projects = projects?.compactMap { p in
                var p = p
                p.artifacts.removeAll { gone.contains($0.path) }
                return p.artifacts.isEmpty ? nil : p
            }
            let after = list.flatMap(\.artifacts).filter { !gone.contains($0.path) }.reduce(0) { $0 + $1.size }
            cleaned[id] = CleanResult(freed: before - after, left: left)
            disk = Disk.read()
            cleaning.remove(id)
        }
    }

    /// `simctl erase`: the simulator stays, its apps and data go. Shut down ones only.
    func erase(_ sim: Simulator) {
        let id = "sim." + sim.udid
        guard !sim.booted, cleaning.insert(id).inserted else { return }
        Task {
            let ok = await Task.detached { exitStatus("/usr/bin/xcrun", ["simctl", "erase", sim.udid]) == 0 }.value
            simulators = await Task.detached { DevCleanup.readSimulators() }.value
            let after = simulators.first { $0.udid == sim.udid }?.size ?? 0
            cleaned[id] = CleanResult(freed: ok ? max(0, sim.size - after) : 0, left: ok ? 0 : 1)
            disk = Disk.read()
            cleaning.remove(id)
        }
    }

    nonisolated static let archivesURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/Archives")

    /// `simctl runtime delete`: frees the runtime's disk image. Xcode downloads it again if a simulator needs it.
    func deleteRuntime(_ r: SimRuntime) {
        let id = "runtime." + r.id
        guard cleaning.insert(id).inserted else { return }
        Task {
            let used = simulators
            let ok = await Task.detached { exitStatus("/usr/bin/xcrun", ["simctl", "runtime", "delete", r.id]) == 0 }.value
            runtimes = await Task.detached { DevCleanup.readUnusedRuntimes(simulators: used) }.value
            let gone = ok && !runtimes.contains { $0.id == r.id }
            cleaned[id] = CleanResult(freed: gone ? r.size : 0, left: gone ? 0 : 1)
            disk = Disk.read()
            cleaning.remove(id)
        }
    }

    /// `simctl delete unavailable`: simulators whose iOS version is no longer installed.
    func deleteUnavailableSimulators() {
        guard cleaning.insert("sim.unavailable").inserted else { return }
        Task {
            _ = await Task.detached { exitStatus("/usr/bin/xcrun", ["simctl", "delete", "unavailable"]) }.value
            simulators = await Task.detached { DevCleanup.readSimulators() }.value
            disk = Disk.read()
            cleaning.remove("sim.unavailable")
        }
    }

    /// Runs after the user's second click on the item's Clean button. Marks the item busy at once (the delete can
    /// take a minute), then re-measures only that item.
    func clean(_ item: CleanItem) {
        guard cleaning.insert(item.id).inserted else { return }
        let running = Cleanup.runningApps(), before = cleanSizes?[item.id] ?? 0
        Task {
            let (left, after) = await Task.detached { (Cleanup.clean(item, running: running), Cleanup.size(item, running: running)) }.value
            cleanSizes?[item.id] = after
            cleaned[item.id] = CleanResult(freed: max(0, before - after), left: left)
            disk = Disk.read()
            cleaning.remove(item.id)
        }
    }

    private func sortedBackground(_ items: [BackgroundItem]) -> [BackgroundItem] {
        let t = explanations
        return items.sorted { ($0.status == .on ? 0 : 1, $0.title(t).lowercased()) < ($1.status == .on ? 0 : 1, $1.title(t).lowercased()) }
    }

    var activeSort: Sort { sort ?? (monitor.assessment.memory ? .memory : .cpu) }

    var culprits: [Group] {
        activeSort == .memory ? groups.sorted { $0.rssKB > $1.rssKB } : groups
    }

    func title(_ g: Group) -> String { explanations.title(g.name) }

    /// Unexplained processes: logged under strain, plus any in the top 25 by CPU or memory. Computed once per sample.
    private func refreshUnknowns() {
        let live = (Array(groups.prefix(25)) + groups.sorted { $0.rssKB > $1.rssKB }.prefix(25)).map { (name: $0.name, path: $0.path) }
        var seen = Set<String>()
        unknowns = (logged + live).filter { explanations.entry($0.name, path: $0.path) == nil && seen.insert($0.name).inserted }
    }

    func clearLog() {
        try? "".write(to: Explanations.unknownFile, atomically: true, encoding: .utf8)
        logged = []
        refreshUnknowns()
    }

    private func notify(_ n: Notice) {
        let mode = UserDefaults.standard.string(forKey: "notify") ?? "all"
        guard mode != "off", mode != "red" || n.level == .red else { return }
        let title = "Strain: \(n.reason)"
        var body = "Strain's Clean tab shows caches and build folders you can delete."  // a full disk has no process to blame
        if let culprit = n.culprit {
            guard let g = groups.first(where: { $0.name == culprit }) else { return }
            body = "Top culprit: \(self.title(g)), \(Int(g.cpu.rounded()))% CPU, \(formatMemory(kb: g.rssKB))."
            if let what = explanations.entry(g.name, path: g.path)?.what { body += " " + what }
        }
        guard isApp else { return print("\(title)\n\(body)") }
        let content = UNMutableNotificationContent()
        (content.title, content.body, content.sound) = (title, body, .default)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Plain-text report to paste into a chat or issue.
    func diagnostics() -> String {
        let s = system
        var lines = [
            "Strain \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · \(Date.now.formatted())",
            "Level: \(monitor.level.title) (\(monitor.assessment.reason))",
            "Memory: \(gb(s.memUsedMB)) of \(gb(s.memTotalMB)) GB used, pressure \(s.pressureName)",
            String(format: "Swap: %@ GB used, swapping %.0f MB/min", gb(s.swapUsedMB), monitor.swapRate),
            String(format: "CPU: load %.1f on %d cores", s.load, s.cores),
            "Disk: \(Disk.read().summary)",  // fresh: `disk` only updates with the Clean tab
            "Keep awake: \(awakeUntil.map { $0 == .distantFuture ? "on, indefinitely" : "on until \($0.formatted(date: .omitted, time: .shortened))" } ?? "off")",
            "", "Top by memory:",
        ]
        lines += groups.sorted { $0.rssKB > $1.rssKB }.prefix(10).map(row)
        lines += ["", "Top by CPU:"] + groups.prefix(10).map(row)
        let listening = servers.filter { $0.kind != .macOS }
        if !listening.isEmpty {
            lines += ["", "Listening servers:"] + listening.map {
                "  \($0.project ?? $0.command) :\($0.ports.map(String.init).joined(separator: ", :"))\($0.exposed ? " (network)" : "")"
            }
        }
        return lines.joined(separator: "\n")
    }

    private func row(_ g: Group) -> String {
        "  \(title(g)) ×\(g.pids.count): \(Int(g.cpu.rounded()))% CPU, \(formatMemory(kb: g.rssKB)), up \(formatDuration(g.seconds))"
    }

    /// `Strain --snapshot out.png [--tab=apps|servers|background|controls|clean|unknown] [--meter=memory|swap|cpu] [--fake-red] [--expand] [--dark]`:
    /// renders the panel from live data and exits.
    func snapshot(to path: String) {
        let args = CommandLine.arguments
        var s = SystemSample.read()
        if fakeRed { s.pressure = 4 }
        let procs = sampleProcesses()
        servers = sampleServers(procs: procs)
        for i in 0..<3 {  // three readings = two history points, enough to draw the charts
            record(readCoreTicks(), s, at: .now - Double(2 - i) * 1.5)
            Thread.sleep(forTimeInterval: 0.4)
        }
        if let m = args.first(where: { $0.hasPrefix("--meter=") }) { meter = MeterKind(rawValue: String(m.dropFirst(8))) }
        if let t = args.first(where: { $0.hasPrefix("--tab=") }), let tab = Tab(rawValue: String(t.dropFirst(6))) { self.tab = tab }
        if tab == .clean {
            cleanSizes = Cleanup.sizes(running: Cleanup.runningApps())
            (projects, simulators) = (DevCleanup.scan(roots: devRoots), DevCleanup.readSimulators())
            (runtimes, archives) = (DevCleanup.readUnusedRuntimes(simulators: simulators), Cleanup.size(of: Store.archivesURL))
        }
        if tab == .controls { (wifi, bluetooth, screens) = (Radios.wifiOn(), Radios.bluetoothOn(), Displays.read(Displays.list())) }
        applyAWDL()
        for i in 0..<Thresholds.hold { apply(s, procs, at: .now - Thresholds.interval * Double(Thresholds.hold - 1 - i)) }
        if args.contains("--expand") {
            expanded = switch tab {
            case .apps: culprits.first?.name
            case .servers: servers.first.map { String($0.pid) }
            case .background: background?.first?.id
            case .clean: Cleanup.items.first.map { "clean." + $0.id }
            case .controls: nil
            case .unknown: nil
            }
        }
        // A real (offscreen) window, not ImageRenderer: buttons, menus and scroll views render as they do in the panel.
        let view = hostOffscreen(dark: args.contains("--dark"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }

    /// Hosts the panel in a borderless window placed off screen. `--window` uses it to profile the open panel live.
    @discardableResult func hostOffscreen(dark: Bool = false) -> NSView {
        let view = NSHostingView(rootView: Panel().environment(self).background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: view.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return view
    }
}

extension SystemSample {
    var pressureName: String { pressure >= 4 ? "Critical" : pressure >= 2 ? "High" : "Normal" }
}

@main
struct Strain: App {
    @State private var store = Store()
    @AppStorage("menuBarText") private var menuBarText = true

    init() {
        let args = CommandLine.arguments
        if args.contains("--report") { print(Store.report()); exit(0) }  // before any window or menu bar item
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let store = store
            DispatchQueue.main.async { store.snapshot(to: args[i + 1]) }  // after the app is up, so a window can show
        }
        if args.contains("--window") {
            let store = store
            DispatchQueue.main.async { store.hostOffscreen() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel().environment(store)
        } label: {
            Image(nsImage: menuBarIcon(store.monitor.level, awake: store.awakeUntil != nil))
            if menuBarText, store.monitor.level > .green, let top = store.culprits.first {
                Text(store.title(top))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

extension Level {
    var color: Color { [.green, .orange, .red][rawValue] }
    var nsColor: NSColor { [.systemGreen, .systemOrange, .systemRed][rawValue] }
    var symbol: String { ["gauge.with.dots.needle.33percent", "gauge.with.dots.needle.67percent", "gauge.with.dots.needle.100percent"][rawValue] }
    var title: String { ["All good", "Under strain", "Struggling"][rawValue] }
}

/// A tinted gauge, plus a cup while keeping the Mac awake. Non-template when amber or red, so the colour survives the
/// menu bar's own tinting.
@MainActor func menuBarIcon(_ level: Level, awake: Bool = false) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    let tint = level == .green ? NSColor.labelColor : level.nsColor
    let gauge = NSImage(systemSymbolName: level.symbol, accessibilityDescription: level.title)!
        .withSymbolConfiguration(config.applying(.init(paletteColors: [tint])))!
    guard awake else {
        gauge.isTemplate = level == .green  // green follows the menu bar; amber and red stand out
        return gauge
    }
    let cup = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Keeping awake")!
        .withSymbolConfiguration(config.applying(.init(paletteColors: [.labelColor])))!
    let gap = 4.0, size = NSSize(width: gauge.size.width + gap + cup.size.width, height: max(gauge.size.height, cup.size.height))
    let image = NSImage(size: size, flipped: false) { _ in
        gauge.draw(at: NSPoint(x: 0, y: (size.height - gauge.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        cup.draw(at: NSPoint(x: gauge.size.width + gap, y: (size.height - cup.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
    image.isTemplate = level == .green
    image.accessibilityDescription = "\(level.title), keeping awake"
    return image
}

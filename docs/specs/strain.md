# Strain: a menu bar app that names what's slowing the Mac

Status: built and published 2026-10-22. Repo `josephgoksu/strain`.

## 1. Context and objectives

2026-10-22: the Mac crawled (load 133, 6.1 GB of 7 GB swap). The cause was two iOS simulators left booted for 5 days, hidden as ~40 separate daemons in Activity Monitor. Next time the cause will be something else.

Strain watches **symptoms**, not known causes, names the culprit **app** in plain English, and leaves every action to Joseph.

| # | Success criterion | How it's tested |
|---|---|---|
| S1 | Menu bar icon is green / amber / red within 30 s of pressure changing | State machine unit test + manual run |
| S2 | Under pressure, the menu lists culprits grouped by owning app, top first | Grouping unit test on real paths from 2026-10-22 |
| S3 | 40 simulator daemons show as one row "iOS Simulator" | Grouping test |
| S4 | Each row: CPU %, memory, running time, one-line "what is this?", Quit button (or "system service" when it can't be quit) | UI run + screenshot |
| S5 | One notification per sustained episode, naming the top culprit; no repeat for the same culprit within 30 min | State machine test |
| S6 | Explanations come from `Resources/explanations.json`, no network, no LLM | Test that loads + validates the file |
| S7 | Unknown processes seen under pressure get logged so a Claude session can add them | Test on the unknowns writer |
| S8 | Strain itself stays under 1% CPU and 40 MB physical footprint | `ps` + `footprint` while running |
| S9 | Icon: macOS squircle, gradient + grain texture, crisp at 16 px | Rendered PNG reviewed |

## 2. Out of scope

Auto-kill or throttle, phone push, history or charts, runtime LLM calls, Upbar integration, App Store, notarization (ad-hoc signed, local install only).

## 3. Prior art

| Source | What we reuse |
|---|---|
| `opensource/upbar` | SwiftPM layout, `build.sh` (.app bundle, ad-hoc sign, `install` mode), `scripts/icon.swift` (icon drawn in code), Swift Testing style |
| This session's `ps` / `sysctl` output | Test fixtures for parser and grouping |
| `kern.memorystatus_vm_pressure_level` | macOS's own pressure signal (1 normal, 2 warn, 4 critical) |

## 4. Design

### Sampling (every 10 s)

| Signal | Source | Why this one |
|---|---|---|
| Memory pressure | `sysctl kern.memorystatus_vm_pressure_level` | Apple's own verdict, beats home-made math |
| Swap used + swap-out rate | `sysctl vm.swapusage`, `host_statistics64` swapouts | Rate is the real signal. Size alone misled v1 (see below) |
| Memory used | `host_statistics64`: app + wired + compressed | Matches Activity Monitor's "Memory Used" |
| Load | `getloadavg()` vs `hw.ncpu` | CPU saturation |
| Per process | `ps -Ao pid=,uid=,pcpu=,rss=,etime=,comm=` | Reads root processes without a privileged helper (verified 2026-10-22) |

`ponytail:` shelling out to `ps` every 10 s costs ~5 ms. Move to `proc_pid_rusage` only if S8 fails.

### Pressure levels

| Level | Any of (held for 3 samples = 30 s) |
|---|---|
| Red | pressure 4, swapping > 300 MB/min, pressure 2 while swapping > 50 MB/min, load > 4 × cores |
| Amber | pressure 2, swapping > 50 MB/min, swap > half of RAM, load > 2 × cores, any group > 80% CPU for 30 min |
| Green | none of the above for 3 samples |

v1 used swap used ÷ swap total. macOS grows the swap file on demand (3 → 4 → 7 GB) and rarely shrinks it, so that ratio sat at 80% with normal pressure and flagged a false red (2026-10-22 screenshot). v2 drops it.

Thresholds live in one `Thresholds` struct. Settings shows them read-only.

### Grouping (path → owner)

1. Path contains `/CoreSimulator/` → `iOS Simulator`
2. Path contains `.app/` → outermost `.app` name (`Brave Browser Helper (Renderer)` → `Brave Browser`)
3. Otherwise → executable name (`mediaanalysisd`)

Group = sum CPU, sum RSS, oldest start, PIDs, owner uid.

### Explanations

`Resources/explanations.json`, keyed by group name:

```json
{ "mediaanalysisd": { "what": "Photos scanning faces and scenes.", "advice": "Finishes on its own. Restart if it runs for days." } }
```

- Seeded with every culprit seen on 2026-10-22 (~30 entries).
- Missing key → row shows the path and "Unknown".
- Unknown group names seen under amber/red append to `~/Library/Application Support/Strain/unknown.txt` (deduped). A Claude session reads it and adds entries. Ships with the next build.

### Actions (user clicks, never automatic)

| Group | Button | Does |
|---|---|---|
| iOS Simulator | Shut down | `xcrun simctl shutdown all` |
| Regular app (has `NSRunningApplication`) | Quit | `terminate()` (app gets to save) |
| User-owned process | Quit | `SIGTERM` to its PIDs |
| Root / other-user process | none | "System service. macOS restarts it." |

Every button asks to confirm first: "Quit Brave Browser (12 processes)?"

### UI (native macOS style)

- `MenuBarExtra` with `.window` style, system materials, SF Symbols, SF Pro, follows light/dark.
- Menu bar glyph: `gauge.with.dots.needle.33percent` (green), `…67percent` (amber), `…100percent` (red), tinted.
- Panel: header (level + one-line reason, e.g. "Swap 6.1 of 7 GB"), then up to 5 culprit rows, then footer (Launch at login toggle, Quit Strain).
- Row: app icon (`NSWorkspace.icon(forFile:)`, or SF Symbol `gearshape` for daemons), name, CPU / memory / running time in `.monospacedDigit()`, explanation in secondary text, button on the right.
- Green state: the panel shows the top 3 consumers anyway, so it's never empty.

### Notification

`UNUserNotificationCenter`, fired on entering amber or red: "Strain: Swap 6.1 GB. Top: iOS Simulator (310% CPU, 4.2 GB)". 30 min cooldown per culprit. Clicking it opens the panel.

### Logo

`scripts/icon.swift` draws it in code (Upbar pattern) and emits `Resources/Strain.icns` via `iconutil`.

- Apple 1024 grid squircle, soft drop shadow.
- Diagonal gradient, warm to hot (deep indigo → magenta → amber), reads as "heat building".
- Grain: seeded per-pixel noise overlay at ~6% opacity, same output every run.
- Glyph: white gauge needle, top highlight like native macOS icons.
- At 16 / 32 px: grain and highlight dropped, so it stays crisp.

## 5. Boundaries

| Always | Ask first | Never |
|---|---|---|
| Unit test the parser, grouping, state machine, explanations file | Creating the GitHub repo and pushing | Kill or throttle anything without a click + confirm |
| Keep thresholds in one struct | Adding any dependency | Network calls, telemetry, LLM at runtime |
| Run `swift test` + `./build.sh` before each commit | Any privileged helper or root access | Send process lists anywhere |

## 6. Implementation slices

- [x] **1. Scaffold.** `Package.swift` (macOS 14, Swift 6), `AGENTS.md`, `context/README.md`, `.gitignore`, `build.sh`, `Resources/Info.plist` (`LSUIElement`), a `MenuBarExtra` showing a static glyph. `git init`.
  Verify: `swift build && ./build.sh` produces `dist/Strain.app`; launching it shows the glyph.
- [x] **2. Sampler.** `Sampler.swift`: parse `ps` output + read the sysctls. Fixture = real `ps` lines from 2026-10-22 (paths with spaces, `14-12:41:13` elapsed format).
  Verify: `swift test` (parser + elapsed-time tests).
- [x] **3. Grouping.** `Grouping.swift`: path → owner, aggregate.
  Verify: `swift test` (Brave helper → Brave Browser, CoreSimulator → iOS Simulator, bare daemon → name).
- [x] **4. Pressure state machine.** `Pressure.swift`: levels, 3-sample hold, notify decision with per-culprit cooldown.
  Verify: `swift test` (spike ignored, sustained fires once, cooldown respected, recovery to green).
- [x] **5. Explanations.** `Resources/explanations.json` seeded, `Explanations.swift` lookup + unknown writer.
  Verify: `swift test` (file parses, no empty fields, unknowns deduped).
- [x] **6. Panel UI + actions.** Header, rows, buttons with confirm, simulator shutdown.
  Verify: `./build.sh install`, open the panel, screenshot; Quit a test process (`sleep 999`) from the panel.
- [x] **7. Notifications + launch at login.** `UNUserNotificationCenter`, `SMAppService.mainApp`.
  Verify: force red with a test threshold override, see one notification; toggle login item, check in System Settings.
- [x] **8. Logo.** `scripts/icon.swift` → `Resources/Strain.icns` + `docs/icon.png`.
  Verify: view the PNG at 1024 and 32 px.
- [x] **9. Publish (ask first).** `gh repo create josephgoksu/strain --private`, push.

## 7. Done gate

- [x] `swift test` green (16 tests)
- [x] `./build.sh install` runs; launch-at-login toggle built, **not yet toggled live**
- [x] S1 S2 S3 S5 S6 S7: unit tests + live run with `--swap-red` (now `--fake-red`) (went red, one notification posted, `unknown.txt` got `Spotify`)
- [~] S4: panel rendered via `--snapshot` from live data; **Quit / Shut down clicks and confirm dialog not exercised live** (no screen access from the build session)
- [x] S8: 17 MB phys footprint, ~0.4% CPU (`footprint`, `ps`). RSS reads 82 MB, which is shared frameworks
- [x] S9: `docs/icon.png` (1024) and `docs/icon-32.png` reviewed
- [x] `context/growing-explanations.md`

Deviation: clicking the notification does not open the panel. `MenuBarExtra` has no API to open itself; add an `NSStatusItem` if it matters.

## 8. v2 (2026-10-22)

| Area | Change |
|---|---|
| Signals | Swap-out rate + swap vs RAM replace swap used ÷ total. Memory used shown |
| Header | Status badge, reason, since when, `⋯` menu |
| Meters | Memory, Swap (with MB/min), CPU (load as % of cores) tiles with bars |
| List | Memory / CPU sort (auto follows the strain), share bar per row, tap to expand: advice, running time, path, Quit…, Reveal, Activity Monitor; context menu |
| Names | Optional `title` in `explanations.json` ("claude" → "Claude Code"); reverse-DNS names shortened |
| Menu | Settings, Unknown Processes, Open Activity Monitor, Copy Diagnostics, About, Quit |
| Settings window | General (login, notify all / red only / never, menu bar name, row count, thresholds read-only), Explanations (unknowns list, copy prompt for Claude), About |
| Menu bar | Top culprit's name next to the gauge when not green (toggle) |
| Check modes | `--snapshot out.png [--fake-red] [--expand] [--dark]` |

## 9. Background Items tab (2026-10-22)

Settings → Background (also `⋯` → Background Items…). Source: `sfltool dumpbtm`, macOS's Login Items database. Since macOS 27 it needs admin (Touch ID), so it runs only on a click and the output is cached in `~/Library/Application Support/Strain/login-items.txt`; the tab shows the cached list and when it was read.

| Shown | Rule |
|---|---|
| Opens at login | enabled `app` records (matches System Events' login items exactly) |
| App background tasks, login helpers, agents, admin helpers (daemons) | by BTM `Type`; Quick Look, Spotlight, dock tile plug-ins skipped |
| Status | On / Off / Blocked (disallowed in System Settings) |
| Running | matched to live groups by app bundle, background-task app, or executable; interpreters (`bash`, `node`) never matched |
| Explanation | table by launchd label, then name; else a plain fallback per kind. Background tasks never borrow the app's process entry |

Strain never turns items off: "Open Login Items…" opens System Settings.

## 10. Servers view (2026-10-22)

Panel switch **Apps | Servers**. Every TCP listener (read in-process with libproc, ~1 ms per tick, matching `lsof -iTCP -sTCP:LISTEN` without sudo; working folder and command line likewise, no spawns) with project (from the process's working folder; `~/Development/<area>/<repo>` drops the area), ports, Local / Network (bound beyond loopback), full command, memory, uptime. Order: dev projects, tools, apps, macOS (hidden by default). Open `http://localhost:<port>`; Stop sends SIGTERM after a confirm, own processes only. Root-owned listeners are invisible without admin.

## 11. One panel (2026-10-22)

Everything lives in the menu bar panel; the Settings window is gone.

| Area | Now |
|---|---|
| Tabs | Apps · Servers · Background · Controls · Clean · Unknown. Icon tab bar, selected tab shows its title, sliding highlight, counts as badges |
| Settings | `⋯` menu: launch at login, culprit in menu bar, notifications, rows, Copy Diagnostics, Activity Monitor, Login Items, Quit |
| Copy prompts | ✨ on the header (what's slowing the Mac), every expanded row (app, server, background item), each unknown, and the whole Unknown list. Built in `Prompts` |
| Destructive actions | Two-step inline button (Quit → "Quit 22?" → done) instead of NSAlert, which closed the panel |
| Motion | Symbol bounce on level change, pulse while red, numeric transitions on meters and badges, copy → ✓, row expand transitions, hover fills, press scale |
| Height | Constant across tabs, expanded rows and levels (header always has its third line) |
| Unknown | Logged-under-strain + anything unexplained in the top 25 by CPU or memory; exiting `(name)` processes skipped |

## 12. Clean tab (2026-10-22)

Quick wins, with no background agent and no guesswork.

| Part | What |
|---|---|
| Quick actions | Flush DNS (admin), Free memory (`purge`, admin), Restart Dock / Finder / menu bar, Fix "Open With" (`lsregister -r`), Reset Quick Look, Stop simulators, Empty Trash (Finder). Stock macOS commands in `QuickAction.all`. Click twice; admin ones use macOS's own password sheet via `osascript ... with administrator privileges` |
| Free up space | Disk bar, then caches sized on first open, largest first: Go build, Xcode DerivedData, iOS DeviceSupport, Bun, npm, SwiftPM, Homebrew downloads, app caches (`~/Library/Caches/*` minus `com.apple.*`, the items above and running apps) |
| Safety | Deletes folder contents only, never the folder; never follows symlinks; refuses any path outside the allowlist (`Cleanup.allowed`). Tested on temp fixtures only |
| Skipped | Logs, Time Machine snapshots, Spotlight reindex, Docker prune, "large files" scan: either needs admin, Full Disk Access, or deletes things that aren't regenerable |

## 13. Explanations ladder (2026-10-22)

Table first (exact, then case- and version-insensitive), then path rules: Apple apps, Apple services, any other app described from its Info.plist (category + copyright). Unknown is what's left: CLIs and loose helpers. Rules and style live in `context/growing-explanations.md`; the style is a test.

## 14. Expandable meters (2026-10-22)

Click Memory, Swap or CPU: its details replace the list (panel height unchanged); a tab click or Close (Esc) goes back.

| Meter | Shows |
|---|---|
| CPU | Big number is real utilization (per-core ticks), not load. One bar per core, Efficiency then Performance; cores over 80% counted as maxed; load 1/5/15; thermal state; 10-min chart; top 3 by CPU |
| Memory | Stacked bar + legend: Apps, Wired, Compressed (and what it holds), Cached files, Free; pressure; 10-min chart; top 3 by memory |
| Swap | Write and read-back rates, swap files allocated, compressor ratio, 10-min chart of writes with the warn line; top 3 by memory |

Top-3 rows open that app in the Apps tab. History lives in memory only (60 points).

## 15. Developer cleanup (2026-10-23)

| Part | What |
|---|---|
| Project build folders | Walks ~/Development (and Developer, Projects, code, src, dev, repos, work, GitHub) for node_modules, .next, .turbo, .nuxt, .svelte-kit, .parcel-cache (beside package.json), target (beside Cargo.toml), .build (beside Package.swift). Grouped by project, sized, "touched" = newest of the folder, everything directly in it (manifests, lockfiles, the build folders, so installs and builds count) and its git index. "Clean N stale" deletes build folders of projects untouched `Thresholds.staleProjectDays` (30) days; a project with a listening server is never touched, checked again at delete time |
| Simulators | `simctl list -j` sizes (dataPathSize). Erase = `simctl erase` (shut down only); "Delete N unavailable" when any |
| More caches | Go modules (read-only folders made writable first), Cargo registry, pnpm, Yarn, uv, Gradle, CocoaPods. Empty or missing caches are hidden |
| Quick actions | Restart audio (admin), Restart Bluetooth (admin), Stay awake 1 h (caffeinate) |
| Strain | Disk under 10 GB free = amber, under 3 GB = red (swap needs room). Header shows "easing off" while a lower level waits out its hold |

## 16. Radio switches (2026-10-23)

Wi-Fi and Bluetooth tiles above the quick actions, Control Center style: one click flips power; turning Bluetooth off takes a second click (as macOS warns: Bluetooth keyboards and mice drop). A refused switch says "macOS refused" instead of silently flipping back. Wi-Fi via `networksetup -setairportpower`; Bluetooth via the private `IOBluetoothPreference{Get,Set}ControllerPowerState` (what blueutil uses), so no install. Bluetooth needs `NSBluetoothAlwaysUsageDescription` (one permission prompt); dev builds without it skip Bluetooth instead of crashing. A tile hides when its radio can't be read, including when Bluetooth access was denied (the call would just read "off").

## 17. AirDrop link (AWDL) (2026-10-23)

Card in Controls under the radios: live state of awdl0 (getifaddrs), three modes and why it's in that state.

| Mode | awdl0 |
|---|---|
| AirDrop on | macOS decides; AirDrop, AirPlay to Mac, Sidecar work |
| Low ping | held off; "Allow AirDrop 10 min" pauses the hold |
| Auto | held off only while the front app (menu bar owner, so opening Strain's panel doesn't count) is a game (Games category or under Steam's steamapps) or GeForce NOW, Moonlight, Parsec, Steam, Zoom, FaceTime, Riverside. Running in the background doesn't count: Steam and Zoom stay open all day |

Holding needs root, so Strain's helper does it (section 19): Strain tells it hold/release each tick over XPC, and the hold lives on that connection, so quitting or crashing Strain releases AirDrop. Only the installed, signed app holds, never a dev run or snapshot. Changing mode ends an "Allow AirDrop" pause. Warns when AWDL Control (app or helper) is running, since the two fight and that is what blocked AirDrop.

## 18. Controls tab (2026-10-23)

Switches and fixes moved out of Clean into their own tab: Connections (Wi-Fi, Bluetooth, AirDrop link), Fix something (Dock, Finder, menu bar, Open With, Quick Look, audio), Network (Flush DNS, Restart Bluetooth), Utilities (Free memory, Stop simulators, Stay awake, Empty Trash). Clean only frees space.

## 19. Strain's helper (2026-10-23)

A root launchd daemon inside the app (`Contents/MacOS/StrainHelper`, `Contents/Library/LaunchDaemons/com.josephgoksu.strain.helper.plist`), registered with `SMAppService.daemon`. "Turn on helper" (Controls footer, or the AirDrop card) registers it; macOS asks once under System Settings → Login Items → Allow in the Background. Replaces the sudo rule (the helper deletes `/etc/sudoers.d/strain` on start) and the old flag-file guard.

| Does | How |
|---|---|
| Admin tiles | `run(action)` by name from `HelperKit.actions`; never a command line from the app |
| AirDrop hold | `holdAWDL` per connection; checks awdl0 every second; releases when the connection drops |
| Login Items | `sfltool dumpbtm` as root: no Touch ID, read on opening Background |

Lifecycle: launchd starts it on the first call; it exits after 30 s idle (no hold, no call in flight), so a rebuilt binary takes over on the next call. Strain only talks to it while holding (each tick) and once on release. On SIGTERM (turned off, logout) it brings awdl0 back up first; a marker in /var/run makes a crashed helper do the same on its next start. Login Items load by themselves through it; the Touch ID fallback runs only on a click.

Trust both ways: the helper's listener requires Strain signed by team `J9GF96BYUX` (`HelperKit.appRequirement`), and Strain requires the same of the helper. `build.sh` signs both with Reaktif LLC's Developer ID and the hardened runtime; the app's only entitlement is Apple Events (Empty Trash goes through Finder). Helper off, or a dev build: tiles fall back to macOS's password sheet, Login Items to Touch ID, and the AirDrop modes ask for the helper.

## 20. Remote check and Intel (2026-10-23)

`Strain --report` prints the running app's diagnostics (level, culprits, meters, servers, disk) and exits without showing anything. The app rewrites them to `~/Library/Application Support/Strain/status.txt` every tick, so the report is the live monitor's view; older than three ticks, it says Strain isn't running. Remote use goes over Tailscale SSH (`ssh <mac> …/Strain --report`) or Screen Sharing: Strain opens no port. A tailnet dashboard (read-only, `tailscale serve`, owner-only) was designed and shelved until this proves too little.

`build.sh` builds universal (arm64 + x86_64). macOS 14 limits Intel to 2018 and later Macs. The Intel slice is untested: no Rosetta or Intel Mac here.

## 21. Displays (2026-10-25)

Card per screen in Controls under Connections; read fresh each time Controls opens or the screens change (the monitor's own buttons may have moved them).

| Screen | Brightness | Volume |
|---|---|---|
| Built-in, Apple displays | private DisplayServices (what Control Center uses) | macOS's own |
| Other external | DDC/CI VCP 0x10 over Apple silicon's `IOAVServiceWriteI2C`/`ReadI2C`, no install, no root | VCP 0x62 + mute 0x8D when the monitor has speakers |

| Key | Goes to |
|---|---|
| Brightness, F14/F15 | the DDC monitor under the pointer; else macOS |
| Volume, mute | the DDC monitor under the pointer (or the only one) when the audio output has no volume of its own (HDMI/DP audio); else macOS |

Keys are opt-in ("Brightness and volume keys control these"): an active event tap on media keys needs Accessibility, and the card says so until it's granted. 1/16 steps, ⇧⌥ for 1/64. Warns when MonitorControl is running, since both answer the keys. Pairing: the framebuffer before each `DCPAVServiceProxy` in the registry carries the EDID vendor/product/serial, matched to `CGDisplay{Vendor,Model,Serial}Number`. Mute isn't read (monitors misreport it). Not built yet: contrast, software dimming below 0, built-in→external brightness sync, an on-screen OSD, Intel (`IOFBCopyI2CInterfaceForBus`) DDC.

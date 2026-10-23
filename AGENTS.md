# Strain

Private macOS menu bar app: watches memory pressure, swap, load and per-process CPU, and names the app behind it in plain English. Never acts without a click.

| | |
|---|---|
| Spec | `docs/specs/strain.md` |
| Stack | Swift 6, SwiftPM, SwiftUI `MenuBarExtra`, macOS 14+, no dependencies |
| Test | `swift test` |
| Build | `./build.sh` → `dist/Strain.app` (universal: Apple silicon + Intel); `./build.sh install` → `~/Applications`, relaunch |
| Check | `Strain --snapshot out.png [--tab=apps|servers|background|controls|clean|unknown] [--meter=memory|swap|cpu] [--fake-red] [--expand] [--dark]` captures the real panel (offscreen window) from live data. `Strain --window` hosts the open panel offscreen with live ticks, to profile it with `footprint` |
| Remote | `~/Applications/Strain.app/Contents/MacOS/Strain --report` prints the running app's status (rewritten each tick to `~/Library/Application Support/Strain/status.txt`); over Tailscale SSH: `ssh <mac> <that path> --report` |
| Icon | `swift scripts/icon.swift` → `Resources/Strain.icns`, `docs/icon.png` |
| Learnings | `context/` (see `context/README.md`) |

Rules:
- Never kill, throttle or signal anything without a user click and a confirm.
- No network, telemetry or LLM calls at runtime.
- Thresholds live in `Thresholds` only.
- Explanations live in `Resources/explanations.json` only. Grow it from `~/Library/Application Support/Strain/unknown.txt` (see `context/growing-explanations.md`).

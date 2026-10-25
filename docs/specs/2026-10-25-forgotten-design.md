# Forgotten (design, 2026-10-25)

Status: draft, waiting for approval. Once built, it folds into `strain.md` as a numbered section.

## Goal

Strain names what you started and forgot (an app you closed, a server left behind a closed terminal) even when it's quiet, and tells you once a day. Quitting stays your click.

## Today

Strain flags only *busy* things: a group above `Thresholds.hogCPU` (80%) for `hogSeconds` (30 min). Forgotten things are mostly quiet: memory and a port at 0% CPU.

## Decision

| Question | Answer |
|---|---|
| How far does Strain go? | **List + daily digest.** A Forgotten section in Apps, one notification a day. Quit = click + confirm (existing `Action`). Keep = silence that item for good |
| Auto-quit | No. Revisit per app only if Keep stays rare and Quit is clicked on the same app every day |

## Signals

Each is cheap: the process list Strain already reads each tick, plus app-switch notifications.

| # | Signal | Rule | Example | Measured here (2026-10-25) |
|---|---|---|---|---|
| 1 | **Terminal closed** | Mine, parent pid 1, no terminal (`tty` `??`), not inside an `.app`, not a macOS path, not a launchd job (`launchctl list` PIDs), alive ≥ `Thresholds.forgottenAfter` (2 h) | `vite` after closing its Ghostty tab | 3 hits, all deliberate daemons: tmux server, gpg-agent, keyboxd. So it ships with a default Keep list for tools that detach on purpose: tmux, screen, gpg-agent, keyboxd, ssh-agent |
| 2 | **Unused app** | A regular app (Dock icon) not brought to the front for `Thresholds.unusedAppHours` (4 h). Last-active times saved, so a Strain restart doesn't reset them; unknown = launch time | Xcode, Docker, Slack with its window closed | Window counts don't work: a closed window stays as a hidden window (Tailscale: 5 windows, 0 on screen), and other Spaces aren't "on screen". Last-front time is reliable |
| 3 | **Idle memory** | Any group ≥ `Thresholds.idleMemoryMB` (500 MB) under 1% CPU for 2 h | Ollama with a model loaded, a booted simulator | Uses the per-group history Monitor already keeps, like `hogSince` |
| 4 | **Old dev server** | A Servers row of kind `.dev` up ≥ 12 h, or one that also matches signal 1 | `bun dev` on :5173 since yesterday | Servers already knows kind, ports and age |

Finder, Strain, login items that open at login, and menu bar apps (no Dock icon) never count.

## Surface

| Part | What |
|---|---|
| Apps tab | A **Forgotten** section above the list, only when something qualifies. Row: name, why ("terminal closed · 3 h", "not used for 6 h", "idle 4 h · 2.1 GB", "server on :5173 · 2 days"), memory, **Quit** (confirm), **Keep** |
| Digest | At most one a day, at the first calm tick after `Thresholds.digestHour` (17:00): "3 still running: vite 2 days, Docker idle 6 h, 3.1 GB". Follows the Notifications setting. Nothing qualifies = no notification |
| Keep | Saved by group name. "Kept" list in the ⋯ menu to undo |
| Report | `Strain --report` gets a Forgotten line |

## Slices

| # | Slice | Done when |
|---|---|---|
| 1 | `ps` adds `ppid` and `tty`; signal 1 with the default Keep list; Forgotten section with Quit and Keep | A `sleep 99999 &` disowned from a closed shell shows; tmux doesn't |
| 2 | Signal 2: last-front times from `NSWorkspace.didActivateApplicationNotification`, saved | An app left in the background past the limit shows; Finder never does |
| 3 | Signals 3 and 4 | Unit tests on the rules with fixed samples |
| 4 | Daily digest and the report line | `--fake-digest` posts it now |

## Not building

| Idea | Why not |
|---|---|
| Auto-quit after idle | Breaks "never acts without a click"; see Decision |
| Real-time nudge per item | One notification a day is the point; per-item alerts become noise you ignore |
| Window counting | Unreliable (see signal 2) |
| Accessibility-based window checks | Needs a permission for a weaker signal than last-front time |

## Risks

| Risk | Guardrail |
|---|---|
| False alarms on things kept running on purpose (dev API for the iPhone, Ollama) | Keep button; launchd jobs never count (the iPhone dev API is one); 2 h minimum age |
| Quitting the wrong process | Same `Action` rules as Apps: own processes only, SIGTERM, apps via `terminate()`, confirm first |
| Last-front times lost | Saved in UserDefaults; unknown falls back to launch time, which only makes an app look *more* recently used |

## Tripwire

If, after a week, Keep is clicked more than Quit, the rules are too loose: tighten them before adding anything.

# Weekly check and wider Clean (design, 2026-10-25)

Status: draft, waiting for approval. Once built, it folds into `strain.md` as a numbered section.

## Goal

Strain finds everything worth cleaning on this Mac, says so once a week, and deletes nothing without a click.

## Decision

| Question | Answer |
|---|---|
| May the weekly run delete? | **No.** Report only: one notification, then the usual click and confirm |
| Data vs cache | Caches (rebuilt on their own) get Clean. Data (models, transcripts, archives) gets Reveal in Finder or Move to Trash, per item, never a bulk button |
| Network | None, as everywhere in Strain |

## Measured on this Mac (2026-10-25)

| Where | Size | Kind |
|---|---|---|
| `/Library/Developer/CoreSimulator/Volumes` (simulator runtimes) | 16 GB | Rebuildable: Xcode downloads again |
| `~/Library/Application Support/Claude/vm_bundles` | 11 GB | Unknown: needs checking before any delete |
| `~/Library/Developer/Xcode/iOS DeviceSupport` | 5.6 GB | Cache, already in Clean |
| `~/.claude/projects` | 5.0 GB | Data: session transcripts |
| `~/Library/Developer/CoreSimulator/Devices` | 4.3 GB | Data per simulator, already in Clean (erase) |
| `~/Library/Application Support/Claude/Partitions` + `Cache` | 2.5 GB | Cache |
| `~/.cache/codex-runtimes`, `~/.codex/sessions` | 2.5 GB | Cache, data |
| `~/.ollama/models` | 262 MB | Data: models |
| `~/Library/Logs` | 52 MB | Logs |
| `~/Downloads` | 3.6 MB | Too small here to matter |

## Slices, in build order

Each slice ships alone, with a test, and works without the weekly check.

| # | Slice | What | Done when |
|---|---|---|---|
| 1 | **Check now** | One button in Clean's header runs the existing scan and shows one total plus the three largest items. "Last checked" under it | Total matches the sum of the rows |
| 2 | **Weekly check** | The same scan in the background, at most once in `Thresholds.checkDays` (7), only on AC power, at utility QoS. One notification: "31 GB to clean: simulator runtimes 16 GB, …". Skipped silently when under `Thresholds.checkMinGB` (5) | `--fake-week` forces a run and posts the notification |
| 3 | **Simulator runtimes** | `xcrun simctl runtime list -j`: runtimes no simulator uses. Delete with `xcrun simctl runtime delete`. Plus Xcode Archives and iOS Device Logs | The runtime a simulator uses never shows as deletable |
| 4 | **AI tools** | One section, a row per tool: Claude, Claude Code, Codex, Ollama, Hugging Face, LM Studio, whisper. Each row splits cache (Clean) from data (Reveal, Move to Trash). Models list by name and size (Ollama manifests, Hugging Face `hub/models--*`) | A running tool's cache is skipped, as App caches does today |
| 5 | **Where the space went** | The ten largest folders under the home folder (two levels), and Downloads files untouched for 90 days. Reveal and Move to Trash only | Nothing outside the home folder is listed |
| 6 | **Logs and login items** | Logs older than 30 days in `~/Library/Logs` (Clean). Background tab badges: "App missing" (target gone) and "Not notarized" (`spctl --assess`) | Badges match `spctl` on three known items |

Smaller adds, fold into a slice: clang module cache (`~/Library/Caches/clang`) into App caches; Reindex Spotlight (`mdutil -E /`, admin) into quick actions.

## Not building

| Idea | Why not |
|---|---|
| Malware scanner | Needs a threat database kept up to date over the network; macOS XProtect already runs. Slice 6 covers the useful part: helpers nobody signed |
| Removing language files | Breaks app signatures for about 50 MB |
| Stripping unused CPU code from apps | Breaks signatures; the next app update puts it back |
| App updater | Network; Homebrew does it |
| Disk map | The largest-folders list answers the same question in a table |
| Automatic deletes on a schedule | Breaks "never acts without a click" |

## Risks

| Risk | Guardrail |
|---|---|
| The weekly scan strains the Mac it watches | AC power only, utility QoS, once a week, and skipped while the level is amber or red |
| Deleting data someone wanted (models, transcripts) | Data rows only Reveal or Move to Trash, one item at a time, never permanent |
| `vm_bundles` (11 GB) is something Claude needs | Listed with size and Reveal only, until we know what deleting it does |
| Sizing `/Library/Developer` | Read only; deletes go through `simctl`, never `rm` |

## Tripwire

If the first two weekly checks each find under 5 GB, drop slice 2 and keep Check now.

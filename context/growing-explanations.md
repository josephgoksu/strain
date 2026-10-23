# Growing explanations.json

Strain logs every group it sees under amber or red that has no entry, one line each: `name<TAB>path`, in
`~/Library/Application Support/Strain/unknown.txt`.

To grow the table (a Claude session does this well):

1. Read `unknown.txt`.
2. For each name, add `"name": { "what": "...", "advice": "..." }` to `Resources/explanations.json`. Key = the group name exactly as logged (app name for anything inside a `.app`).
3. Run `swift test`. It fails on blank fields or bad JSON.
4. `./build.sh install`, then delete the handled lines from `unknown.txt`.

`what` says what it is in plain English. `advice` says whether it ends on its own, and what to do if not. Say "Can't be quit." for root daemons macOS restarts.

## How a process gets its explanation

| Step | Rule | Example |
|---|---|---|
| 1 | Table, exact name | `Claude` (app) vs `claude` (CLI) |
| 2 | Table, ignoring case and a version suffix | `python3.12`, `Python` → `python` |
| 3 | App under `/System/Applications/` | "One of Apple's built-in apps." |
| 4 | Path under `/System/`, `/usr/libexec/`, `/usr/sbin/`, `/sbin/` | "A built-in macOS service." |
| 5 | Any other `.app`: its Info.plist category + copyright holder | "A utility by Tailscale Inc." |
| 6 | Nothing matched | Unknown tab, logged to `unknown.txt` |

So Unknown is only CLIs and helpers outside app bundles. Add a table entry when the generic text is wrong or too vague (Dock: "use Clean > Restart Dock"). One key per tool: `python` covers every version, so never add `python3`.

## Style (enforced by `shippedTableFollowsTheStyle`)

- `what`: one plain sentence; the first ~50 characters show in the row, the rest when expanded.
- `advice`: does it end on its own, and what to do if not. "Can't be quit." for services macOS restarts.
- Every field ends with a period, ≤ 160 characters, no dashes.

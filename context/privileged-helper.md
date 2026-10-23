# Privileged helper (SMAppService)

| Fact | Why it matters |
|---|---|
| Both binaries must be signed by team `J9GF96BYUX` (Reaktif Developer ID) | The XPC requirement checks the team; an ad-hoc or Apple Development build can't talk to the helper and falls back to password prompts |
| `HelperKit.actions` is the only list of root commands | Adding an admin tile means adding its argv there too; a test keeps the tile's fallback command in sync |
| The daemon plist uses `BundleProgram` + `AssociatedBundleIdentifiers` | SMAppService daemons run from inside the app bundle; moving or deleting Strain.app removes the helper with it |
| Approval lives in System Settings → Login Items → Allow in the Background | `register()` alone leaves it `.requiresApproval` |
| Every rebuild replaces the helper binary in place | The helper exits after 30 s with nothing to do (no hold, no call in flight), so launchd starts the new binary on the next call. A helper that never exits would serve the old code until reboot |
| The ad-hoc signature (before 2026-10-23) made macOS re-ask Bluetooth and Automation permissions on every install | Stable signing fixed it |
| Hardened runtime needs `com.apple.security.automation.apple-events` (Resources/Strain.entitlements) | Strain is the responsible process for the osascript it spawns; without it, Empty Trash's Finder event can be refused silently |
| The helper releases AirDrop on SIGTERM, and on start if `/var/run/com.josephgoksu.strain.awdl-held` exists | Turning the helper off, logout, or a crash mid-hold must not leave awdl0 down |

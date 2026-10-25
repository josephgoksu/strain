# Changelog

All notable changes to Strain. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions: [Semantic Versioning](https://semver.org/). A tag `vX.Y.Z` releases the matching section.

## [Unreleased]

### Added

- Displays in Controls: brightness for every screen, plus volume for monitors with speakers (DDC/CI on Apple silicon).
- Optional brightness and volume keys for external monitors, following the pointer; F14/F15 work as brightness keys. Needs Accessibility.
- Keep awake in Controls and the ⋯ menu: indefinitely or 10 min to 12 h, optionally letting the display sleep, sleeping while locked, or stopping on battery. A cup shows in the menu bar while on.
- Check now in Clean: measures again, then names the three largest parts and when it was checked.
- A weekly check: on AC power, while the Mac is calm, Strain measures Clean and notifies once when 5 GB or more can go. It deletes nothing.
- Clean lists simulator runtimes no simulator uses (several GB each) with a Delete, Xcode Archives with Show in Finder, and iOS Device Logs.
- AI tools in Clean: web caches of Claude, Cursor and LM Studio (cleaned only while closed), plus their data (sandbox VM, transcripts, models by name) sized and shown in Finder, never deleted.
- Where the space went, in Clean on a click: the ten largest folders in your home folder, and downloads untouched for 90 days with Move to Trash.
- Old logs in Clean: log files and crash reports older than 30 days.
- Background badges: Leftover (its app or launch file is gone), Not notarized (apps Gatekeeper rejects), Unsigned (programs with no valid signature).
- Plain English explanation for whisper-cli.

### Changed

- New README art.
- The Stay awake 1 h tile is gone: Keep awake replaces it, and it never leaves a `caffeinate` running after Strain quits.

## [0.1.2] - 2026-10-25

### Fixed

- Light mode is readable: the panel gets an opaque white base instead of the washed out menu bar material, and captions use a darker gray.

## [0.1.1] - 2026-10-25

### Added

- Plain English explanations for deadcode, gpg-agent, the Go linker, golangci-lint, local API servers, grype and osv-scanner.

## [0.1.0] - 2026-10-23

### Added

- Menu bar level (All good, Under strain, Struggling) from memory pressure, swap, CPU load, long-running hogs and free disk, with one notification per culprit.
- Apps, Servers, Background, Controls, Clean and Unknown tabs, each process explained in plain English.
- Meter details: memory breakdown, per-core load (Performance and Efficiency), swap activity, 10 minutes of history.
- Clean: developer caches, stale build folders, simulator data.
- Controls: Wi-Fi, Bluetooth, AirDrop or low ping (AWDL), one-click macOS fixes.
- Strain's helper (SMAppService) for admin actions without a password.
- `Strain --report` for checks over SSH.
- Universal build: Apple silicon and Intel.

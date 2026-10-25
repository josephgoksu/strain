# Changelog

All notable changes to Strain. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions: [Semantic Versioning](https://semver.org/). A tag `vX.Y.Z` releases the matching section.

## [Unreleased]

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

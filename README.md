# Storage Assistant

Storage Assistant is a recommendation-first macOS cleanup prototype. It scans user-owned and developer-heavy locations, explains why an item may be removable, and only moves files to Trash when the user explicitly approves it.

## What It Scans

- `~/Downloads` for old or large installers, archives, disk images, and other review-worthy items.
- `~/.Trash` for already-trashed storage.
- `~/Library/Caches` grouped by top-level cache folder.
- `~/Library/Logs` grouped by top-level log folder.
- Developer storage:
  - Unity project generated folders such as `Library`, `Temp`, `Obj`, `Logs`, `Build`, and `Builds`.
  - Unity Hub/editor/package caches and installed editor summary.
  - Xcode DerivedData, Archives, DeviceSupport, and simulator devices.
  - Docker Desktop disk image and cache.
  - Python package caches and virtual environments.
  - Node package caches and `node_modules`.
  - Homebrew cache.
  - Generic build artifacts such as `.build`, `build`, `dist`, `target`, `.gradle`, `.tox`, `.next`, `.nuxt`, and related generated project output.
- Leftovers and services:
  - Library leftovers for apps that do not appear to be installed.
  - Saved application state, preferences, and exact bundle-ID Application Support folders.
  - Hidden home app configuration folders such as `~/.hammerspoon`, plus stale `~/.config/<app>` folders, when no installed app name matches.
  - Sandboxed app traces such as `~/Library/Containers`, `~/Library/Group Containers`, `~/Library/Application Scripts`, `~/Library/Preferences/ByHost`, `~/Library/WebKit`, `~/Library/HTTPStorages`, and `~/Library/Cookies`.
  - Broader review-only traces in user and system Library locations, including Application Support, Preferences, Logs, Caches, plug-ins, Quick Look generators, Spotlight importers, preference panes, screen savers, privileged helpers, shared support folders, and package receipts.
  - Launch agents and launch daemons that point to missing programs or appear to be running without a matching installed app.
  - Known licensing/service leftovers such as PACE/iLok components.

High-risk recommendations are review-only. Riskier systems such as Docker's disk image and simulator devices are surfaced so you can inspect them, not deleted directly.

Launch agents, launch daemons, privileged helpers, known licensing services, home app configuration folders, containers, plug-ins, shared support, package receipts, and system-wide traces are review-only. If a service appears to be running, unload it or use the vendor uninstaller before removing files manually.

## Run the CLI

```sh
swift run storage-assistant
```

For JSON output:

```sh
swift run storage-assistant --json
```

For scan phase output:

```sh
swift run storage-assistant -- --progress
```

## Run the macOS App

```sh
./scripts/run-app.sh
```

The SwiftUI app can reveal items in Finder, ignore recommendations, and move low/medium-risk recommendations to Trash.

The sidebar groups results into broad review areas rather than one row per tool: Quick Wins, User Files, Caches & Logs, Developer Storage, App Leftovers & Services, and High Risk Review. Individual recommendations still show their more specific detector type.

`swift run StorageAssistantApp` builds the same executable, but SwiftPM does not create a normal `.app` bundle. The helper script wraps the executable in a local app bundle and opens it like a regular macOS app.

## 0.1.1 Polish

- Configurable developer project roots from the Settings toolbar button.
- Adjustable project search depth.
- Visible scan progress with cancellation.
- Recommendation details with dates, risk, confidence, rationale, and safety notes.
- Cleanup history UI for items moved to Trash.
- Ignored items UI with an Unignore action.
- Scanner tests for configured project roots, Unity detection, download recommendations, and duplicate path handling.
- Conservative 0.2 foundation for uninstalled app leftovers and stale/running background services.
- Broad review-area sidebar plus generic build artifact detection.
- Scan snapshots for growth tracking.
- Permission diagnostics for paths that cannot be fully scanned.
- Configurable cleanup thresholds.
- Command suggestions for safer Docker/Xcode cleanup paths.

Run tests with:

```sh
swift test
```

## Current Safety Rules

- No background deletion.
- No permanent deletion.
- No scanning of `/System`, `/private`, `/bin`, or `/sbin`. System-wide `/Library`, `/Users/Shared`, and package receipt traces are surfaced as review-only.
- Risky developer artifacts are marked review-only when direct deletion would be unsafe.
- Running services, launch daemons, and privileged helper tools are review-only.
- Ignore rules and cleanup history are saved locally in `~/Library/Application Support/Storage Assistant/state.json`.
- Scan settings are saved in the same local state file.

## Next Useful Milestones

- Folder access prompts and Full Disk Access guidance.
- Growth tracking UI with per-category and per-path deltas.
- Optional guarded execution for Docker/Xcode cleanup commands.
- Detector refactor into smaller modules.

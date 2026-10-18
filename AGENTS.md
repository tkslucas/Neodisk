# AGENTS.md

Neodisk is a native disk space analyzer for macOS and Linux in Swift: one shared, UI-free core and one native
app per platform (SwiftUI/AppKit on macOS, GTK 4/libadwaita on Linux). Layout and data flow: ARCHITECTURE.md.

## Commits

- Small, focused Conventional Commits; don't mix refactors with behavior changes.
- Bump `AppVersion.string` (`Sources/NeodiskAppModel/AppVersion.swift`) on every user-visible change.

## macOS

- Swift 6, macOS 14.0+. **Command Line Tools only, no Xcode**: `swift build`, `swift test`, `swift run`;
  never `xcodebuild`.
- `swift test` works on CLT only because `Package.swift` declares swift-testing and the
  `lib_TestingInterop` linker flags. Don't remove either.
- Run the app: `swift run -c release Neodisk`. `-Xswiftc -DNEODISK_NIGHTLY` builds Neodisk Nightly, which
  has its own name, id and storage.

### Dev hooks

The most used ones; the rest live in `Sources/NeodiskUI/Dev/`.

- `NEODISK_AUTOSCAN=<path>`: scan on launch. `NEODISK_AUTOREVEAL=<path>`: then select and reveal that node.
- `NEODISK_UI_SNAPSHOT=<out.png>`: offscreen whole-window capture; runs as an accessory, never on screen.
- `Neodisk --render-png <scan-path> <out.png> [scale fx fy]`: headless treemap render
  (`NEODISK_RENDER_COLOR_MODE`, `NEODISK_RENDER_PALETTE`, `NEODISK_RENDER_STYLE`, `NEODISK_RENDER_CLOUD_ONLY=0`).
- `NEODISK_ANALYSIS_TAB`, `NEODISK_VIZ_MODE`, `NEODISK_TREEMAP_STYLE`, `NEODISK_OUTLINE_POSITION`,
  `NEODISK_UPDATE_STATE`: force that UI state on launch without persisting it.
- `NEODISK_INCREMENTAL=0`: every rescan runs the full traversal (fallback, and the honest benchmark baseline).
- `NEODISK_SCAN_TIMING=1`: per-phase timings on stderr as `NEODISK_SCAN_TIMING phase=<name> ms=<value>`
  lines, a parsing contract for tooling; `diskscan --bench-rescan` exercises it.
- `NEODISK_HEADLESS=1` + `NEODISK_BENCH_AUTOQUIT=1` (+ `NEODISK_BENCH_RESCANS=<n>`): off-screen felt-time
  benchmark runs. A bench run that could draw on screen is a bug.
- `NEODISK_SNAPSHOT_DIR=<dir>`: isolate the snapshot cache from the developer's real one.
- Headless runs share the `Neodisk` UserDefaults domain with your `swift run` sessions: check
  `defaults read Neodisk <key>` before concluding a feature regressed.
- The sidebar's material background renders blank in offscreen captures; verify the sidebar by tests and a human look.

## Linux

- Swift 6.4; GTK 4.14+ and libadwaita 1.5+ (Ubuntu 24.04 is the floor: newer API needs a runtime check, see
  the dlsym pattern in `Accent.swift`). Packages: `libgtk-4-dev libadwaita-1-dev libzstd-dev pkg-config`.
- `swift build` builds the core and the `neodisk` GTK app; `swift test` runs the core suites
  (NeodiskUITests is macOS-only). `swift run neodisk` runs from a checkout; `Packaging/linux/install.sh [prefix]`
  installs a static-stdlib release build.
- SwiftPM's `prohibited flag(s): -pthread` and `dependency 'sparkle' is not used` aren't ours: "zero warnings"
  means compiler warnings.
- Static Swift runtime links need `--build-system native` for now.
- Hooks: `NEODISK_AUTOSCAN`, `NEODISK_UI_SNAPSHOT` (GSK render to PNG, then quit; `NEODISK_SNAPSHOT_DELAY`),
  `NEODISK_VIZ_MODE`, `NEODISK_TREEMAP_STYLE`, `NEODISK_ANALYSIS_TAB`, `NEODISK_SELECT`, `NEODISK_SCAN_TIMING`.
  `XDG_CONFIG_HOME` isolates settings. Example:
  `NEODISK_AUTOSCAN=/usr NEODISK_UI_SNAPSHOT=/tmp/shot.png xvfb-run -a -s "-screen 0 1600x1000x24" .build/debug/neodisk`

## Product constraints

- **Read-only.** The app never modifies or deletes user files; it writes only its preferences and snapshot
  cache. Move-to-Trash was removed on purpose: don't reintroduce it.
- Scans stream partial trees, then a final snapshot. The treemap and outline are primary navigation, not extras.
- Toolbar buttons stay persistent and disable when unusable; they never appear and disappear.
- The scan progress bar is always determinate, never moves backward within a session (fallbacks and phase
  changes included) and is full exactly when the scan is done. Quiet phases hold their value under a caption.
  The drifting stripe sheen (`StripedProgressBar`) is the liveness signal: keep it.
- Cloud-only (dataless) local files, like iCloud Drive's, weigh in the maps only with the toolbar's toggle on.

## Localization

- The UI follows the system language. Catalogs live in `Localization/<lang>.lproj/` and must land in
  `Bundle.main`, so they aren't a SwiftPM resource; `swift run` shows English, verify translations in the
  packaged `.app`.
- Keys are the English source string verbatim. Add each new key to every catalog, byte-identical, with matching
  `%@`/`%lld` counts (`plutil -lint`); `en.lproj` is the reference.
- A `String` passed to `Text` isn't localized: use `Text(LocalizedStringKey(x))` or
  `String(format: NSLocalizedString(…), …)`.
- The Linux app reads the same catalogs through `L("…")`; reuse a Mac string when the wording fits. Strings
  the shared model produces go through `AppStrings.localized`. Test Linux with `LANGUAGE=de` (locale installed).

## Platform and core split

- `NeodiskKit` never imports AppKit, SwiftUI or GTK (the target graph enforces it); its public API is narrow.
- `NeodiskAppModel` uses `package` access: visible to both apps, not public API.
- A platform difference below the UI goes in the core behind `#if canImport`/`#if os` with one internal
  interface; apps never branch on platform for data behavior.
- Logic both apps need (classification, colors, scene building, search) goes in NeodiskAppModel, never one
  app with a copy in the other.
- Data bugs get fixed in NeodiskKit; coordination, selection and navigation in NeodiskUI. Avoid new dependencies.

## Done means

- `swift build` with zero compiler warnings and `swift test` green on macOS and Linux. Guard Apple-only tests
  with `#if canImport(Darwin)`. Test scanning, path, geometry and formatting changes; look at a render for visuals.

## Notes

- Workspace text scales (`TextScale`): write `.neoFont(…)`, never `.font(.system(size:))`; sizes around text read `neoTextScale`.
- AppKit surfaces scale through `OutlineRowMetrics.scale` and `TreemapScene.labelScale`; window chrome stays system size.
- A push button sizes from `controlSize`, not its label: pair `.neoFont(.body)` with `.neoControlSize(base:)`.
- Inline bars beside text (capacity, percentage, scan progress) scale with the text too.
- Treemap gestures mutate the `CALayer` transform in `TreemapNSView`, never SwiftUI state (that version twitched).
- On macOS 14+ `NSView.clipsToBounds` defaults to false and overrides `.clipped()`; set it explicitly.
- Keep `WorkspaceView`'s SwiftUI identity stable from scanning to displaying, or the treemap is torn down.
- The scan event stream is bounded (`bufferingNewest`); the `.finished` event must never be dropped.
- Timing-sensitive suites are `.serialized`; prefer eventual-state assertions over sleeps.
- Never rely on `CATextLayer.truncationMode` (overflow renders blank); labels pre-ellipsize via `endTruncated`.

## Linux app notes

- GTK objects are `GPtr`; convert with `ptr(x)` and `raw(x)`. `_new` results are owned; `gtk_*_new(model)`
  takes ownership of one model reference.
- Signals use the trampolines in `Support/Signals.swift`; `notify::` must use `connectNotify` or it crashes.
- UI state lives in `AppModel` (`@Observable`, `@MainActor`, bound with `track { … }`); the main actor runs on
  GLib's loop, so `Task { @MainActor in … }` is safe from any GTK callback.
- Visualizations rasterize off the main actor into one texture and draw hover/selection on top; never
  re-rasterize on hover.

## Starting points

- Scanning: `NeodiskKit/Services/ScanEngine.swift`; tree and index: `NeodiskKit/Models/FileTreeStore.swift`.
- UI state: `NeodiskUI/Model/NeodiskViewModel.swift` (+ extensions) and `ScanCoordinator.swift`.
- Scan start, rescan, snapshot cache and restore: `NeodiskUI/Model/ScanSessionModel.swift`.
- Treemap: `TreemapKit/CushionTreemapRenderer.swift` and `NeodiskAppModel/Treemap/TreemapScene.swift`.
- Linux scanning: `BulkDirectoryReader+Linux.swift`, `LinuxMountTable.swift`; Linux app: `NeodiskGTK/App/AppModel.swift`.

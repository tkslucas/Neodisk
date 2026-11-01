# AGENTS.md

Neodisk is a native disk space analyzer for macOS and Linux in Swift: one shared, UI-free core and one native
app per platform (SwiftUI/AppKit on macOS, GTK 4/libadwaita on Linux). The core and `diskscan` also build on
Windows. Layout and data flow: ARCHITECTURE.md.

## Commits

- Small, focused Conventional Commits; don't mix refactors with behavior changes.
- PRs don't touch `AppVersion.string` (`Sources/NeodiskAppModel/AppVersion.swift`): it's bumped once, in the release step (nightlies carry the date).

## macOS

- Swift 6, macOS 14.0+. **Command Line Tools only, no Xcode**: `swift build`, `swift test`, `swift run`;
  never `xcodebuild`.
- Agents and worktrees build with `--scratch-path <main checkout>/.build-<agent>.noindex`: one incremental folder per
  agent, reused across worktrees; `.noindex` keeps Spotlight from indexing it.
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
- `NEODISK_SNAPSHOT_DIR=<dir>`: isolate the snapshot cache (dev builds already use `Neodisk Dev`, never the app's).
- `NEODISK_AUTOSELECT=<path>[:<path>…]`: select those items after the scan (the last one primary), as ⌘-clicks would.
- `NEODISK_AUTOCOLLECT=<path>[:<path>…]`: collect those items in Cleanup after the scan; with
  `NEODISK_AUTOTRASH=1`, then move them as if confirmed (really trashes: temp dirs only); `=fail` fails every move,
  `=hold` holds them in the moving state (neither moves anything).
- Headless runs share the `Neodisk` UserDefaults domain with your `swift run` sessions: check
  `defaults read Neodisk <key>` before concluding a feature regressed.
- The sidebar's material background renders blank in offscreen captures: `NEODISK_SIDEBAR_SNAPSHOT=<out.png>`
  renders the sidebar alone (`NEODISK_SIDEBAR_SNAPSHOT_WIDTH`), `NEODISK_TABBAR_SNAPSHOT=<out.png>` the statistics
  tabs at several widths; both take `NEODISK_SNAPSHOT_APPEARANCE=light` and `NEODISK_SNAPSHOT_TEXT_SCALE`.
  `NEODISK_SIDEBAR_COLLAPSED=<volumes,cloudFiles,…>` collapses those sidebar sections for the run, unsaved.

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
  `NEODISK_VIZ_MODE`, `NEODISK_TREEMAP_STYLE`, `NEODISK_ANALYSIS_TAB`, `NEODISK_SELECT=<path>[:<path>…]`, `NEODISK_SCAN_TIMING`,
  `NEODISK_AUTOTRASH=<path>[:<path>…]` (moves them as if confirmed, reported as the window would; really trashes:
  temp dirs only; with `NEODISK_UI_SNAPSHOT`, the capture waits for the moves and shows the toast),
  `NEODISK_POPUP=primary|sections|status|views|preferences` (opens that menu; popovers miss the window capture, so grab the X screen).
  `XDG_CONFIG_HOME` isolates settings. Example:
  `NEODISK_AUTOSCAN=/usr NEODISK_UI_SNAPSHOT=/tmp/shot.png xvfb-run -a -s "-screen 0 1600x1000x24" .build/debug/neodisk`

## Windows

- Swift 6.4.2 with Visual Studio 2022's C++ tools and a Windows SDK. `swift build` builds the core and `diskscan`;
  `swift test` runs the core suites. CI: `.github/workflows/windows.yml`.
- Platform code sits next to the Linux code: `#if os(Windows)` arms and `+Windows.swift` files (`WindowsFileInfo`,
  `WindowsPath`, `WindowsVolume`), with `import WinSDK` only in files that need it: WinSDK's `UUID` and others
  shadow Foundation's.
- Paths stay `URL.path` spellings (`C:/Users/x`); Win32 calls go through `WindowsPath.withWidePath`, which adds
  `\\?\` past `MAX_PATH`. Never follow reparse points (`FILE_FLAG_OPEN_REPARSE_POINT`).
- Foundation on Windows: `FileManager.linkItem` makes a symbolic link (use `WindowsPath.createHardLink`) and
  `standardizedFileURL` breaks drive roots (use `WindowsPath.lexicallyStandardized`). Hidden means the attribute,
  not a dot name.
- Tests that need POSIX behavior get `#if !os(Windows)` with a one-line reason; Windows-only cases live in
  `WindowsPlatformTests`. Symbolic link tests need an elevated shell or Developer Mode.
- The app is `swift build --product neodisk` (`.build\debug\neodisk.exe`, a GUI program: no console, so logs go
  to `%LOCALAPPDATA%\Neodisk\Logs`, or to stderr when it's redirected). Settings: `%APPDATA%\Neodisk\settings.json`.
- App shell: `NeodiskWin` over `ScanWorkspace` (NeodiskAppModel). Custom-drawn chrome subclasses `SurfaceView`, whose
  element list feeds both hit-testing and its UI Automation provider; keep them one list. Message parameters are
  bit patterns: convert with `Int(bitPattern:)`/`truncatingIfNeeded:`, never `Int(wParam)` (handles trap).
- Hooks: `NEODISK_AUTOSCAN=<path>`, `NEODISK_UI_SNAPSHOT=<out.png>` (captures the window from the screen, backdrop
  included, then quits; `NEODISK_SNAPSHOT_PRINTWINDOW=1` uses PrintWindow), `NEODISK_THEME=light|dark`,
  `NEODISK_SCALE=<factor>` (lays out as at that DPI scale), `NEODISK_LANGUAGE=<tag>`, `NEODISK_NO_MICA=1`.
- The maps draw through `CNeodiskCanvas` (Direct3D 11, Direct2D, DirectWrite and WIC behind a C API); rasters
  build off the main thread and reach the canvas window by a posted message. Hooks: `NEODISK_CANVAS_PNG=<prefix>`
  renders the cushion, flat and sunburst headless to `<prefix>-<view>.png`, `NEODISK_CANVAS_BENCH=<report.txt>`
  times hover, resize and drill frames in a window, `NEODISK_CANVAS_DEMO=1` opens the canvas alone
  (`NEODISK_VIZ_MODE=sunburst`). The tree is `NEODISK_CANVAS_SCAN=<path>` or a synthetic one of
  `NEODISK_CANVAS_NODES=<count>`.

## Product constraints

- **Scanning is read-only; removal is the Trash only.** Besides its preferences and snapshot cache, the only
  change the app makes is moving items the user collected in Cleanup and confirmed to the Trash, each re-checked
  by `TrashSafetyPolicy` and `TrashMover` right before its move. Never delete permanently, never skip the checks,
  and never let a drag move or trash files behind the scan (drags out of the app only copy).
- Scans stream partial trees, then a final snapshot. The treemap and outline are primary navigation, not extras.
- Toolbar buttons stay persistent and disable when unusable. Only a button tied to absent content or a feature
  that's off goes away instead.
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

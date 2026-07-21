# AGENTS.md

This file tells coding agents how to work effectively in this repository.

## Purpose

Neodisk is a native macOS disk space analyzer built in Swift. It pairs a
classic analyzer UI (outline list + cushion treemap + file kinds) with
a fast, actor-based scan engine. When developing Neodisk, prioritize modern
Swift/SwiftUI practices and keep the scanning core UI-free.

## Commit Guidelines

- Make small, focused commits; each should be a single logical change.
- Avoid mixing refactors with behavior changes.
- Use Conventional Commits:
  - `fix: correct size totals for nested directories`
  - `feat: remember last opened scan location`
  - `perf: parallelize cushion rasterization over cells`
  - `refactor: narrow NeodiskKit public API`
- Bump `AppVersion.string` (`Sources/NeodiskUI/App/AppVersion.swift`) on every
  user-visible change; it shows in the sidebar and identifies the build.

## Environment Facts

- Swift 6, macOS 14.0+.
- **Command Line Tools only — no Xcode.** Use `swift build`, `swift test`,
  `swift run`; never `xcodebuild`.
- `swift test` works on CLT only because `Package.swift` declares the
  swift-testing dependency and the `lib_TestingInterop` linker flags. Do not
  remove either.
- Run the app: `swift run -c release Neodisk`.
- Dev hooks:
  - `NEODISK_AUTOSCAN=<path>` — scan on launch. Also accepts a connected
    cloud account's target ID (`cloudscan://<provider>/<account>`), composing
    with `NEODISK_CLOUD_FIXTURE` for headless cloud runs.
  - `NEODISK_CLOUD_FIXTURE=<path.json>` — register a fixture cloud-drive
    account (see `CloudFixture` in CloudScanKit), so the whole CloudScan
    pipeline — sidebar row, scan, visualizations, snapshot cache — runs
    without OAuth or network.
  - `NEODISK_GOOGLE_CLIENT_ID` / `NEODISK_GOOGLE_CLIENT_SECRET` — Google
    OAuth desktop client for the Connect Google Drive flow. The shipped
    client ID is baked into `GoogleOAuthConfiguration.swift` (public by
    nature; the flow is protected by PKCE). The client secret is not in this
    repo: release packaging injects it into Info.plist
    (`NeodiskGoogleClientSecret`), and dev builds pass it via the env var.
    Without a secret the connect action stays hidden.
  - `NEODISK_DROPBOX_APP_KEY` / `NEODISK_ONEDRIVE_CLIENT_ID` — same gate for
    the Dropbox and OneDrive connect actions (pure PKCE public clients, no
    secrets). With several providers configured the sidebar's connect button
    becomes a menu.
  - `NEODISK_AUTOREVEAL=<path>` — after the scan, select that node and
    expand its ancestors in the outline (deep trees in headless snapshots).
  - `NEODISK_INCREMENTAL=0` — disable incremental FSEvents rescans; every
    rescan runs the full traversal (fallback safety valve, and the honest
    baseline when benchmarking scan changes).
  - `NEODISK_SCAN_TIMING=1` — print per-phase scan timings to stderr as
    `NEODISK_SCAN_TIMING phase=<name> ms=<value> …` lines (traversal,
    assembly, first partial, replay, splice, snapshot encode/decode). The
    format is a parsing contract for measurement tooling; `diskscan
    --bench-rescan [--bench-touch <file>]` exercises the full
    incremental-rescan pipeline under it. In the app this also emits
    app-level *felt-time* marks (`phase=app.launchToScanStart`,
    `app.firstPartialDisplayed`, `app.scanFinishedToTreeDisplayed`,
    `app.feltTotal`, each tagged `mode=full|restore|rescan`) — process launch
    and the UI tail (splice apply, treemap layout, first render) the engine
    phases don't cover. See `INSTRUCTIONS/scripts/app-bench.sh`.
  - `NEODISK_HEADLESS=1` — run the real app entirely off-screen for felt-time
    benchmarking: accessory activation (no Dock icon, never activates), the
    window moved offscreen and kept transparent, and the in-memory CloudScan
    token store — the same offscreen machinery as `NEODISK_UI_SNAPSHOT` but
    with no capture. A bench run that could draw on screen is a bug; this is
    the switch that prevents it. Compose with `NEODISK_AUTOSCAN` +
    `NEODISK_SCAN_TIMING=1` + `NEODISK_BENCH_AUTOQUIT=1`.
  - `NEODISK_BENCH_AUTOQUIT=1` — `NSApp.terminate` cleanly once the final
    felt-time mark has flushed (the scanned/rescanned/restored tree is on the
    map), so a harness measures a real launch→quit lifecycle.
  - `NEODISK_BENCH_RESCANS=<n>` / `NEODISK_BENCH_RESCAN_INTERVAL=<seconds>` —
    after the `NEODISK_AUTOSCAN` scan displays, wait the interval (default 60,
    so real fs-event churn accumulates) then trigger an in-app `rescan()` and
    repeat `n` times, quitting after the last. Measures felt rescan cost with
    the baseline in memory (no relaunch, no snapshot decode) — the honest
    "hit Rescan a minute later" path. Compose with `NEODISK_INCREMENTAL=0` for
    the full-retraverse head-to-head. FeltTiming emits one `app.*` episode per
    rescan (`mode=rescan`).
  - `NEODISK_SNAPSHOT_DIR=<dir>` — override the on-disk snapshot-cache
    directory, isolating a bench run from the developer's real cache (and
    letting a rescan bench seed a clean baseline it controls).
  - `Neodisk --render-png <scan-path> <out.png> [scale fx fy]` — headless
    treemap render for verifying visual changes
    (`NEODISK_RENDER_COLOR_MODE=<age|branch>` picks the color mode,
    `NEODISK_RENDER_PALETTE=<standard|vivid|graphite|retro|neon|colorblind>` the
    palette).
  - `NEODISK_UI_SNAPSHOT=<out.png>` — offscreen window capture with zoom.
  - `NEODISK_ANALYSIS_TAB=<kinds|largest|age|duplicates|changes>` — open that
    statistics tab on launch, so captures can show any tab.
  - `NEODISK_VIZ_MODE=<treemap|sunburst>` — show that center visualization
    on launch without persisting the preference.
  - `NEODISK_TREEMAP_STYLE=<cushion|flat>` — show that treemap style on
    launch without persisting the preference (`NEODISK_RENDER_STYLE=flat`
    is the `--render-png` equivalent).
  - `NEODISK_OUTLINE_POSITION=<leading|bottom>` — dock the file list left of
    or below the treemap on launch without persisting the preference.
  - `NEODISK_UPDATE_STATE=<checking|available|downloading|readyToInstall|upToDate|failed>`
    — force the toolbar update pill into a non-idle state at launch (inert
    closures), so headless snapshots can capture the indicator without a live
    Sparkle check.
  - When `NEODISK_UI_SNAPSHOT` is set the app runs as an accessory (no Dock
    icon, never activates) and its window is moved offscreen and kept
    transparent, so the capture never appears on screen or steals focus; the
    capture is the whole window (titlebar/toolbar included).
  - `NEODISK_UI_SNAPSHOT` and `--render-png` also swap the CloudScan token
    store for an empty in-memory one: cloud account restore reads the
    Keychain at launch, and from a binary signed differently than the one
    that stored the token macOS shows an access prompt — which a headless
    run must never put on screen.
  - Headless runs of the raw executable share the `Neodisk` UserDefaults
    domain with the developer's own `swift run` sessions — captures inherit
    whatever preferences (e.g. the cloud-only toggle) were last persisted
    there. Check `defaults read Neodisk <key>` before concluding a feature
    regressed.
  - The sidebar's material background renders blank in offscreen
    `NEODISK_UI_SNAPSHOT` captures — sidebar content can't be verified
    headlessly; cover it with tests and a human look instead.
  - `NEODISK_RENDER_CLOUD_ONLY=0` — `--render-png` weights cloud-only
    (dataless) files like the app's toolbar toggle by default; set 0 for
    the strict on-disk map.

## Project Structure

```
Sources/
├── Neodisk/         # Thin executable shim → NeodiskApp.main()
├── NeodiskUI/       # The SwiftUI app, one folder per concern:
│   ├── App/         #   app entry, root ContentView, settings, preferences
│   ├── Model/       #   NeodiskViewModel + its sub-models (scan session,
│   │                #   warnings, free space, cloud accounts, diff), ScanCoordinator
│   ├── Treemap/     #   treemap pane, scene, controller, breadcrumb
│   ├── Sunburst/    #   sunburst pane, chart, geometry, legend
│   ├── Outline/     #   file outline, locations sidebar, warnings panel
│   ├── Statistics/  #   kinds/age/largest/duplicates tabs + models
│   ├── Search/      #   search index, fuzzy matcher, outline search
│   ├── System/      #   Finder/Quick Look glue, pinned folders
│   ├── Shared/      #   palettes, formatters
│   └── Dev/         #   headless render + snapshot dev hooks
├── NeodiskKit/      # UI-free scan engine and core data model
│   ├── Models/      #   scan targets, node records, tree store, snapshots
│   └── Services/    #   ScanEngine, snapshot cache, formatters, dedup
├── TreemapKit/      # Pure treemap geometry and cushion rasterizer
├── SunburstCore/    # Pure sunburst layout, ring metrics, hit-testing
├── CloudScanKit/    # Cloud-drive scanning: OAuth stack + providers
└── NeodiskCLI/      # diskscan — reference CLI consumer of the core
Localization/        # <lang>.lproj string catalogs (bundled into the .app)
Packaging/           # Info.plist and app resources
Tests/               # Package-level unit and golden-image tests
```

`NeodiskKit` never imports AppKit or SwiftUI — the target dependency graph
enforces it. Its public API is deliberately narrow.

## Product Constraints

Neodisk makes user-facing promises. Do not casually violate them:

- **Read-only.** The app never modifies or deletes user files; it writes only
  its own preferences and snapshot cache. Move-to-Trash was removed on purpose
  — do not reintroduce it.
- Scans feel fast and responsive: the engine streams partial trees, then a
  final snapshot.
- The treemap and outline list are primary navigation surfaces, not secondary
  embellishments.
- Toolbar buttons stay persistent and disable when unusable, rather than
  appearing and disappearing.
- The scan progress bar is determinate always, monotonically non-decreasing
  within a scan session, and full exactly when the scan is done. Never an
  indeterminate/bouncing linear bar; quiet phases hold their value under a
  caption. A fallback or phase change may never move the bar backward.
  Liveness is signaled by the drifting diagonal-stripe sheen on the fill
  (`StripedProgressBar`) — it drifts while work runs, freezes when stopped,
  and is intentional, not decoration to be cleaned up.

## Localization

The UI follows the macOS system language; there is no in-app picker. String
catalogs live in `Localization/<lang>.lproj/` and must land in `Bundle.main`
(not `Bundle.module`), so they are not a SwiftPM resource — `package-app.sh`
copies them into `Contents/Resources/` and `Info.plist` lists the languages.

- Keys are the English source string verbatim, so most new strings localize
  automatically once added to every `Localizable.strings`.
- A `String`-typed value passed to `Text` is not localized — wrap it with
  `Text(LocalizedStringKey(x))` or build it via `String(format: NSLocalizedString(…), …)`.
- Add each new key to all catalogs; keep keys byte-identical and `%@`/`%lld`
  specifier counts matching (`plutil -lint`). `en.lproj` is the reference.
- `swift run` shows English (no `.lproj` in `Bundle.main`); verify translations
  from the packaged `.app`.

## Working Agreement For Changes

- Keep edits consistent with the existing architecture unless it is the problem.
- Fix data-related bugs in the `NeodiskKit` model/service layer; fix
  coordination, selection, and navigation issues in `NeodiskUI`.
- Add or update tests when changing scanner behavior, path handling, geometry,
  or formatting.
- Avoid new dependencies unless clearly justified; the project is intentionally
  light on external packages.
- Done means `swift build` with zero warnings and `swift test` all green. For
  visual changes, also eyeball a headless render.
- Treemap rendering is performance-sensitive and has sharp edges — see Notes.

## Notes

- Do not route treemap gesture frames through SwiftUI state. Gestures mutate the
  `CALayer` transform directly in `TreemapNSView`, and crisp renders swap in the
  same `CATransaction`; the SwiftUI-state version twitched.
- On macOS 14+, `NSView.clipsToBounds` defaults to false and overrides SwiftUI
  `.clipped()`, so treemap containment sets it explicitly. `.clipped()` never
  clips hit-testing.
- Keep `WorkspaceView`'s SwiftUI identity identical across the
  scanning→displaying phases, or the treemap view is torn down mid-session.
- The scan event stream is bounded (`bufferingNewest`); the `.finished` event
  must never be dropped.
- Mark timing-sensitive test suites `.serialized` and prefer eventual-state
  assertions over sleeps.
- Never rely on `CATextLayer.truncationMode`: on current macOS a string that
  overflows the layer renders as nothing at all (not truncated — blank).
  Treemap labels pre-ellipsize via `TreemapNSView.endTruncated` instead;
  `TreemapLabelLayerTests.overflowingHeaderLabelRendersPixels` guards this.

## If You Need A Starting Point

- Scanner or data bug: `Sources/NeodiskKit/Services/ScanEngine.swift` and the
  matching tests in `Tests/`.
- Tree/index behavior bug: `Sources/NeodiskKit/Models/FileTreeStore.swift`.
- Selection/navigation/UI state bug: `Sources/NeodiskUI/Model/NeodiskViewModel.swift`
  (+ its `NeodiskViewModel+*.swift` extensions) and
  `Sources/NeodiskUI/Model/ScanCoordinator.swift`.
- Scan start/rescan policy, snapshot cache/restore, or persistence bug:
  `Sources/NeodiskUI/Model/ScanSessionModel.swift`.
- Size or display formatting bug: `Sources/NeodiskKit/Services/FileSizeFormatter.swift`.
- Treemap layout or rendering bug: `Sources/TreemapKit/CushionTreemapRenderer.swift`
  and `Sources/NeodiskUI/Treemap/TreemapScene.swift`.

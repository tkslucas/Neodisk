# AGENTS.md

This file tells coding agents how to work effectively in this repository.

## Purpose

Neodisk is a native macOS disk space analyzer built in Swift. It pairs a
Disk Inventory X-style UI (outline list + cushion treemap + file kinds) with
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
- Bump `AppVersion.string` (`Sources/NeodiskUI/AppVersion.swift`) on every
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
  - `NEODISK_AUTOSCAN=<path>` — scan on launch.
  - `NEODISK_AUTOREVEAL=<path>` — after the scan, select that node and
    expand its ancestors in the outline (deep trees in headless snapshots).
  - `Neodisk --render-png <scan-path> <out.png> [scale fx fy]` — headless
    treemap render for verifying visual changes.
  - `NEODISK_UI_SNAPSHOT=<out.png>` — offscreen window capture with zoom.
  - `NEODISK_ANALYSIS_TAB=<kinds|largest|age|duplicates>` — open that
    statistics tab on launch, so captures can show any tab.
  - `NEODISK_VIZ_MODE=<treemap|sunburst>` — show that center visualization
    on launch without persisting the preference.

## Project Structure

```
Sources/
├── Neodisk/         # Thin executable shim → NeodiskApp.main()
├── NeodiskUI/       # The SwiftUI app: state, coordination, treemap views
├── NeodiskKit/      # UI-free scan engine and core data model
│   ├── Models/      #   scan targets, node records, tree store, snapshots
│   └── Services/    #   ScanEngine, snapshot cache, formatters, dedup
├── TreemapKit/      # Pure treemap geometry and cushion rasterizer
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

## If You Need A Starting Point

- Scanner or data bug: `Sources/NeodiskKit/Services/ScanEngine.swift` and the
  matching tests in `Tests/`.
- Tree/index behavior bug: `Sources/NeodiskKit/Models/FileTreeStore.swift`.
- Selection/navigation/UI state bug: `Sources/NeodiskUI/NeodiskViewModel.swift`
  and `Sources/NeodiskUI/ScanCoordinator.swift`.
- Size or display formatting bug: `Sources/NeodiskKit/Services/FileSizeFormatter.swift`.
- Treemap layout or rendering bug: `Sources/TreemapKit/CushionTreemapRenderer.swift`
  and `Sources/NeodiskUI/TreemapScene.swift`.

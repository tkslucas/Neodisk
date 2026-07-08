<h1 align="center">
  <img src="Packaging/icon.png" width="128" alt="Neodisk icon"><br>
  <p>Neodisk</p>
</h1>

<p align="center">
  Read-only MacOS disk space visualizer.
  Treemap on the <code>NeodiskKit</code> scan engine.
  <br>
  <a href="https://github.com/tkslucas/Neodisk/releases/latest/download/Neodisk.dmg">Download</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="Platform: macOS 14+">
  <img src="https://img.shields.io/github/v/release/tkslucas/Neodisk?label=version" alt="Latest version">
  <img src="https://img.shields.io/badge/license-GPLv3-lightgrey" alt="License: GPLv3">
</p>

<p align="center">
  <img src="screenshots/diff-sonoma.jpeg" width="32%" alt="Changes view: files that grew, shrank, appeared, or were deleted since the last scan">
  <img src="screenshots/hero-tahoe.jpeg" width="32%" alt="Cushion treemap of a full volume with the outline list and file kinds">
  <img src="screenshots/kind-sequoia.jpeg" width="32%" alt="Filtering by file kind highlights just those files in the treemap">
</p>

## Download

[**Download Neodisk.dmg**](https://github.com/tkslucas/Neodisk/releases/latest/download/Neodisk.dmg)
and drag **Neodisk** onto the Applications folder.
Versioned builds and a `.zip` fallback are on the
[Releases](https://github.com/tkslucas/Neodisk/releases) page.

Requires macOS 14 (Sonoma) or later.

## About

**Read-only by design.** Neodisk never modifies or deletes your files. 
Instead, Reveal in Finder, Open, and Copy Path are the only file actions.
Delete and clean up safely in Finder instead.

## Features

- Treemap: Pinch to zoom, scroll to pan.
- Outline + file type statistics: size-sorted file tree and per-type totals
- Fast scanning: parallel traversal that backs off as the machine
  heat-soaks, hard-link dedup, live progress, glob exclusions.
- Search: `⌘F` fuzzy search over the entire scan. Quick Look on spacebar.
- Snapshots & changes: completed scans persist and reopen instantly. The Changes (+/-)
  toggle diffs against the previous scan to show what files grew, shrinked, got added, deleted.
- Multilingual: the UI follows the macOS system language: English, Spanish,
  French, German, Italian, Brazilian Portuguese, Japanese, and Simplified Chinese.

## Build & Run

Requires macOS 14+ and a Swift 6 toolchain. No Xcode needed, the Xcode
Command Line Tools are enough.

```bash
swift run -c release Neodisk    # build and launch directly
swift test                      # full test suite (engine + treemap + UI)
```

## Structure

One package, strictly layered targets:

```
Sources/
├── NeodiskKit/   # UI-free scanning core (derived from Radix)
├── NeodiskCLI/   # `diskscan` — the core's reference CLI
├── TreemapKit/   # Pure treemap geometry, viewport, rasterizer
├── NeodiskUI/    # SwiftUI/AppKit views, view model, scan lifecycle
└── Neodisk/      # Thin executable entry point
Localization/     # .lproj string catalogs, one per language
```

## Planned

- Add to Homebrew
- Horizontal scroll in the file outline (undecided). The idea is that
  deep nesting crops names until the sidebar is expanded very wide, but
  the current behavior is fine. This should not interfere with search (same pane)
- Multiplatform: native Windows and Linux versions (a lot of work, will
  take a while)

## Credits

- [Radix](https://github.com/colinvkim/Radix) by Colin Kim (MIT) — the scan
  engine, core data model NeodiskKit is derived from, huge inspiration.
- [Disk Inventory X](http://www.derlien.com/) by Tjark Derlien and
  [GrandPerspective](https://grandperspectiv.sourceforge.net/) by Erwin
  Bonsma — the cushion-treemap disk viewers this UI follows. No code from
  either is used.
- Cushion treemaps: van Wijk & van de Wetering, INFOVIS 1999. Squarified
  treemaps: Bruls, Huizing & van Wijk, 2000.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE), Radix attribution is preserved there.

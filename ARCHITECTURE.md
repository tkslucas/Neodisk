# Architecture

Neodisk is one repository with one Swift core and a native app per
platform. The structure follows [Ghostty](https://github.com/ghostty-org/ghostty):
all the logic that isn't a widget lives in a shared core, and each platform
gets a thin application written against that platform's own UI toolkit.
Ghostty's core is Zig, and its GTK app is Zig talking to GTK's C API. Neodisk's
core is Swift, and its GTK app is Swift talking to GTK's C API.

```
                 ┌──────────────────────────────────────────────┐
                 │                 shared core                  │
                 │                                              │
                 │  NeodiskKit      scan engine, tree model,    │
                 │                  snapshots, duplicates        │
                 │  TreemapKit      squarify, cushion raster     │
                 │  SunburstCore    sunburst layout, hit-test    │
                 │  NeodiskAppModel kinds, palettes, treemap     │
                 │                  scene, search, formatting    │
                 └───────────┬──────────────────────┬───────────┘
                             │                      │
                ┌────────────▼─────────┐  ┌─────────▼────────────┐
                │ macOS: NeodiskUI     │  │ Linux: NeodiskGTK    │
                │ SwiftUI + AppKit     │  │ GTK 4 + libadwaita   │
                └──────────────────────┘  └──────────────────────┘
                                          (Windows: NeodiskWin, below)
```

`diskscan` (NeodiskCLI) is a third consumer of the core, on every platform.

## Why the core stayed Swift

Neodisk already had a large, tuned, heavily tested Swift engine: the scan
engine, tree store, snapshot codec, incremental rescans, and duplicate
finder, with about 14k lines of engine tests. Swift is officially supported on
Linux and Windows, and its C interop is good enough to drive GTK directly,
the same way Zig drives it in Ghostty. Rewriting the core in Rust or Zig
would have meant re-deriving every one of those behaviors, then rewriting
the macOS app's data layer against an FFI boundary. Keeping Swift means
the Mac app uses the core with no boundary at all, and the Linux app
reuses the same code instead of a translation of it.

## What's shared and what isn't

**Shared core** (builds and tests on macOS, Linux and Windows):

| Target | What it owns |
|---|---|
| NeodiskKit | Traversal, tree assembly, hard-link/clone dedup, snapshot cache and codec, change lists, duplicate finder, incremental rescans |
| TreemapKit | Squarified layout, viewport math, cushion and flat rasterizers (RGBA8 buffers) |
| SunburstCore | Sunburst layout, branch-hue colors, hit-testing, zoom geometry |
| NeodiskAppModel | File-kind classification and catalogs, palettes (as sRGB `SIMD3<Float>`), age buckets, the treemap scene (cells, labels, hit-testing), sunburst fill pass, keyboard navigation, fuzzy search, display formatting |

`NeodiskAppModel` declarations use `package` access: every app in this
package can see them, but they aren't public API. Colors in the shared
model are sRGB triples, so each app converts them to its toolkit's color
type (`Color(rgb:)` in SwiftUI, `GdkRGBA` in GTK).

**Per platform:**

| | macOS (NeodiskUI) | Linux (NeodiskGTK) | Windows (NeodiskWin) |
|---|---|---|---|
| Toolkit | SwiftUI + AppKit | GTK 4.14+ and libadwaita 1.5+ | Win32 controls + Direct2D/DirectWrite surfaces (`CNeodiskWin`) |
| Treemap drawing | CALayer with a CGImage raster | GtkSnapshot with a GdkTexture raster | Direct2D over a Direct3D 11 swap chain (`CNeodiskCanvas`) |
| Sunburst drawing | SwiftUI Canvas | cairo raster texture + GskPath overlays | the same canvas |
| Outline | NSOutlineView | GtkColumnView over a lazy GtkTreeListModel | a virtual (owner-data) ListView over the expanded rows |
| Main thread | AppKit run loop | GLib main loop, with the main dispatch queue drained from it | a message loop that also waits on the main dispatch queue's event |
| State → UI | `@Observable` / SwiftUI | `@Observable` / `withObservationTracking` | `@Observable` / `observeChanges` |
| Strings | `Localization/*.lproj` in the bundle | the same catalogs, read from the data directory | the same catalogs (`StringsCatalog`), next to the executable |
| Settings | UserDefaults | JSON in `$XDG_CONFIG_HOME/neodisk` | JSON in `%APPDATA%\Neodisk` |
| File actions | NSWorkspace, Quick Look | GtkFileLauncher (portal or FileManager1) | ShellExecute, File Explorer |
| Updates | Sparkle | the distribution's package manager | not yet |

## The platform layer inside the core

Platform differences below the UI stay inside the core behind
`#if canImport(...)` / `#if os(...)`, so the apps never see them:

| Concern | Apple platforms | Linux | Windows |
|---|---|---|---|---|
| Directory enumeration | `getattrlistbulk` batches | `readdir` + `fstatat` relative to the open directory (`BulkDirectoryReader+Linux.swift`) | `GetFileInformationByHandleEx` directory-info batches (`FileIdExtdDirectoryInfo`, 64 KiB) from one handle, no per-entry open (`BulkDirectoryReader+Windows.swift`) |
| Per-item metadata | URLResourceValues, lstat fallback | lstat through the same conversion as the reader (`LinuxStat`) | one handle opened without following reparse points, through the same conversion as the reader (`WindowsFileInfo`) |
| Allocated size | `ATTR_FILE_ALLOCSIZE` | `st_blocks × 512` | `AllocationSize`; files the system compressed (WOF) list 0 there and are asked one by one |
| Identity, hard links | device + inode, link count | device + inode, link count | volume serial + file ID; the walk counts every link (directory info has no link count) |
| Links and mount points | never followed (`O_NOFOLLOW`, mount status) | never followed, device changes | name-surrogate reparse points (symlinks, junctions, mounted volumes) are leaves, never followed |
| Incremental rescans | FSEvents journal replay | none (no persistent journal); every rescan is a full scan | none yet (the USN change journal is the candidate) |
| Filesystem type / profile | `statfs.f_fstypename`, `MNT_LOCAL` | `/proc/self/mountinfo` (`LinuxMountTable`) + sysfs rotational/removable flags | `GetVolumeInformationW`, `GetDriveTypeW`, the disk's seek penalty (`WindowsVolume`) |
| Volume capacity | important-usage capacity (purgeable counts as free) | `statvfs`, df's used/available split (root reserve excluded) | `GetDiskFreeSpaceExW`, File Explorer's used/free |
| Snapshot compression | LZFSE (Compression framework) | zstd (libzstd) | XPRESS with Huffman (Compression API), in 1 MB chunks |
| SHA-256 | CryptoKit | swift-crypto | swift-crypto |
| Packages, clones, dataless files, firmlinks | APFS/Finder semantics | not applicable | cloud-only files (recall-on-access) count as dataless |
| Name tie-break in sort order | `localizedStandardCompare` | byte-level natural order (ICU is too slow for the hot path) | as Linux |
| File type descriptions | Launch Services (UTType) | GIO / shared-mime-info, installed by the app | the app's job |

## The GTK app

`Sources/NeodiskGTK` is plain Swift over GTK's C headers (`Sources/CGtk`
is the system-library module). There's no binding generator and no
cross-platform UI layer. A small support layer keeps the calls readable:

- **Pointers.** `ptr()` converts a stored `GPtr` to whatever the C function
  expects (typed or opaque pointer), picked by type inference.
- **Signals.** Each signal shape gets one `@convention(c)` trampoline that
  recovers the Swift closure from its user-data box. GLib owns the box and
  frees it with the handler. `notify::` signals take an extra `GParamSpec`
  argument, so always use `connectNotify` for them.
- **Main loop.** `MainLoopBridge` adds the main dispatch queue's eventfd to
  GLib's loop and drains it there. That's what lets `@MainActor` code,
  `Task`s, and `DispatchQueue.main` run on the GTK thread.
- **Observation.** `track { … }` re-runs a closure whenever the
  `@Observable` state it read changes. That's how models drive widgets,
  just as SwiftUI views do on the Mac.
- **Canvas.** `NeodiskCanvas` is a real GtkWidget subclass registered from
  Swift. Its snapshot vfunc draws through GtkSnapshot, so the treemap and
  sunburst stay on GTK's GPU renderer.

## Windows

The core follows the Linux port: `#if os(Windows)` branches and `+Windows.swift` files next to the Linux ones,
behind the same internal interfaces, using the toolchain's `WinSDK` and `ucrt` modules (see the table above).
Paths are `URL.path` spellings (`C:/Users/x`); Win32 calls get them with backslashes, and with the `\\?\` prefix
past `MAX_PATH` (`WindowsPath`). Trash checks compare paths case-insensitively and treat every drive as a child of
one root. Moving to the Recycle Bin is not wired up yet: `TrashMover.systemTrash` throws.

The app (`NeodiskWin`) is Swift over Win32 with Direct2D and DirectWrite for drawing, over the same
`NeodiskAppModel` the other two apps use (`ScanWorkspace` holds the location, its scan, selection and drill
state). WinUI 3 would need swift-winrt projections generated or vendored and the Windows App Runtime on every
machine, while the surfaces that matter (treemap, sunburst) are Direct2D either way.

- **Real controls where they bring keyboard and Narrator support:** the file list is an owner-data ListView
  (only visible rows exist), the search field an EDIT. They sit on the content layer, which is opaque.
- **Custom surfaces with UI Automation providers:** the navigation pane, command bar, header and status bar are
  child windows drawn by Direct2D, each answering `WM_GETOBJECT` with a provider built from the same element
  list it hit-tests (`SurfaceView`). The COM-heavy parts (DirectWrite, UI Automation, uxtheme, WIC) live in
  `CNeodiskWin`, a C++ target behind a C API, because the toolchain's `WinSDK` module doesn't cover them.
- **Windows 11 look:** Mica (`DWMWA_SYSTEMBACKDROP_TYPE`) behind the pane and the command bar, which are an
  extended frame drawn with real alpha; immersive dark mode and the accent from the system, re-read on
  `WM_SETTINGCHANGE`; per-monitor DPI v2, long paths and common controls v6 from the embedded manifest.
- **Main thread:** the message loop waits on window messages and the main dispatch queue's event together, so
  `@MainActor` work runs between messages.

`Package.swift` declares it in an `#if os(Windows)` block like the Linux one.

## Where logic goes

- A data or scanning bug is a NeodiskKit fix, and it applies on every
  platform.
- UI-free logic that more than one app needs goes in NeodiskAppModel. That
  includes classification, color rules, scene building, search, and
  formatting.
- A platform difference below the UI goes in the core, behind
  `#if`, with the same internal interface on every side.
- Widgets, gestures, windows, and platform services belong to the app
  target for that platform.

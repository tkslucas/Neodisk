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
                 │  CloudScanKit    cloud-drive scanning         │
                 │  NeodiskAppModel kinds, palettes, treemap     │
                 │                  scene, search, formatting    │
                 └───────────┬──────────────────────┬───────────┘
                             │                      │
                ┌────────────▼─────────┐  ┌─────────▼────────────┐
                │ macOS: NeodiskUI     │  │ Linux: NeodiskGTK    │
                │ SwiftUI + AppKit     │  │ GTK 4 + libadwaita   │
                └──────────────────────┘  └──────────────────────┘
                                          (Windows: planned, below)
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

**Shared core** (builds and tests on macOS and Linux):

| Target | What it owns |
|---|---|
| NeodiskKit | Traversal, tree assembly, hard-link/clone dedup, snapshot cache and codec, change lists, duplicate finder, incremental rescans |
| TreemapKit | Squarified layout, viewport math, cushion and flat rasterizers (RGBA8 buffers) |
| SunburstCore | Sunburst layout, branch-hue colors, hit-testing, zoom geometry |
| CloudScanKit | OAuth (PKCE, loopback), Google Drive / Dropbox / OneDrive providers |
| NeodiskAppModel | File-kind classification and catalogs, palettes (as sRGB `SIMD3<Float>`), age buckets, the treemap scene (cells, labels, hit-testing), sunburst fill pass, keyboard navigation, fuzzy search, display formatting |

`NeodiskAppModel` declarations use `package` access: every app in this
package can see them, but they aren't public API. Colors in the shared
model are sRGB triples, so each app converts them to its toolkit's color
type (`Color(rgb:)` in SwiftUI, `GdkRGBA` in GTK).

**Per platform:**

| | macOS (NeodiskUI) | Linux (NeodiskGTK) |
|---|---|---|
| Toolkit | SwiftUI + AppKit | GTK 4.14+ and libadwaita 1.5+ |
| Treemap drawing | CALayer with a CGImage raster | GtkSnapshot with a GdkTexture raster |
| Sunburst drawing | SwiftUI Canvas | cairo raster texture + GskPath overlays |
| Outline | NSOutlineView | GtkColumnView over a lazy GtkTreeListModel |
| Main thread | AppKit run loop | GLib main loop, with the main dispatch queue drained from it |
| State → UI | `@Observable` / SwiftUI | `@Observable` / `withObservationTracking` |
| Strings | `Localization/*.lproj` in the bundle | the same catalogs, read from the data directory |
| Settings | UserDefaults | JSON in `$XDG_CONFIG_HOME/neodisk` |
| File actions | NSWorkspace, Quick Look | GtkFileLauncher (portal or FileManager1) |
| Updates | Sparkle | the distribution's package manager |

## The platform layer inside the core

Platform differences below the UI stay inside the core behind
`#if canImport(...)` / `#if os(...)`, so the apps never see them:

| Concern | Apple platforms | Linux |
|---|---|---|
| Directory enumeration | `getattrlistbulk` batches | `readdir` + `fstatat` relative to the open directory (`BulkDirectoryReader+Linux.swift`) |
| Per-item metadata | URLResourceValues, lstat fallback | lstat through the same conversion as the reader (`LinuxStat`) |
| Allocated size | `ATTR_FILE_ALLOCSIZE` | `st_blocks × 512` |
| Incremental rescans | FSEvents journal replay | none (no persistent journal); every rescan is a full scan |
| Filesystem type / profile | `statfs.f_fstypename`, `MNT_LOCAL` | `/proc/self/mountinfo` (`LinuxMountTable`) + sysfs rotational/removable flags |
| Volume capacity | important-usage capacity (purgeable counts as free) | `statvfs`, df's used/available split (root reserve excluded) |
| Snapshot compression | LZFSE (Compression framework) | zstd (libzstd) |
| SHA-256 | CryptoKit | swift-crypto |
| Packages, clones, dataless files, firmlinks | APFS/Finder semantics | not applicable |
| Name tie-break in sort order | `localizedStandardCompare` | byte-level natural order (ICU is too slow for the hot path) |
| File type descriptions | Launch Services (UTType) | GIO / shared-mime-info, installed by the app |
| Token storage | Keychain | in-memory for now (libsecret is a follow-up) |

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

## Adding Windows

The plan follows the Linux port:

1. **Core platform layer** (`#if os(Windows)` next to the Linux branches):
   - `FindFirstFileExW` with `FIND_FIRST_EX_LARGE_FETCH` / `FindExInfoBasic`,
     or `NtQueryDirectoryFile` batches, for enumeration.
   - `FILE_STANDARD_INFO.AllocationSize` or `GetCompressedFileSizeW` for
     allocated size.
   - The volume serial number plus the 128-bit file ID for identity.
   - `GetDiskFreeSpaceExW` for capacity.
   - The NTFS **USN change journal** for incremental rescans. It's a real
     persistent journal, so Windows can have FSEvents-style incremental
     rescans where Linux can't.
   - The Compression API (XPRESS) or vendored zstd for snapshots.
   - swift-crypto for hashing and Credential Manager for tokens.
2. **Shell:** a `NeodiskWinUI` target using WinUI 3 through
   [swift-winrt](https://github.com/thebrowsercompany/swift-winrt) (the
   route The Browser Company took for Arc on Windows), with the treemap
   raster drawn through Direct2D. It sits over the same `NeodiskAppModel`
   the other two apps use.
3. `Package.swift` gains an `#elseif os(Windows)` block like the Linux one.

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

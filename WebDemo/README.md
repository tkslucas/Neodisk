# WebDemo

The app's own treemap and sunburst cores, compiled to WebAssembly for the
interactive Neodisk demo on lucastakayasu.com (source:
`tkslucas/personal-website`, `src/neodisk/`).

- `Sources/TreemapKit`, `Sources/SunburstCore` — symlinks to the real app
  targets; the demo runs the same squarified layout and cushion/flat
  rasterizers as the shipping app.
- `Sources/NeodiskWebEngine` — thin C-ABI glue: the scan tree arrives as
  shared linear-memory buffers (`Tree.swift`), `Scene.swift` ports
  `TreemapScene.build` (culling, aggregates, flat nesting, free/hidden
  space, cloud-only hatching), `WebTree.swift` conforms the tree to
  SunburstCore's protocols, and `Exports.swift` holds the exported entry
  points the website's `engine/engine.js` calls.

## Build

```sh
./build.sh
```

Embedded Swift, wasm32 — needs the swift.org 6.4 toolchain via swiftly and
the `swift-6.4.0-RELEASE_wasm` Swift SDK bundle (it provides the embedded
variant); `wasm-opt` from binaryen is used when installed. Output (~180 KB)
is copied to the website's `public/neodisk/neodisk-engine.wasm`
(override with `NEODISK_WEB_OUT`). The build is reproducible: rebuilding
from the same sources yields a byte-identical module.

This package is not part of the app build; `swift build` at the repo root
ignores it.

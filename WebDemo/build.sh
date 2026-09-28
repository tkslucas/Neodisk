#!/bin/zsh
# Builds the Neodisk web engine (TreemapKit + SunburstCore + NeodiskWebEngine
# glue) as an Embedded Swift wasm32 module, optimizes it, and copies it into
# the personal website's public/neodisk/ folder.
#
# Needs the swift.org 6.4 toolchain via swiftly (~/.swiftly/bin/swift) with
# the swift-6.4.0-RELEASE_wasm-embedded Swift SDK, and (optionally) binaryen's
# wasm-opt (brew install binaryen).
#
#   ./build.sh                 build + copy to the default website checkout
#   NEODISK_WEB_OUT=... ./build.sh   copy somewhere else

set -euo pipefail
cd "$(dirname "$0")"

SWIFT="${SWIFT:-$HOME/.swiftly/bin/swift}"
SDK="${NEODISK_WASM_SDK:-swift-6.4.0-RELEASE_wasm-embedded}"
OUT="${NEODISK_WEB_OUT:-$HOME/Documents/personal/personal-website/public/neodisk/neodisk-engine.wasm}"

# String hashing (Set<String> in SunburstLayout) needs the Unicode
# normalization tables, which Embedded Swift keeps in a separate archive.
SDK_ROOT="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.4.0-RELEASE_wasm.artifactbundle/swift-6.4.0-RELEASE_wasm/wasm32-unknown-wasip1/swift.xctoolchain"
UNICODE_TABLES="$SDK_ROOT/usr/lib/swift/embedded/wasm32-unknown-wasip1/libswiftUnicodeDataTables.a"
if [[ ! -f "$UNICODE_TABLES" ]]; then
  UNICODE_TABLES="$(find "$HOME/Library/org.swift.swiftpm/swift-sdks" -path '*embedded/wasm32-unknown-wasip1/libswiftUnicodeDataTables.a' | head -1)"
fi

WASM=".build/wasm32-unknown-wasip1/release/NeodiskWebEngine.wasm"
/bin/rm -f "$WASM" # never ship a stale module if the build fails

# Swift 6.4's default (swift-build) backend chokes on this machine's
# duplicate toolchain registration; the native build system is fine.
# -msimd128: the cushion rasterizer's SIMD8<Double> pixel loop lowers to
# wasm SIMD (f64x2) instead of scalar code.
"$SWIFT" build --build-system native --swift-sdk "$SDK" -c release \
  -Xswiftc -Xcc -Xswiftc -msimd128 \
  -Xlinker "$UNICODE_TABLES" 2>&1 | grep -v "has been deprecated" || true

[[ -f "$WASM" ]] || { echo "build failed: $WASM missing" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
WASM_OPT="$(command -v wasm-opt || echo /opt/homebrew/bin/wasm-opt)"
if [[ -x "$WASM_OPT" ]]; then
  # -O3 (speed over the last few KB): the raster loops are the hot path.
  "$WASM_OPT" -O3 --enable-bulk-memory --enable-simd --enable-nontrapping-float-to-int \
    --enable-sign-ext --enable-mutable-globals --enable-bulk-memory-opt --strip-debug --strip-producers \
    "$WASM" -o "$OUT"
else
  cp "$WASM" "$OUT"
fi

printf 'neodisk-engine.wasm: %s bytes (raw %s) -> %s\n' \
  "$(stat -f %z "$OUT")" "$(stat -f %z "$WASM")" "$OUT"

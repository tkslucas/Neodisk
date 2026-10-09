#!/bin/sh
# Builds the Linux app in release mode and installs it under a prefix.
#
#   Packaging/linux/install.sh              # into ~/.local (no root needed)
#   sudo Packaging/linux/install.sh /usr/local
#   Packaging/linux/install.sh --nightly    # Neodisk Nightly, beside the stable app
#   DESTDIR=stage Packaging/linux/install.sh /usr/local   # stage for a tarball
#
# The Swift runtime is linked statically, so the installed binary needs only
# GTK 4 and libadwaita at run time, not a Swift toolchain.
set -eu

APP_ID="com.lucastakayasu.Neodisk"
NAME="Neodisk"
SLUG="neodisk"
ICONS="app-icon"
ICON512="Packaging/icon.png"
BUILD_FLAGS=""
if [ "${1:-}" = "--nightly" ]; then
    shift
    APP_ID="$APP_ID.Nightly"
    NAME="Neodisk Nightly"
    SLUG="neodisk-nightly"
    ICONS="app-icon-nightly"
    ICON512="Packaging/linux/app-icon-nightly/512.png"
    BUILD_FLAGS="-Xswiftc -DNEODISK_NIGHTLY --scratch-path .build/nightly"
fi
PREFIX="${1:-$HOME/.local}"
DEST="${DESTDIR:-}$PREFIX"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

cd "$ROOT"
# The native build system links Foundation's static dependencies (ICU,
# CoreFoundation, Synchronization) that the default SwiftBuild backend
# leaves out of --static-swift-stdlib links. Still true in Swift 6.4, where
# native is deprecated and prints a warning; passing the libraries by hand
# only moves the undefined references into other Foundation archives. Drop
# the flag once a SwiftBuild static link succeeds.
BUILD="swift build --build-system native -c release $BUILD_FLAGS"
$BUILD --product neodisk --static-swift-stdlib
BIN_DIR="$($BUILD --show-bin-path)"

install -Dm755 "$BIN_DIR/neodisk" "$DEST/bin/$SLUG"
strip "$DEST/bin/$SLUG" 2>/dev/null || true

# Translations (shared with the macOS app) and the app's own icons.
mkdir -p "$DEST/share/$SLUG"
rm -rf "$DEST/share/$SLUG/Localization" "$DEST/share/$SLUG/icons"
cp -R Localization "$DEST/share/$SLUG/Localization"
cp -R Packaging/linux/icons "$DEST/share/$SLUG/icons"

# The app icon at every size menus and panels ask for, so none of them
# has to downscale the 512 px original.
install -Dm644 "$ICON512" "$DEST/share/icons/hicolor/512x512/apps/$APP_ID.png"
for size in 16 24 32 48 64 128 256; do
    install -Dm644 "Packaging/linux/$ICONS/$size.png" \
        "$DEST/share/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
done
# The nightly's desktop entry and metainfo are the stable ones renamed.
install -d "$DEST/share/metainfo" "$DEST/share/applications"
sed -e "s|com\.lucastakayasu\.Neodisk|$APP_ID|g" -e "s|<name>Neodisk</name>|<name>$NAME</name>|" \
    -e "s|<binary>neodisk</binary>|<binary>$SLUG</binary>|" \
    Packaging/linux/com.lucastakayasu.Neodisk.metainfo.xml > "$DEST/share/metainfo/$APP_ID.metainfo.xml"
sed -e "s|^Exec=neodisk|Exec=$PREFIX/bin/$SLUG|" -e "s|^Name=Neodisk\$|Name=$NAME|" -e "s|^Icon=.*|Icon=$APP_ID|" \
    Packaging/linux/com.lucastakayasu.Neodisk.desktop > "$DEST/share/applications/$APP_ID.desktop"

if [ -z "${DESTDIR:-}" ]; then
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$PREFIX/share/applications" || true
    command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" || true
fi

echo "Installed $NAME to $DEST (run: $PREFIX/bin/$SLUG)"

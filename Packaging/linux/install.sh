#!/bin/sh
# Builds the Linux app in release mode and installs it under a prefix.
#
#   Packaging/linux/install.sh              # into ~/.local (no root needed)
#   sudo Packaging/linux/install.sh /usr/local
#
# The Swift runtime is linked statically, so the installed binary needs only
# GTK 4 and libadwaita at run time, not a Swift toolchain.
set -eu

PREFIX="${1:-$HOME/.local}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_ID="com.lucastakayasu.Neodisk"

cd "$ROOT"
# The native build system links Foundation's static dependencies (ICU,
# CoreFoundation, Synchronization) that the default SwiftBuild backend
# currently leaves out of --static-swift-stdlib links.
BUILD="swift build --build-system native -c release"
$BUILD --product neodisk --static-swift-stdlib
BIN_DIR="$($BUILD --show-bin-path)"

install -Dm755 "$BIN_DIR/neodisk" "$PREFIX/bin/neodisk"
strip "$PREFIX/bin/neodisk" 2>/dev/null || true

# Translations (shared with the macOS app) and the app's own icons.
mkdir -p "$PREFIX/share/neodisk"
rm -rf "$PREFIX/share/neodisk/Localization" "$PREFIX/share/neodisk/icons"
cp -R Localization "$PREFIX/share/neodisk/Localization"
cp -R Packaging/linux/icons "$PREFIX/share/neodisk/icons"

install -Dm644 Packaging/icon.png "$PREFIX/share/icons/hicolor/512x512/apps/$APP_ID.png"
install -Dm644 "Packaging/linux/$APP_ID.metainfo.xml" "$PREFIX/share/metainfo/$APP_ID.metainfo.xml"
install -d "$PREFIX/share/applications"
sed "s|^Exec=neodisk|Exec=$PREFIX/bin/neodisk|" "Packaging/linux/$APP_ID.desktop" \
    > "$PREFIX/share/applications/$APP_ID.desktop"

command -v update-desktop-database >/dev/null && update-desktop-database -q "$PREFIX/share/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" || true

echo "Installed Neodisk to $PREFIX (run: $PREFIX/bin/neodisk)"

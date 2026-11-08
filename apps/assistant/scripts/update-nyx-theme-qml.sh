#!/usr/bin/env bash
# Refresh the HUD's copy of the Nyx.Theme QML module (quickshell/Nyx/Theme) from a
# nyx-design checkout. The HUD carries its own copy so it runs the same on Omarchy,
# where no system QML module is installed, and on NyxOS. Run it when nyx-design's
# module changes (FROM records the commit it was taken from).
#   scripts/update-nyx-theme-qml.sh [NYX_DESIGN_CHECKOUT]
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
design=${1:-$here/../../../nyx-design}
src=$design/qml/Nyx/Theme
[[ -f $src/qmldir ]] || { echo "no Nyx.Theme module in $design" >&2; exit 1; }
dest=$here/quickshell/Nyx/Theme
rm -rf "$dest"
mkdir -p "$dest"
cp "$src"/qmldir "$src"/*.qml "$src"/*.js "$dest/"
git -C "$design" rev-parse --short HEAD > "$dest/FROM"
echo "Nyx.Theme from nyx-design $(cat "$dest/FROM")"

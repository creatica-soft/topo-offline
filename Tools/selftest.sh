#!/bin/zsh
# Builds the app's core code for macOS and runs an end-to-end check against the real tile servers:
# downloads ~60 tiles (NSW + QLD + overview), reads them back offline, tests resume, over-zoom and delete.
set -euo pipefail
ROOT=${0:A:h:h}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/data"
cp "$ROOT"/TopoOffline/{Model,Storage,Download}/*.swift "$ROOT"/TopoOffline/Map/{TileImage,TopoTileOverlay}.swift "$ROOT"/TopoOffline/App/Secrets.swift "$WORK/src/"
cp "$ROOT/Tools/SelfTest.swift" "$WORK/src/main.swift"
swiftc -swift-version 5 -target arm64-apple-macosx15.0 -O "$WORK"/src/*.swift -o "$WORK/selftest"
# The LINZ key (if set) comes from your private Config/Secrets.xcconfig, as for the app.
export LINZ_API_KEY=$(sed -n 's/^LINZ_API_KEY *= *//p' "$ROOT/Config/Secrets.xcconfig" 2>/dev/null | tail -1)
"$WORK/selftest" "$WORK/data" "$ROOT/TopoOffline/Resources/osm-campsites.json"

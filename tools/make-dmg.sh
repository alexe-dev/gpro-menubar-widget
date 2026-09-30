#!/bin/bash
# Build the app and wrap it in a DMG with the usual drag-to-Applications layout.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh

VERSION="$(defaults read "$(pwd)/GPRO.app/Contents/Info" CFBundleVersion 2>/dev/null || echo 1.0)"
STAGE="$(mktemp -d)"
DMG="GPRO-$VERSION.dmg"

cp -R GPRO.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp positions.json "$STAGE/positions.json" 2>/dev/null || true

rm -f "$DMG"
hdiutil create -volname "GPRO" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "$DMG  ($(du -h "$DMG" | cut -f1))"

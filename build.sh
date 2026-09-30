#!/bin/bash
# Build and sign the bundle. macOS needs at least an ad-hoc signature for the menu bar item to appear.
set -euo pipefail
cd "$(dirname "$0")"
APP="${APP_NAME:-GPRO}.app"
mkdir -p "$APP/Contents/MacOS"
# The icon is generated, not checked in as a binary blob.
if [ ! -f GPRO.icns ]; then
  swift tools/make-icon.swift && iconutil -c icns icon.iconset -o GPRO.icns
fi
mkdir -p "$APP/Contents/Resources"
cp GPRO.icns "$APP/Contents/Resources/"

swiftc -O main.swift dashboard.swift settings.swift -o "$APP/Contents/MacOS/${APP%.app}"
codesign --force --sign - "$APP"
echo "Built: $APP"

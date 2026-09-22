#!/bin/bash
# Build and sign the bundle. macOS needs at least an ad-hoc signature for the menu bar item to appear.
set -euo pipefail
cd "$(dirname "$0")"
APP="${APP_NAME:-GPRO}.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/${APP%.app}"
codesign --force --sign - "$APP"
echo "Built: $APP"

#!/bin/bash
# Сборка и подпись бандла. macOS требует подпись даже ad-hoc, иначе иконка не появится в меню-баре.
set -euo pipefail
cd "$(dirname "$0")"
APP="${APP_NAME:-GPRO}.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/${APP%.app}"
codesign --force --sign - "$APP"
echo "Собрано: $APP"

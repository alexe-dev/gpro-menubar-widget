#!/bin/bash
# Ставит launch agent, чтобы виджет поднимался при входе в систему.
set -euo pipefail
cd "$(dirname "$0")"
DIR="$(pwd)"
PLIST="$HOME/Library/LaunchAgents/local.gpro.widget.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.gpro.widget</string>
  <key>ProgramArguments</key>
  <array><string>$DIR/GPRO.app/Contents/MacOS/GPRO</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>/tmp/gpro-widget.err.log</string>
</dict>
</plist>
PLISTEOF
launchctl bootout "gui/$(id -u)/local.gpro.widget" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Автозапуск включён. Отключить: launchctl bootout gui/\$(id -u) $PLIST"

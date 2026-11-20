#!/bin/bash
# Build ReplyClock.app into ~/Applications. Pass --login to also start it at login.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/ReplyClock.app"
BIN="$APP/Contents/MacOS/ReplyClock"
LABEL="local.replyclock"

pkill -x ReplyClock 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$BIN" -module-cache-path "${TMPDIR:-/tmp}/replyclock-swift-cache"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Reply Clock</string>
  <key>CFBundleExecutable</key><string>ReplyClock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP" >/dev/null

"$BIN" --selftest

if [[ "${1:-}" == "--login" ]]; then
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "Installed login item: $PLIST"
fi

echo "Built $APP — start it with: open \"$APP\""

#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_MODE="${1:-release}"
case "$BUILD_MODE" in release|debug) ;; *) echo 'Usage: bash Scripts/build.sh [release|debug]' >&2; exit 2 ;; esac
QUICKSWITCH_SIGN_IDENTITY="${QUICKSWITCH_SIGN_IDENTITY:-}"
if [ -z "$QUICKSWITCH_SIGN_IDENTITY" ] && [ -f "$TASK_ROOT/.local/signing-identity" ]; then
    IFS= read -r QUICKSWITCH_SIGN_IDENTITY < "$TASK_ROOT/.local/signing-identity"
fi
QUICKSWITCH_SIGN_IDENTITY="${QUICKSWITCH_SIGN_IDENTITY:--}"
cd "$TASK_ROOT"
swift build -c "$BUILD_MODE" --product QuickSwitch
QUICKSWITCH_BIN="$(swift build -c "$BUILD_MODE" --show-bin-path)/QuickSwitch"
APP_DIR="$TASK_ROOT/dist/QuickSwitch.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$QUICKSWITCH_BIN" "$APP_DIR/Contents/MacOS/QuickSwitch"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.pakwingho.quickswitch</string>
<key>CFBundleName</key><string>QuickSwitch</string>
<key>CFBundleDisplayName</key><string>QuickSwitch</string>
<key>CFBundleExecutable</key><string>QuickSwitch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>QuickSwitch.icns</string>
<key>NSAppleEventsUsageDescription</key><string>QuickSwitch 按你的操作切換外觀、Dock、音樂及清空垃圾桶。</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>QuickSwitch 讀取已配對耳機，並按你的操作連線或斷線。</string>
<key>NSFocusStatusUsageDescription</key><string>QuickSwitch 顯示目前專注模式狀態。</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>local.pakwingho.quickswitch</string><key>CFBundleURLSchemes</key><array><string>quickswitch</string></array></dict></array>
</dict></plist>
PLIST
python3 "$TASK_ROOT/../scripts/localization/package-resources.py" "$(dirname "$QUICKSWITCH_BIN")" "$APP_DIR" QuickSwitch_QuickSwitchCore
xcrun swift "$TASK_ROOT/Scripts/make-icon.swift" "$APP_DIR/Contents/Resources"
codesign --force --sign "$QUICKSWITCH_SIGN_IDENTITY" --identifier local.pakwingho.quickswitch "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Built: $APP_DIR"

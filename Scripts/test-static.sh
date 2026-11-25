#!/bin/zsh
set -euo pipefail

SCRIPT_PATH="$0"
PROJECT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
SOURCE_DIR="$PROJECT_DIR/Sources"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
AGENT_PLIST="$PROJECT_DIR/Resources/io.github.ruodou233.MacWiFiPicker.plist"
APP="$PROJECT_DIR/.build/artifacts/Mac WiFi Picker.app"

zsh -n "$PROJECT_DIR/Scripts/build.sh" "$PROJECT_DIR/Scripts/install.sh" "$PROJECT_DIR/Scripts/test.sh"
plutil -lint "$INFO_PLIST" >/dev/null
plutil -lint "$AGENT_PLIST" >/dev/null
test -f "$PROJECT_DIR/Resources/MacWiFiPicker.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive:SuccessfulExit' "$AGENT_PLIST")" = "false"

# The design rule that matters: one process, one popover, no second window.
if grep -rEn 'NSWindow\(|NSPanel\(|NSAlert\(\)|runModal\(\)|WiFiAgent|mbuseragent' "$SOURCE_DIR" >/dev/null; then
    echo "The app must not create a second window or manage Apple's Wi-Fi agents." >&2
    exit 1
fi
POPOVER_COUNT="$(grep -rE 'NSPopover\(\)' "$SOURCE_DIR" | wc -l | tr -d ' ')"
if [[ "$POPOVER_COUNT" != "1" ]]; then
    echo "The host must construct exactly one NSPopover." >&2
    exit 1
fi

test -x "$APP/Contents/MacOS/WiFiPickerHost"
test -f "$APP/Contents/Resources/MacWiFiPicker.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")" = "MacWiFiPicker.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" \
    = "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
codesign --verify --deep --strict "$APP" >/dev/null

echo "Mac WiFi Picker static checks passed"

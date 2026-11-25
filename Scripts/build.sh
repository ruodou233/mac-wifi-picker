#!/bin/zsh
set -euo pipefail

SCRIPT_PATH="$0"
PROJECT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
RESOURCE_DIR="$PROJECT_DIR/Resources"
ARTIFACT_DIR="$PROJECT_DIR/.build/artifacts"
APP_NAME="Mac WiFi Picker.app"
TARGET_APP="$ARTIFACT_DIR/$APP_NAME"

TEMP_BASE="$(printenv TMPDIR 2>/dev/null || true)"
if [[ -z "$TEMP_BASE" ]]; then TEMP_BASE="/tmp"; fi
TEMP_ROOT="$(mktemp -d "$TEMP_BASE/mac-wifi-picker-build.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

cd "$PROJECT_DIR"
swift build -j 2 -c release --product WiFiPickerHost -Xswiftc -warnings-as-errors
BIN_DIR="$(swift build -c release --show-bin-path)"

TEMP_APP="$TEMP_ROOT/$APP_NAME"
TEMP_CONTENTS="$TEMP_APP/Contents"
TEMP_MACOS="$TEMP_CONTENTS/MacOS"
TEMP_RESOURCES="$TEMP_CONTENTS/Resources"
mkdir -p "$TEMP_MACOS" "$TEMP_RESOURCES"
cp "$BIN_DIR/WiFiPickerHost" "$TEMP_MACOS/WiFiPickerHost"
cp "$RESOURCE_DIR/Info.plist" "$TEMP_CONTENTS/Info.plist"
cp "$RESOURCE_DIR/MacWiFiPicker.icns" "$TEMP_RESOURCES/MacWiFiPicker.icns"

# Drop debug symbols so the binary carries no build-machine paths.
strip -S "$TEMP_MACOS/WiFiPickerHost"

# Local builds use ad-hoc signing; no custom keychain or password is required.
codesign --force --sign - "$TEMP_APP" >/dev/null

plutil -lint "$TEMP_CONTENTS/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$TEMP_APP" >/dev/null

mkdir -p "$ARTIFACT_DIR"
PREVIOUS_APP="$TEMP_ROOT/Mac WiFi Picker.previous.app.disabled"
if [[ -e "$TARGET_APP" ]]; then
    mv "$TARGET_APP" "$PREVIOUS_APP"
fi
if ! mv "$TEMP_APP" "$TARGET_APP"; then
    if [[ -e "$PREVIOUS_APP" ]]; then mv "$PREVIOUS_APP" "$TARGET_APP"; fi
    exit 1
fi

echo "Built: $TARGET_APP"

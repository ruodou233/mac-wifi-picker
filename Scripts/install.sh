#!/bin/zsh
# Installs the built app into /Applications, keeps the previous copy as a backup,
# and starts it from a LaunchAgent that relaunches it after a crash.
set -euo pipefail

SCRIPT_PATH="$0"
PROJECT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/.build/artifacts/Mac WiFi Picker.app"
INSTALL_APP="/Applications/Mac WiFi Picker.app"
EXECUTABLE="$INSTALL_APP/Contents/MacOS/WiFiPickerHost"
BACKUP_DIR="$HOME/Library/Application Support/Mac WiFi Picker"
BACKUP_APP="$BACKUP_DIR/Mac WiFi Picker.previous.app.disabled"
AGENT_LABEL="io.github.ruodou233.MacWiFiPicker"
AGENT_TEMPLATE="$PROJECT_DIR/Resources/$AGENT_LABEL.plist"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
USER_ID="$(id -u)"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "No app bundle found. Run Scripts/build.sh first." >&2
    exit 2
fi
codesign --verify --deep --strict "$SOURCE_APP" >/dev/null

# Stop the running copy, whether the LaunchAgent or the login item started it.
launchctl bootout "gui/$USER_ID/$AGENT_LABEL" >/dev/null 2>&1 || true
pkill -f -x "$EXECUTABLE" >/dev/null 2>&1 || true
pkill -f -x "$EXECUTABLE --login-launch" >/dev/null 2>&1 || true

# Keep one previous copy. The suffix is not .app, so Launch Services ignores it.
mkdir -p "$BACKUP_DIR"
if [[ -e "$INSTALL_APP" ]]; then
    rm -rf "$BACKUP_APP"
    mv "$INSTALL_APP" "$BACKUP_APP"
fi
if ! ditto "$SOURCE_APP" "$INSTALL_APP"; then
    rm -rf "$INSTALL_APP"
    if [[ -e "$BACKUP_APP" ]]; then mv "$BACKUP_APP" "$INSTALL_APP"; fi
    echo "Copy failed; the previous app was put back." >&2
    exit 3
fi

# The LaunchAgent is the only startup path: launched with --login-launch, the app
# removes its own login item, so a login never starts two copies.
mkdir -p "$HOME/Library/LaunchAgents"
cp "$AGENT_TEMPLATE" "$AGENT_PLIST"
plutil -lint "$AGENT_PLIST" >/dev/null
# A bootstrap right after a bootout can fail while launchd is still tearing down.
launchctl bootstrap "gui/$USER_ID" "$AGENT_PLIST" 2>/dev/null \
    || { sleep 2; launchctl bootstrap "gui/$USER_ID" "$AGENT_PLIST"; }

sleep 2
if ! pgrep -f -x "$EXECUTABLE --login-launch" >/dev/null 2>&1; then
    echo "The app did not stay running. Check: launchctl print gui/$USER_ID/$AGENT_LABEL" >&2
    exit 4
fi

echo "Installed: $INSTALL_APP"
if [[ -e "$BACKUP_APP" ]]; then echo "Previous copy: $BACKUP_APP"; fi
echo "Startup: LaunchAgent $AGENT_LABEL (relaunches after a crash; Quit from the menu stays quit until next login)"

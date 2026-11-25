#!/bin/zsh
set -euo pipefail

SCRIPT_PATH="$0"
PROJECT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"

cd "$PROJECT_DIR"
swift run -j 4 -Xswiftc -warnings-as-errors WiFiPickerModelTests
swift build -j 4 --product WiFiPickerHost -Xswiftc -warnings-as-errors

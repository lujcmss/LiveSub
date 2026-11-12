#!/bin/zsh
# Build LiveSub.app with SwiftPM and sign it ad-hoc ("Sign to Run Locally"). No Xcode or paid account needed.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
source scripts/sdk.sh
swift build -c "$CONFIG" --product livesub
BIN="$(swift build -c "$CONFIG" --show-bin-path)/livesub"
APP=build/LiveSub.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Keep Spotlight from listing this build copy next to the installed app.
touch build/.metadata_never_index
cp "$BIN" "$APP/Contents/MacOS/livesub"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature with a stable identifier so macOS privacy permissions stick to the bundle ID.
codesign --force --sign - --identifier app.livesub.LiveSub --options runtime \
  --entitlements Resources/LiveSub.entitlements "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $PWD/$APP"

#!/bin/zsh
# Build LiveSub and install it into /Applications (or ~/Applications if that is not writable),
# so it can be opened from Spotlight, Launchpad or Finder like any other app.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
# Quit a running copy first so the new one is the one that opens.
osascript -e 'tell application id "app.livesub.LiveSub" to quit' >/dev/null 2>&1 || true
rm -rf "$DEST/LiveSub.app"
cp -R build/LiveSub.app "$DEST/LiveSub.app"
echo "Installed $DEST/LiveSub.app"

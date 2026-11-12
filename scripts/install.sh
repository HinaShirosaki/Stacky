#!/bin/sh
# Builds Stacky and installs it to /Applications (or ~/Applications if that isn't writable), then opens it.
# Usage: scripts/install.sh [identity]   Run it again to update; your workspaces are kept.
set -e
cd "$(dirname "$0")/.."

major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || { echo "Stacky needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."; exit 1; }
command -v swift >/dev/null 2>&1 || {
  echo "Swift isn't installed. Run:  xcode-select --install"
  echo "then run this script again."
  exit 1
}

scripts/bundle.sh "$@"

DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
rm -rf "$DEST/Stacky.app"
ditto build/Stacky.app "$DEST/Stacky.app"
open "$DEST/Stacky.app"

echo
echo "Installed $DEST/Stacky.app and opened it. Look for the stacked-layers icon in the menu bar."
echo "First run: allow Stacky in System Settings › Privacy & Security › Accessibility."

#!/bin/bash
# install.sh — download the latest CleanSwitcher release and install it
set -euo pipefail

REPO="marklidenberg/CleanSwitcher"
APP="CleanSwitcher"
DEST="/Applications/$APP.app"

echo "Fetching latest $APP release…"

# - Resolve the latest release's zip asset URL

url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o "https://github.com/$REPO/releases/download/[^\"]*\.zip" \
  | head -n1)

[ -n "$url" ] || { echo "No .zip asset found in latest release."; exit 1; }

# - Download and unpack into a temp dir

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp/$APP.zip"
ditto -x -k "$tmp/$APP.zip" "$tmp"

# - Install into /Applications

rm -rf "$DEST"
mv "$tmp/$APP.app" "$DEST"

# - Strip quarantine (belt-and-suspenders; curl usually doesn't set it)

xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "Installed $DEST"
echo "Launch it, then grant Accessibility permission when prompted."
open "$DEST"

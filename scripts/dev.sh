#!/bin/bash

# Hot-ish reload dev loop for CleanSwitcher.
#
# Watches Sources/, and on any change rebuilds, re-signs with a STABLE signing
# identity, and relaunches the app. A stable identity (not ad-hoc) keeps the
# macOS Accessibility grant alive across rebuilds, so you only approve once.
#
# Usage:
#   ./dev.sh            # build once, then watch and reload on save
#   ./dev.sh --once     # build, sign, launch once and exit (no watching)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY_NAME="CleanSwitcher"
APP_NAME="CleanSwitcher"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

# - Pick a stable signing identity (falls back to ad-hoc with a warning)

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -Eo '"Apple Development: [^"]+"' | head -1 | tr -d '"')"
if [ -z "$IDENTITY" ]; then
    echo "⚠️  No Apple Development identity found — falling back to ad-hoc (-)."
    echo "    Accessibility grant will reset on every rebuild."
    IDENTITY="-"
fi

reload() {
    echo "──▶ building…"
    if ! swift build -c debug 2>&1 | grep -vE '^\[|^Building|^Compiling'; then :; fi
    swift build -c debug >/dev/null

    mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
    cp ".build/debug/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/"
    cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/"
    [ -f "$PROJECT_DIR/AppIcon.icns" ] && cp "$PROJECT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
    echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

    codesign --force --deep --sign "$IDENTITY" "$APP_BUNDLE" >/dev/null 2>&1

    pkill -x "$BINARY_NAME" 2>/dev/null || true
    sleep 0.2
    open "$APP_BUNDLE"
    echo "──▶ reloaded ($(date +%H:%M:%S))  identity: $IDENTITY"
}

reload

if [ "${1:-}" = "--once" ]; then
    exit 0
fi

echo "──▶ watching Sources/ … (Ctrl-C to stop)"
STAMP="$PROJECT_DIR/.build/.dev-stamp"
touch "$STAMP"
while true; do
    if [ -n "$(find "$PROJECT_DIR/Sources" -name '*.swift' -newer "$STAMP" 2>/dev/null)" ]; then
        touch "$STAMP"
        reload
    fi
    sleep 0.5
done

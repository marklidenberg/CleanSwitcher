#!/bin/bash
# release.sh — build CleanSwitcher.app, zip it, and publish a GitHub release
#
# Usage:
#   ./scripts/release.sh            # release the version in Info.plist
#   ./scripts/release.sh 1.2.0      # bump Info.plist to 1.2.0, then release

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CleanSwitcher"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
ZIP="$PROJECT_DIR/$APP_NAME.zip"
PLIST="$PROJECT_DIR/Info.plist"

cd "$PROJECT_DIR"

# - Resolve the version (bump Info.plist if one is passed)

if [ "${1:-}" != "" ]; then
    VERSION="$1"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
    echo "Bumped Info.plist to $VERSION"
else
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
fi

TAG="v$VERSION"
echo "Releasing $TAG"

# - Refuse to clobber an existing release

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "ERROR: release $TAG already exists. Bump the version first."
    exit 1
fi

# - Build the release app bundle

"$PROJECT_DIR/scripts/build-app.sh" release

# - Zip it (keepParent so the archive contains $APP_NAME.app)

rm -f "$ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"

# - Publish the release with the zip attached

gh release create "$TAG" "$ZIP" \
    --title "$TAG" \
    --notes "Ad-hoc signed, not notarized. Install: \`curl -fsSL https://raw.githubusercontent.com/marklidenberg/$APP_NAME/main/install.sh | bash\`"

# - Clean up the local zip

rm -f "$ZIP"

echo "Published $TAG"

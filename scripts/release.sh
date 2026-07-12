#!/bin/bash
# release.sh — bump the version, commit & tag it, push, then publish a GitHub release
#
# Usage:
#   ./scripts/release.sh            # bump patch (default), e.g. 1.0.0 -> 1.0.1
#   ./scripts/release.sh minor      # bump minor,           e.g. 1.0.1 -> 1.1.0
#   ./scripts/release.sh major      # bump major,           e.g. 1.1.0 -> 2.0.0

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CleanSwitcher"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
ZIP="$PROJECT_DIR/$APP_NAME.zip"
PLIST="$PROJECT_DIR/Info.plist"

cd "$PROJECT_DIR"

# - Refuse to release from a dirty tree (releases build from the working tree)

if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: working tree is dirty. Commit or stash first."
    exit 1
fi

# - Compute the new version

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
IFS='.' read -r major minor patch <<< "$CURRENT"
major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"

case "${1:-patch}" in
    major) VERSION="$((major + 1)).0.0" ;;
    minor) VERSION="$major.$((minor + 1)).0" ;;
    patch) VERSION="$major.$minor.$((patch + 1))" ;;
    *)     echo "ERROR: unknown bump '$1' (expected major, minor, or patch)"; exit 1 ;;
esac

TAG="v$VERSION"
echo "Releasing $CURRENT -> $TAG"

# - Refuse to clobber an existing release

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "ERROR: release $TAG already exists."
    exit 1
fi

# - Bump Info.plist, commit, and tag

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"

git commit -m "chore(release): $TAG" -- "$PLIST"
git tag -a "$TAG" -m "$TAG"   # annotated, so --follow-tags actually pushes it

# - Push the commit and the tag

git push --follow-tags

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

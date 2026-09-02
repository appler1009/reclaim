#!/bin/bash
# Builds Reclaim.app into ./dist
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="dist/Reclaim.app"
TEAM_ID="${TEAM_ID:-TN2RQ5P647}"
BUNDLE_ID="${BUNDLE_ID:-com.appler.reclaim}"

# The marketing version lives in VERSION, one line, edited by hand for a release.
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.0.0)}"

# The build number is the commit count: monotonic, identical for everyone who
# builds the same commit, and needing no state outside the repository. A build
# from a tree that is not a git checkout, or a shallow clone, falls back to 0 —
# which reads as "unofficial" rather than pretending to be a real build.
if BUILD_COUNT="$(git rev-list --count HEAD 2>/dev/null)"; then
  BUILD="$BUILD_COUNT"
else
  BUILD="0"
fi
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  COMMIT="$COMMIT-dirty"
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/DiskMap"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Reclaim"

# App icon
if [ ! -f dist/Reclaim.icns ]; then
  mkdir -p dist
  swift Scripts/make_icon.swift dist/Reclaim.iconset >/dev/null
  iconutil -c icns dist/Reclaim.iconset -o dist/Reclaim.icns
fi
cp dist/Reclaim.icns "$APP/Contents/Resources/Reclaim.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Reclaim</string>
  <key>CFBundleDisplayName</key><string>Reclaim</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Reclaim</string>
  <key>CFBundleIconFile</key><string>Reclaim</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>ReclaimSourceCommit</key><string>$COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Reclaim measures how much space your Desktop is using.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Reclaim measures how much space your Documents are using.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Reclaim finds stale downloads you can delete.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Reclaim can analyse external volumes.</string>
</dict>
</plist>
PLIST

# Prefer the Developer ID identity (distributable, notarizable); fall back to ad-hoc.
IDENTITY="$(security find-identity -v -p codesigning \
  | sed -n "s/.*\"\(Developer ID Application: .*(${TEAM_ID})\)\".*/\1/p" | head -1)"

if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --timestamp \
    --entitlements Scripts/Reclaim.entitlements \
    --sign "$IDENTITY" "$APP"
  echo "signed with: $IDENTITY"
else
  echo "warning: no Developer ID identity for team $TEAM_ID; signing ad-hoc" >&2
  codesign --force --sign - "$APP"
fi

codesign --verify --strict --verbose=1 "$APP"
echo "built $APP — version $VERSION (build $BUILD, commit $COMMIT)"

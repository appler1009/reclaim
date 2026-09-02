#!/bin/bash
# Notarizes and staples dist/Reclaim.app so it opens on other people's Macs.
#
# One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials reclaim-notary \
#     --apple-id <your-apple-id> --team-id TN2RQ5P647 --password <app-specific-password>
# App-specific passwords come from https://account.apple.com → Sign-In and Security.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-reclaim-notary}"
APP="dist/Reclaim.app"
ZIP="dist/Reclaim.zip"

[ -d "$APP" ] || { echo "build it first: ./Scripts/build_app.sh" >&2; exit 1; }

codesign --verify --strict --verbose=1 "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Re-zip so the distributed archive contains the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "notarized and stapled: $APP (distributable archive: $ZIP)"

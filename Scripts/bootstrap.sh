#!/bin/bash
# One-time setup for a fresh clone.
#
# Everything here is per-clone state that git cannot carry for you: hooks live
# in .git, which is not version controlled, so pointing git at the copies that
# are is the one thing that has to be asked for.
set -euo pipefail
cd "$(dirname "$0")/.."

git config core.hooksPath .githooks
echo "hooks: .githooks (post-merge, post-checkout keep the Xcode project current)"

if command -v xcodegen >/dev/null 2>&1; then
  ./iOS/generate.sh
else
  echo "xcodegen not installed — the iOS app needs it: brew install xcodegen"
fi

cat <<'NOTE'

Ready.
  swift test                 the Mac app's tests
  ./Scripts/build_app.sh     → dist/Reclaim.app
  open iOS/ReclaimCompanion.xcodeproj

For a device build of the companion, put your team in iOS/Local.xcconfig:
  DEVELOPMENT_TEAM = XXXXXXXXXX
NOTE

#!/bin/bash
# Regenerates the Xcode project only when it is out of date.
#
# Called by the git hooks, which fire after every pull and every checkout —
# most of which change nothing the project cares about. Regenerating anyway
# would rewrite the file under an open Xcode and make it reload for nothing.
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="ReclaimCompanion.xcodeproj/project.pbxproj"

# Missing, or older than either file that decides what it contains.
if [ -f "$PROJECT" ] \
  && [ ! project.yml -nt "$PROJECT" ] \
  && [ ! Version.xcconfig -nt "$PROJECT" ]; then
  exit 0
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  # A warning, not a failure: somebody who never opens the iOS app should not
  # have their checkout fail over a tool they have no use for.
  echo "note: iOS/ReclaimCompanion.xcodeproj is out of date and xcodegen is not installed." >&2
  echo "      brew install xcodegen && ./iOS/generate.sh" >&2
  exit 0
fi

./generate.sh

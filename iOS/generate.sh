#!/bin/bash
# Regenerates iOS/ReclaimCompanion.xcodeproj from project.yml.
#
# The project file is not in git — project.yml is the source, and a generated
# pbxproj in version control is a merge conflict waiting to happen. That trade
# costs one command, which is this one, and the hooks in .githooks run it for
# you after a pull or a checkout.
#
# Run it yourself after adding or removing a source file: xcodegen references
# files explicitly, so a file Xcode has never been told about will not build.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. brew install xcodegen" >&2
  exit 1
fi

xcodegen generate --quiet
echo "generated iOS/ReclaimCompanion.xcodeproj ($(cat ../VERSION))"

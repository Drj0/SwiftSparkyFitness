#!/bin/zsh
# Archive, export, upload and push to the PersonalTester TestFlight group.
# Build number is auto-resolved by asc. Usage: ./release.sh "what to test notes"
# ASC_SUBMIT=1 also submits for Beta App Review (what /upload-testflight sets).
set -e
cd "$(dirname "$0")"
# The app target's version, from Xcode — grepping the project file hit the
# test target's MARKETING_VERSION first.
VERSION=$(xcodebuild -project SwiftSparkyFitness.xcodeproj -target SwiftSparkyFitness -showBuildSettings 2>/dev/null | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
[ -n "$VERSION" ] || { echo "Couldn't read MARKETING_VERSION" >&2; exit 1; }
notes=(); [ -n "$1" ] && notes=(--test-notes "$1" --locale en-US)
submit=(); [ -n "$ASC_SUBMIT" ] && submit=(--submit --confirm)
asc publish testflight \
  --app 6817818115 \
  --project SwiftSparkyFitness.xcodeproj \
  --scheme SwiftSparkyFitness \
  --version "$VERSION" \
  --group "PersonalTester" \
  "${notes[@]}" \
  --wait --notify "${submit[@]}"

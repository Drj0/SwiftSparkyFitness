#!/bin/zsh
# Archive, export, upload and push to the PersonalTester TestFlight group.
# Build number is auto-resolved by asc. Usage: ./release.sh "what to test notes"
set -e
cd "$(dirname "$0")"
VERSION=$(grep -m1 MARKETING_VERSION SwiftSparkyFitness.xcodeproj/project.pbxproj | sed 's/.*= \(.*\);/\1/')
asc publish testflight \
  --app 6817818115 \
  --project SwiftSparkyFitness.xcodeproj \
  --scheme SwiftSparkyFitness \
  --version "$VERSION" \
  --group "PersonalTester" \
  --test-notes "${1:-New build}" --locale en-US \
  --wait --notify

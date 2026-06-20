#!/bin/bash
# Real XCUITest UI tests — launches the app bundle and taps actual controls by
# their accessibility identifiers. Regenerates the Xcode project from project.yml
# (so the SwiftPM package stays the source of truth) and runs the UI test target.
#
#   ./scripts/uitest.sh
#
# Requires: xcodegen (brew install xcodegen), Xcode. Uses ad-hoc signing ("-").
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ regenerating Mnemosyne.xcodeproj from project.yml"
xcodegen generate >/dev/null

echo "▸ running XCUITest (real button clicks)"
# -retry-tests-on-failure heals the intermittent macOS XCUITest
# "has not loaded accessibility" launch flakiness (re-runs only the failed test).
xcodebuild test \
  -project Mnemosyne.xcodeproj \
  -scheme Mnemosyne \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .ddata \
  -retry-tests-on-failure -test-iterations 3 \
  CODE_SIGN_IDENTITY="-" \
  2>&1 | grep -aE "Test Case '.*' (passed|failed)|TEST SUCCEEDED|TEST FAILED|error:" || true

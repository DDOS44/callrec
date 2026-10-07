#!/bin/bash
# Real test run for a Command Line Tools-only Mac (no Xcode, no XCTest).
#
# Plain `swift test` is a false green here: it builds the test bundle, then exits
# 0 without running a single test. This builds the bundle and runs it through the
# swift-testing ABI entry point (scripts/run-tests.swift). Exits non-zero if any
# test fails or if zero tests ran.
#
# Usage: scripts/test.sh [name-substring]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests
RUNNER=.build/testrunner/run-tests
mkdir -p .build/testrunner
if [ ! -x "$RUNNER" ] || [ scripts/run-tests.swift -nt "$RUNNER" ]; then
  swiftc -O scripts/run-tests.swift -o "$RUNNER"
fi
BUNDLE=$(echo "$PWD"/.build/debug/*PackageTests.xctest/Contents/MacOS/*PackageTests)
[ -f "$BUNDLE" ] || { echo "test bundle not found" >&2; exit 2; }
exec "$RUNNER" "$BUNDLE" "$@"

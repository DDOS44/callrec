#!/usr/bin/env bash
# Runs the whole test suite under AddressSanitizer: catches use-after-free, buffer
# overflows and other memory bugs that pass normal tests. Fails on any ASan report or
# any test failure. Uses a separate build dir so it never disturbs the normal build.
#
# ThreadSanitizer is not used here: on this toolchain it crashes inside its own runtime
# (DialRules.randomGap, garbage shadow address) after ~230 clean tests; AddressSanitizer
# runs the full suite. Re-check TSan when the toolchain updates:
#   swift build --build-tests --sanitize=thread --scratch-path .build/tsan
set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH=.build/asan
swift build --build-tests --sanitize=address --scratch-path "$SCRATCH"

RUNNER="$SCRATCH/testrunner/run-tests-asan"
mkdir -p "$(dirname "$RUNNER")"
if [ ! -x "$RUNNER" ] || [ scripts/run-tests.swift -nt "$RUNNER" ]; then
  swiftc -sanitize=address scripts/run-tests.swift -o "$RUNNER"
fi

BUNDLE=$(echo "$PWD/$SCRATCH"/debug/*PackageTests.xctest/Contents/MacOS/*PackageTests)
[ -f "$BUNDLE" ] || { echo "sanitized test bundle not found" >&2; exit 2; }

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
set +e
ASAN_OPTIONS="detect_leaks=0:halt_on_error=1" "$RUNNER" "$BUNDLE" "$@" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if grep -q "ERROR: AddressSanitizer" "$LOG"; then
  echo "AddressSanitizer found a memory error (see above)." >&2
  exit 1
fi
if [ "$status" -ne 0 ]; then
  echo "Tests failed under AddressSanitizer (exit $status)." >&2
  exit "$status"
fi
echo "AddressSanitizer: clean."

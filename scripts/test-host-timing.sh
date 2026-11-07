#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="${TMPDIR:-$HOME/.hermes/cache/scratch}"
WORK="$(mktemp -d "$TEMP_ROOT/dualscreen-timing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc "$ROOT/host/Sources/DualScreenHost/TimingCoordinator.swift" \
    "$ROOT/host/Tests/TimingTests.swift" -o "$WORK/timing-tests"
"$WORK/timing-tests"

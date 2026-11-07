#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="${TMPDIR:-$HOME/.hermes/cache/scratch}"
WORK="$(mktemp -d "$TEMP_ROOT/dualscreen-bitrate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc "$ROOT/host/Sources/DualScreenHost/BitratePolicy.swift" \
    "$ROOT/host/Tests/BitratePolicyTests.swift" -o "$WORK/bitrate-tests"
"$WORK/bitrate-tests"

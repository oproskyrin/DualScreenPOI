#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-$HOME/.cache}/dualscreen-layout-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc "$ROOT/host/Sources/DualScreenHost/DisplayArrangement.swift" \
    "$ROOT/host/Tests/DisplayPlacementTests.swift" -o "$WORK/placement"
"$WORK/placement"

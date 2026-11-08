#!/bin/bash
# Pure-core DualScreenMic input route tests (docs/mic-0x07.md): ring overfill
# drop, silence when mic is not negotiated, absent-HAL drops. No real HAL IO.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="${TMPDIR:-$HOME/.hermes/cache/scratch}"
WORK="$(mktemp -d "$TEMP_ROOT/dualscreen-mic.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc "$ROOT/host/Sources/DualScreenHost/MicInputRoute.swift" \
    "$ROOT/host/Sources/DualScreenHost/HostLog.swift" \
    "$ROOT/host/Tests/MicInputRouteTests.swift" -o "$WORK/mic-tests"
"$WORK/mic-tests"

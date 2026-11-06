#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-$HOME/.cache}/dualscreen-server-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc "$ROOT/host/Sources/DualScreenHost/FrameServer.swift" \
    "$ROOT/host/Sources/DualScreenHost/HostLog.swift" \
    "$ROOT/host/Tests/FrameServerRegression.swift" -o "$WORK/server"
"$WORK/server"
xcrun swiftc "$ROOT/host/Sources/DualScreenHost/HostLog.swift" \
    "$ROOT/host/Tests/HostLogRegression.swift" -o "$WORK/log"
"$WORK/log"

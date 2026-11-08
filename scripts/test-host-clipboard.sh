#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="${TMPDIR:-$HOME/.hermes/cache/scratch}"
WORK="$(mktemp -d "$TEMP_ROOT/dualscreen-clipboard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc "$ROOT/host/Sources/DualScreenHost/ClipboardSync.swift" \
    "$ROOT/host/Sources/DualScreenHost/HostLog.swift" \
    "$ROOT/host/Tests/ClipboardSyncTests.swift" -o "$WORK/clipboard-tests"
"$WORK/clipboard-tests"

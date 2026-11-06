#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="${TMPDIR:-$HOME/.hermes/cache/scratch}"
WORK="$(mktemp -d "$TEMP_ROOT/dualscreen-input.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc "$ROOT/host/Sources/DualScreenHost/InputInjector.swift" "$ROOT/host/Tests/InputInjectorTests.swift" -o "$WORK/input-tests"
"$WORK/input-tests"

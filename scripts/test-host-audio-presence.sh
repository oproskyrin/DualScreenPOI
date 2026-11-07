#!/bin/bash
# No installation, live route writes, audio-service restart, or production notify.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-$HOME/.hermes/cache/scratch}/dualscreen-presence-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"
xcrun swiftc -warnings-as-errors host/Sources/DualScreenHost/AudioDevicePresence.swift \
    host/Tests/AudioDevicePresenceTests.swift -o "$WORK/presence"
"$WORK/presence"
if [[ ${1:-} == --hal ]]; then
    # Actual Swift lifecycle publisher in a separate process, actual HAL ABI,
    # isolated notification name and injected HAL host, never installed devices.
    BUILDER="$ROOT/scripts/build-dualscreen-audio.sh"
    [[ -f "$BUILDER" ]] || BUILDER="$ROOT/build-dualscreen-audio.sh"
    DUALSCREEN_PRESENCE_PUBLISHER="$WORK/presence" bash "$BUILDER" "${@:2}"
fi

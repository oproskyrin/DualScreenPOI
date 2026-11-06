#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-$HOME/.cache}/dualscreen-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"
xcrun clang host/Tests/AudioConverterRegression.m host/Sources/VTEncoderShim/VTEncoderShim.m \
    -Ihost/Sources/VTEncoderShim/include -framework Foundation -framework CoreMedia \
    -framework CoreVideo -framework VideoToolbox -framework AudioToolbox -o "$WORK/converter"
"$WORK/converter"
xcrun swiftc host/Sources/DualScreenHost/TabletAudioRoute.swift host/Tests/TabletAudioPolicyTests.swift -o "$WORK/policy"
"$WORK/policy"
if [[ ${1:-} == --devices ]]; then
    for TEST in AudioRouteRegression NativeAudioVolumeRegression; do
        xcrun swiftc host/Sources/DualScreenHost/TabletAudioRoute.swift "host/Tests/$TEST.swift" -o "$WORK/$TEST"
        "$WORK/$TEST"
    done
fi

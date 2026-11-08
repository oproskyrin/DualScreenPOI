#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-$HOME/.cache}/dualscreen-app-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SOURCE="$ROOT/host/Sources/DualScreenHost"
xcrun swiftc "$SOURCE/AppRuntimePolicy.swift" "$ROOT/host/Tests/AppRuntimeTests.swift" -o "$WORK/policy"
"$WORK/policy"
xcrun swiftc "$SOURCE/HostLog.swift" "$SOURCE/ClipboardSync.swift" "$SOURCE/FrameServer.swift" "$ROOT/host/Tests/ServerLifecycleTests.swift" -o "$WORK/server"
"$WORK/server"
FRAMEWORK_DIR="$ROOT/host/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
if [[ ! -d "$FRAMEWORK_DIR/Sparkle.framework" ]]; then
    printf '%s\n' 'Sparkle artifact missing: run swift build -c release in host first.' >&2
    exit 1
fi
xcrun swiftc -F "$FRAMEWORK_DIR" -framework Sparkle -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" \
    "$SOURCE/AppRuntimePolicy.swift" "$SOURCE/AppUpdater.swift" "$SOURCE/AppLifecycle.swift" "$SOURCE/LaunchAgent.swift" \
    "$ROOT/host/Tests/AppKitLifecycleTests.swift" -o "$WORK/lifecycle"
"$WORK/lifecycle"
# No launchctl mutations, audio-presence posts, display setup or input injection.

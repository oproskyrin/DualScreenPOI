#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH="${BUILD_SCRATCH_ROOT:-$HOME/.hermes/cache/scratch}"
mkdir -p "$SCRATCH"
WORK=$(mktemp -d "$SCRATCH/dualscreen-localization.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SOURCE="$ROOT/host/Sources/DualScreenHost"
mkdir -p "$WORK/Full.bundle" "$WORK/Partial.bundle/ru.lproj"
cp -R "$SOURCE/Resources/" "$WORK/Full.bundle/"
cp -R "$SOURCE/Resources/en.lproj" "$WORK/Partial.bundle/"
printf '"unused" = "не используется";\n' > "$WORK/Partial.bundle/ru.lproj/Localizable.strings"
xcrun swiftc "$SOURCE/Localization.swift" "$ROOT/host/Tests/LocalizationTests.swift" -o "$WORK/localization"
"$WORK/localization" "$WORK/Full.bundle" "$WORK/Partial.bundle"

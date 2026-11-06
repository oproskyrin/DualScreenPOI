#!/bin/bash
# Local GPLv3 HAL driver build. Never installs, removes drivers, or restarts audio.
set -euo pipefail
PIN=574029f0d3175ccf29a826d74be4da3967b1cb92
VERSION=1.0.0
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-"$HERE/../dist/DualScreenAudio"}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
SCRATCH=${BUILD_SCRATCH_ROOT:-"$HOME/.hermes/cache/scratch"}
mkdir -p "$SCRATCH"
WORK=$(mktemp -d "$SCRATCH/dualscreen-audio.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SOURCE="$WORK/source"
mkdir -p "$SOURCE/upstream" "$SOURCE/modified"
# An extracted corresponding-source archive is sufficient for offline rebuilding.
if [[ -f "$HERE/upstream/BlackHole/BlackHole.c" && -f "$HERE/UPSTREAM_SHA" ]]; then
    [[ $(cat "$HERE/UPSTREAM_SHA") == "$PIN" ]] || { printf 'Unexpected source pin\n' >&2; exit 1; }
    cp -R "$HERE/upstream/." "$SOURCE/upstream/"
else
    UPSTREAM=${BLACKHOLE_SOURCE:-/Users/oleg/.hermes/cache/scratch/dualscreen-blackhole}
    git -C "$UPSTREAM" cat-file -e "$PIN^{commit}"
    git -C "$UPSTREAM" archive "$PIN" | tar -xf - -C "$SOURCE/upstream"
fi
printf '%s\n' "$PIN" > "$SOURCE/UPSTREAM_SHA"
cp "$0" "$SOURCE/build-dualscreen-audio.sh"
cp "$HERE/verify-dualscreen-audio.c" "$SOURCE/verify-dualscreen-audio.c"
cat > "$SOURCE/modified/DualScreenAudioConfig.h" <<'HEADER'
/* DualScreen local customization; original source copyright/license preserved. */
#define kDriver_Name "DualScreenAudio"
#define kPlugIn_BundleID "com.dualscreen.audio.driver"
#define kPlugIn_Icon ""
#define kHas_Driver_Name_Format false
#define kDevice_Name "Xiaoxin Pad Pro 12.7"
#define kDevice2_Name "DualScreenAudio (disabled mirror)"
#define kManufacturer_Name "DualScreen"
#define kNumber_Of_Channels 2
#define kSampleRates 48000
#define kDevice_IsHidden false
#define kDevice_HasInput true
#define kDevice_HasOutput true
#define kDevice2_IsHidden true
#define kDevice2_HasInput false
#define kDevice2_HasOutput false
#define kEnableVolumeControl true
#define kCanBeDefaultDevice true
#define kCanBeDefaultSystemDevice true
HEADER
# Remove the optional icon property instead of returning a broken URL or artwork.
python3 - "$SOURCE" <<'PY'
from pathlib import Path
import re, sys, plistlib
root = Path(sys.argv[1])
s = (root/'upstream/BlackHole/BlackHole.c').read_text()
s = '/* Modified for DualScreen: icon property disabled; see NOTICE.txt. */\n' + s
label = '\t\tcase kAudioDevicePropertyIcon:\n'
assert s.count(label) == 4
# Two labels share their implementation with other properties. Remove only label.
s = s.replace(label, '', 2)
# Remaining icon cases have dedicated implementations ending at the next default.
s, count = re.subn(r'\t\tcase kAudioDevicePropertyIcon:\n.*?(?=\t\tdefault:)', '', s, flags=re.S)
assert count == 2
# Fix upstream control enumeration: respect scope, omit disabled pitch and use
# the secondary object's own list. Without this, output lists return input IDs
# and counting the disabled pitch control can walk past the array.
for name in ('kDevice_ObjectList', 'kDevice2_ObjectList'):
    old = f'{name}[i].type == kObjectType_Control && ({name}[i].scope == scope || scope == kAudioObjectPropertyScopeGlobal)'
    new = old + f' && (gPitch_Adjust_Enabled || {name}[i].id != kObjectID_Pitch_Adjust)'
    assert s.count(old) == 1
    s = s.replace(old, new)
old = '(kDevice_ObjectList[i].type == kObjectType_Control) && !(!gPitch_Adjust_Enabled && kDevice_ObjectList[i].id==kObjectID_Pitch_Adjust)'
assert s.count(old) == 2
for name in ('kDevice_ObjectList', 'kDevice2_ObjectList'):
    new = f'({name}[i].type == kObjectType_Control) && (gPitch_Adjust_Enabled || {name}[i].id != kObjectID_Pitch_Adjust) && ({name}[i].scope == inAddress->mScope || inAddress->mScope == kAudioObjectPropertyScopeGlobal)'
    s = s.replace(old, new, 1)
(root/'modified/BlackHole.c').write_text(s)
p = plistlib.loads((root/'upstream/BlackHole/BlackHole.plist').read_bytes())
p.update(CFBundleExecutable='DualScreenAudio', CFBundleIdentifier='com.dualscreen.audio.driver',
         CFBundleName='DualScreenAudio', CFBundleShortVersionString='1.0.0', CFBundleVersion='1')
p.pop('CFBundleIconFile', None)
(root/'modified/Info.plist').write_bytes(plistlib.dumps(p))
PY
cat > "$SOURCE/NOTICE.txt" <<'NOTICE'
DualScreenAudio is a modified BlackHole audio HAL driver, GPL-3.0.
Original copyright: Copyright (C) 2019 Existential Audio Inc.
See upstream/LICENSE for the complete unaltered copyright and GPLv3 license.
Local changes: DualScreen driver and bundle branding; Xiaoxin Pad Pro 12.7 device;
fixed stereo 48 kHz; native output volume/mute enabled; secondary device hidden
and all its streams disabled; control enumeration scope/count bugs fixed (including
secondary list selection and disabled pitch control); optional icon property
removed, no upstream artwork
used by the compiled driver. Upstream symbols retain their names for attribution.
Corresponding source, exact upstream pin, configuration, verifier and full CLT
build/package recipe are in this archive. Rebuild on macOS with CLT and Python 3:
  bash build-dualscreen-audio.sh "$HOME/DualScreenAudio-rebuild"
The bundle is ad-hoc signed; the local installer is unsigned and not notarized.
The installer has no installation scripts: it never removes existing drivers,
restarts coreaudiod or changes the selected system output device.
No installation or system audio changes are performed by this build script.
Public redistribution/integration licensing must be evaluated separately; this
artifact does not license other DualScreen components or grant trademark rights.
The archived original upstream source includes unmodified historical artwork;
none is copied into the customized driver bundle or used as its branding.
NOTICE
cp "$SOURCE/upstream/LICENSE" "$SOURCE/LICENSE"
ROOT="$WORK/payload"
DRIVER="$ROOT/Library/Audio/Plug-Ins/HAL/DualScreenAudio.driver"
SUPPORT="$ROOT/Library/Application Support/DualScreenAudio"
mkdir -p "$DRIVER/Contents/MacOS" "$DRIVER/Contents/Resources" "$SUPPORT"
cp "$SOURCE/modified/Info.plist" "$DRIVER/Contents/Info.plist"
cp "$SOURCE/LICENSE" "$SOURCE/NOTICE.txt" "$DRIVER/Contents/Resources/"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang --version
# kHas_Driver_Name_Format=false leaves an unreachable printf-style branch.
xcrun clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=13.0 \
  -std=gnu11 -O2 -fblocks -Wno-format-extra-args -bundle -include "$SOURCE/modified/DualScreenAudioConfig.h" \
  "$SOURCE/modified/BlackHole.c" -framework CoreAudio -framework CoreFoundation \
  -framework Accelerate -o "$DRIVER/Contents/MacOS/DualScreenAudio"
chmod -R u=rwX,go=rX "$ROOT"
codesign --force --sign - --timestamp=none "$DRIVER"
codesign --verify --strict --verbose=2 "$DRIVER"
plutil -lint "$DRIVER/Contents/Info.plist"
xcrun lipo -info "$DRIVER/Contents/MacOS/DualScreenAudio"
xcrun clang "$SOURCE/verify-dualscreen-audio.c" -framework CoreAudio -framework CoreFoundation -o "$WORK/verify-dualscreen-audio"
"$WORK/verify-dualscreen-audio" "$DRIVER/Contents/MacOS/DualScreenAudio"
# Source and recipe accompany the binary, both externally and in pkg payload.
COPYFILE_DISABLE=1 tar -czf "$OUT/DualScreenAudio-source.tar.gz" -C "$SOURCE" .
cp "$OUT/DualScreenAudio-source.tar.gz" "$SUPPORT/"
cp "$SOURCE/LICENSE" "$SOURCE/NOTICE.txt" "$SOURCE/UPSTREAM_SHA" "$SUPPORT/"
pkgbuild --analyze --root "$ROOT" "$WORK/components.plist"
# Force exact payload paths: do not relocate a pre-existing bundle elsewhere.
python3 - "$WORK/components.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, 'rb') as f: entries = plistlib.load(f)
for entry in entries:
    entry['BundleIsRelocatable'] = False
    entry['BundleOverwriteAction'] = 'upgrade'
with open(p, 'wb') as f: plistlib.dump(entries, f)
PY
PKG="$OUT/DualScreenAudio-$VERSION.pkg"
pkgbuild --root "$ROOT" --component-plist "$WORK/components.plist" \
  --identifier com.dualscreen.audio.installer --version "$VERSION" \
  --ownership recommended --install-location / "$PKG"
# Local copies are for inspection, not HAL registration or installation.
if [[ -e "$OUT/DualScreenAudio.driver" ]]; then rm -rf "$OUT/DualScreenAudio.driver"; fi
cp -R "$DRIVER" "$OUT/DualScreenAudio.driver"
cp "$WORK/verify-dualscreen-audio" "$OUT/verify-dualscreen-audio"
cp "$SOURCE/NOTICE.txt" "$SOURCE/UPSTREAM_SHA" "$OUT/"
shasum -a 256 "$PKG" "$OUT/DualScreenAudio-source.tar.gz"
printf 'PKG=%s\nDRIVER_UID=DualScreenAudio_UID\nSOURCE_SHA=%s\n' "$PKG" "$PIN"

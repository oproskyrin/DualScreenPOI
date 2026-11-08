#!/bin/bash
# Local GPLv3 HAL driver build. Never installs, removes drivers, or restarts audio.
# Modes: default builds the DualScreenAudio output HAL; `--mic` builds the
# DualScreenMic input HAL (mono, UID DualScreenMic_UID) from the same pinned
# sources. Both variants coexist: distinct bundle IDs, UIDs and notify names.
set -euo pipefail
PIN=574029f0d3175ccf29a826d74be4da3967b1cb92
VERSION=1.1.0
HERE=$(cd "$(dirname "$0")" && pwd)
MODE=output
if [[ "${1:-}" == "--mic" ]]; then MODE=mic; shift; fi
if [[ "$MODE" == mic ]]; then
    DRIVER_NAME=DualScreenMic
    DRIVER_BUNDLE_ID=com.dualscreen.audio.driver.mic
    INSTALLER_ID=com.dualscreen.audio.installer.mic
    DRIVER_UID=DualScreenMic_UID
    PRESENCE_NOTIFY_NAME=com.oleg.dualscreen.host.mic-pid
else
    DRIVER_NAME=DualScreenAudio
    DRIVER_BUNDLE_ID=com.dualscreen.audio.driver
    INSTALLER_ID=com.dualscreen.audio.installer
    DRIVER_UID=DualScreenAudio_UID
    PRESENCE_NOTIFY_NAME=com.oleg.dualscreen.host.audio-pid
fi
OUT=${1:-"$HERE/../dist/$DRIVER_NAME"}
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
elif [[ -z ${BLACKHOLE_SOURCE:-} && -f "$HERE/../dist/DualScreenAudio/DualScreenAudio-source.tar.gz" ]]; then
    tar -xzf "$HERE/../dist/DualScreenAudio/DualScreenAudio-source.tar.gz" -C "$SOURCE" ./upstream ./UPSTREAM_SHA
    [[ $(cat "$SOURCE/UPSTREAM_SHA") == "$PIN" ]] || { printf 'Unexpected archive pin\n' >&2; exit 1; }
else
    UPSTREAM=${BLACKHOLE_SOURCE:-/Users/oleg/.hermes/cache/scratch/dualscreen-blackhole}
    git -C "$UPSTREAM" cat-file -e "$PIN^{commit}"
    git -C "$UPSTREAM" archive "$PIN" | tar -xf - -C "$SOURCE/upstream"
fi
# The mic variant shares the pinned upstream with the output HAL; only the
# config header, plist identity, two scope-split default-device properties,
# the compiled notify name and the packaging identifiers differ.
printf '%s\n' "$PIN" > "$SOURCE/UPSTREAM_SHA"
printf '%s\n' "$VERSION" > "$SOURCE/VERSION"
cat > "$SOURCE/PRESENCE_PROTOCOL.txt" <<'PROTOCOL'
DualScreenAudio 1.1.0 presence protocol (public metadata, no secrets)
PID state: com.oleg.dualscreen.host.audio-pid, uint64, zero means inactive.
Birth state: com.oleg.dualscreen.host.audio-pid.start-time, uint64, process start
seconds * 1000000 + microseconds from proc_pidinfo(PROC_PIDTBSDINFO).
Heartbeat state: com.oleg.dualscreen.host.audio-pid.heartbeat, uint64 raw
mach_continuous_time() ticks (NOT nanoseconds), zero means inactive.
Host uses notify_register_check; sets birth, PID, heartbeat, then notify_post(PID
name). A serial background DispatchSourceTimer refreshes heartbeat every 250ms.
Clock is machine-wide, monotonic and includes sleep, shared across Swift/C. HAL
converts elapsed ticks using mach_timebase_info: delta * numer / denom ns, with
128-bit arithmetic before multiplication (no overflow). Accept age <= 1.5 seconds;
reject zero or any future timestamp before subtracting. Poll every 250ms (normal
expiry visibility <= 1.75s plus scheduler delay, not a realtime guarantee).
Notify state is volatile, not persisted across reboot; future and expired tokens
are rejected even after a HAL reload. Crash/freeze ceases renewal; stale PID reuse
cannot renew a heartbeat. No wall-clock or process-inspection permission needed.
Only publish after real server startup, not updater-only/smoke invocations.
Normal stop restores an available prior non-tablet default output only while the
current default is still tablet; otherwise preserves user choice. If prior output
vanished use available built-in, then available non-tablet output. Never alter
volume/mute. Stop invalidates the timer generation under the same lock as timer
callbacks; queued callbacks cannot publish after stop or into a new start. Clear
heartbeat then PID only if BOTH PID and birth still belong to this host, before
cancelling notify tokens. Timer callbacks also check ownership before renewing.
HAL reads only heartbeat initially and on a serial 250ms dispatch timer. It never
calls kill/proc_pidinfo or queries another process, including across user IDs.
PID/birth metadata are publisher ownership hints, not an HAL availability gate.
Offline primary: absent from plug-in/box device and owned-object lists, not alive,
hidden. Online: one primary device. Secondary device never enumerated. UID and
control values remain unchanged; PropertiesChanged notifies plug-in, box/device.
All presence probing and notifications occur outside the realtime audio thread.
On crash/removal CoreAudio owns fallback, with no forced output write from HAL.
Darwin notify state is shared between registrations/processes (including other
users); notify_post alone carries no PID, and notify_set_state does not itself
post an event. No authentication/security guarantee is implied by this hint.
Sources: macOS SDK notify.h and AudioServerPlugIn.h; local notify(3) man page.
Tests use an isolated com.oleg.dualscreen.test.* name and dlopen/mock HAL host;
the actual Swift publisher is exercised across processes by the presence script.
Where sandbox-exec exists, a separate child loads the actual ABI under a temporary
(allow default)(deny process-info*) policy: the legacy proc_pidinfo gate is proven
denied while heartbeat detection works. This is NOT the actual coreaudiod sandbox
or cross-UID installation test. Public notify namespace is intentionally not an
authentication channel: another user/process can spoof or clear this hint.
Tests prove API topology/notify behavior, not installed Sound UI/cache/fallback.
Run source-only Swift/ABI tests and rebuild: bash scripts/test-host-audio-presence.sh --hal
An installed-device/System Settings regression requires separate user approval.
PROTOCOL
if [[ "$MODE" == mic ]]; then
    sed -i '' 's/audio-pid/mic-pid/g' "$SOURCE/PRESENCE_PROTOCOL.txt"
    printf '%s\n' "DualScreenMic variant: the identical contract runs on the mic notify" \
        "name, published by the same host process via AudioDevicePresence with" \
        "inert routing - it never touches the default output route." >> "$SOURCE/PRESENCE_PROTOCOL.txt"
fi
cp "$0" "$SOURCE/build-dualscreen-audio.sh"
cp "$HERE/verify-dualscreen-audio.c" "$SOURCE/verify-dualscreen-audio.c"
cp "$HERE/DualScreenAudioPresence.h" "$SOURCE/modified/DualScreenAudioPresence.h"
cp "$HERE/DualScreenAudioPresence.h" "$SOURCE/DualScreenAudioPresence.h"
# Include the real host publisher and device-free lifecycle/ownership/routing tests.
# The root recipe still rebuilds independently using only the original CLT tools.
if [[ -f "$HERE/host/Sources/DualScreenHost/MicInputRoute.swift" ]]; then
    HOST_SOURCE_ROOT="$HERE" # extracted corresponding-source archive
else
    HOST_SOURCE_ROOT="$HERE/.."
fi
mkdir -p "$SOURCE/host/Sources/DualScreenHost" "$SOURCE/host/Tests" "$SOURCE/scripts"
cp "$HOST_SOURCE_ROOT/host/Sources/DualScreenHost/AudioDevicePresence.swift" "$SOURCE/host/Sources/DualScreenHost/"
cp "$HOST_SOURCE_ROOT/host/Sources/DualScreenHost/MicInputRoute.swift" "$SOURCE/host/Sources/DualScreenHost/"
cp "$HOST_SOURCE_ROOT/host/Tests/AudioDevicePresenceTests.swift" "$SOURCE/host/Tests/"
cp "$HOST_SOURCE_ROOT/host/Tests/MicInputRouteTests.swift" "$SOURCE/host/Tests/"
cp "$HOST_SOURCE_ROOT/scripts/test-host-audio-presence.sh" "$SOURCE/scripts/"
cp "$HOST_SOURCE_ROOT/scripts/test-host-mic.sh" "$SOURCE/scripts/"
if [[ "$MODE" == mic ]]; then
cat > "$SOURCE/modified/DualScreenAudioConfig.h" <<'HEADER'
/* DualScreen local customization; original source copyright/license preserved.
 * DualScreenMic variant: mono 48 kHz input device fed by the host over 0x07. */
#define kDriver_Name "DualScreenMic"
#define kPlugIn_BundleID "com.dualscreen.audio.driver.mic"
#define kPlugIn_Icon ""
#define kHas_Driver_Name_Format false
#define kDevice_Name "Xiaoxin Pad Pro 12.7"
#define kDevice2_Name "DualScreenMic (disabled mirror)"
#define kManufacturer_Name "DualScreen"
#define kNumber_Of_Channels 1
#define kSampleRates 48000
#define kDevice_IsHidden false
#define kDevice_HasInput true
#define kDevice_HasOutput true
#define kDevice2_IsHidden true
#define kDevice2_HasInput false
#define kDevice2_HasOutput false
#define kEnableVolumeControl false
#define kCanBeDefaultDevice true
#define kCanBeDefaultSystemDevice false
HEADER
else
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
fi
# Remove the optional icon property instead of returning a broken URL or artwork.
python3 - "$SOURCE" "$MODE" <<'PY'
from pathlib import Path
import re, sys, plistlib
root = Path(sys.argv[1])
mic = sys.argv[2] == 'mic'
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
# Dynamic topology is handled at the validated public property entry points.
marker = 'static OSStatus\tBlackHole_Initialize('
assert s.count(marker) == 1
s = s.replace(marker, '#include "DualScreenAudioPresence.h"\n\n' + marker)
s = s.replace('gPlugIn_Host = inHost;', 'gPlugIn_Host = inHost;\n    dsInitializePresence();')
# Device identity/gain remain stable; only availability changes.
s = s.replace('*((UInt32*)outData) = kDevice_IsHidden;', '*((UInt32*)outData) = !atomic_load(&dsPresent);')
start = s.index('static OSStatus\tBlackHole_GetDevicePropertyData(')
pos = s.index('case kAudioDevicePropertyDeviceIsAlive:', start)
end = s.index('case kAudioDevicePropertyDeviceIsRunning:', pos)
part = s[pos:end].replace('*((UInt32*)outData) = 1;', '*((UInt32*)outData) = inObjectID == kObjectID_Device && atomic_load(&dsPresent);')
s = s[:pos] + part + s[end:]
for function, body in (
    ('BlackHole_GetPropertyDataSize', '''AudioObjectID dsIDs[2]; UInt32 dsCount;
    if (dsList(inObjectID, inAddress->mSelector, dsIDs, &dsCount)) {
        *outDataSize = dsCount * sizeof(AudioObjectID); return noErr;
    }
    '''),
    ('BlackHole_GetPropertyData', '''if (inObjectID == kObjectID_PlugIn && inAddress->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) {
        if (inQualifierDataSize != sizeof(CFStringRef) || !inQualifierData || inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
        CFStringRef uid = *(CFStringRef*)inQualifierData;
        if (!uid || CFGetTypeID(uid) != CFStringGetTypeID()) return kAudioHardwareIllegalOperationError;
        CFStringRef actualUID = get_device_uid();
        *(AudioObjectID*)outData = atomic_load(&dsPresent) && CFEqual(uid, actualUID) ? kObjectID_Device : kAudioObjectUnknown;
        CFRelease(actualUID); *outDataSize = sizeof(AudioObjectID); return noErr;
    }
    AudioObjectID dsIDs[2]; UInt32 dsCount;
    if (dsList(inObjectID, inAddress->mSelector, dsIDs, &dsCount)) {
        UInt32 bytes = minimum(dsCount, inDataSize / sizeof(AudioObjectID)) * sizeof(AudioObjectID);
        memcpy(outData, dsIDs, bytes); *outDataSize = bytes; return noErr;
    }
    ''')):
    start = s.index('static OSStatus\t' + function + '(')
    pos = s.index('switch(inObjectID)', start)
    s = s[:pos] + body + s[pos:]
if mic:
    # Mic variant: the device feeds its ring from host playback, so an output
    # stream must exist — but it must never become a default *output*.
    # Scope-split both default properties: input keeps kCanBeDefault*, output
    # always refuses, so the mic never captures the system output route.
    old = '\t\t\t*((UInt32*)outData) = kCanBeDefaultDevice;'
    assert s.count(old) == 1
    s = s.replace(old, '\t\t\t*((UInt32*)outData) = inAddress->mScope == kAudioObjectPropertyScopeOutput ? 0 : kCanBeDefaultDevice;')
    old = '\t\t\t*((UInt32*)outData) = kCanBeDefaultSystemDevice;'
    assert s.count(old) == 1
    s = s.replace(old, '\t\t\t*((UInt32*)outData) = inAddress->mScope == kAudioObjectPropertyScopeOutput ? 0 : kCanBeDefaultSystemDevice;')
(root/'modified/BlackHole.c').write_text(s)
name = 'DualScreenMic' if mic else 'DualScreenAudio'
p = plistlib.loads((root/'upstream/BlackHole/BlackHole.plist').read_bytes())
p.update(CFBundleExecutable=name, CFBundleIdentifier='com.dualscreen.audio.driver.mic' if mic else 'com.dualscreen.audio.driver',
         CFBundleName=name, CFBundleShortVersionString='1.1.0', CFBundleVersion='1.1.0')
p.pop('CFBundleIconFile', None)
(root/'modified/Info.plist').write_bytes(plistlib.dumps(p))
PY
if [[ "$MODE" == mic ]]; then
cat > "$SOURCE/NOTICE.txt" <<'NOTICE'
DualScreenMic is a modified BlackHole audio HAL driver, GPL-3.0.
Original copyright: Copyright (C) 2019 Existential Audio Inc.
See upstream/LICENSE for the complete unaltered copyright and GPLv3 license.
Local changes (version 1.1.0): dedicated mono 48 kHz microphone input variant,
coexists with the DualScreenAudio output HAL (distinct bundle id, UID
DualScreenMic_UID, notify name com.oleg.dualscreen.host.mic-pid); the same
dynamic notify-heartbeat device presence contract as the output HAL; the
device is defaultable as an INPUT only — both default-device properties refuse
the output scope; the always-present output stream exists solely as the host
ring-buffer feed path (PCM reaches the ring through ordinary CoreAudio
playback, never direct coreaudiod access); no volume/mute controls; secondary
device hidden with no streams; control enumeration and icon fixes as in the
output HAL; no upstream artwork is used by the compiled driver. Upstream
symbols retain their names for attribution.
Corresponding source, exact upstream pin, configuration, verifier and full CLT
build/package recipe are in this archive. Rebuild on macOS with CLT and Python 3:
  bash build-dualscreen-audio.sh --mic "$HOME/DualScreenMic-rebuild"
The bundle is ad-hoc signed; the local installer is unsigned and not notarized.
The installer has no installation scripts: it never removes existing drivers,
restarts coreaudiod or changes any selected system audio device.
No installation or system audio changes are performed by this build script.
Public redistribution/integration licensing must be evaluated separately; this
artifact does not license other DualScreen components or grant trademark rights.
The archived original upstream source includes unmodified historical artwork;
none is copied into the customized driver bundle or used as its branding.
NOTICE
else
cat > "$SOURCE/NOTICE.txt" <<'NOTICE'
DualScreenAudio is a modified BlackHole audio HAL driver, GPL-3.0.
Original copyright: Copyright (C) 2019 Existential Audio Inc.
See upstream/LICENSE for the complete unaltered copyright and GPLv3 license.
Local changes (version 1.1.0): dynamic primary device topology controlled by a live
bounded monotonic notify heartbeat; crash/freeze expiry outside realtime callbacks;
plugin/box lists and alive/hidden notifications; UID translation validation;
DualScreen driver and bundle branding; Xiaoxin Pad Pro 12.7 device;
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
fi
cp "$SOURCE/upstream/LICENSE" "$SOURCE/LICENSE"
ROOT="$WORK/payload"
DRIVER="$ROOT/Library/Audio/Plug-Ins/HAL/$DRIVER_NAME.driver"
SUPPORT="$ROOT/Library/Application Support/$DRIVER_NAME"
mkdir -p "$DRIVER/Contents/MacOS" "$DRIVER/Contents/Resources" "$SUPPORT"
cp "$SOURCE/modified/Info.plist" "$DRIVER/Contents/Info.plist"
cp "$SOURCE/LICENSE" "$SOURCE/NOTICE.txt" "$DRIVER/Contents/Resources/"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang --version
# kHas_Driver_Name_Format=false leaves an unreachable printf-style branch.
# The shipped driver publishes on the variant's own notify name; the presence
# test bundle below keeps the isolated com.oleg.dualscreen.test.* name.
xcrun clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=13.0 \
  -std=gnu11 -O2 -fblocks -Wno-format-extra-args -bundle -include "$SOURCE/modified/DualScreenAudioConfig.h" \
  -DDS_AUDIO_PRESENCE_NOTIFY_NAME="\"$PRESENCE_NOTIFY_NAME\"" \
  "$SOURCE/modified/BlackHole.c" -framework CoreAudio -framework CoreFoundation \
  -framework Accelerate -o "$DRIVER/Contents/MacOS/$DRIVER_NAME"
chmod -R u=rwX,go=rX "$ROOT"
codesign --force --sign - --timestamp=none "$DRIVER"
codesign --verify --strict --verbose=2 "$DRIVER"
plutil -lint "$DRIVER/Contents/Info.plist"
xcrun lipo -info "$DRIVER/Contents/MacOS/$DRIVER_NAME"
xcrun clang "$SOURCE/verify-dualscreen-audio.c" -framework CoreAudio -framework CoreFoundation -o "$WORK/verify-dualscreen-audio"
if [[ "$MODE" == mic ]]; then
    "$WORK/verify-dualscreen-audio" "$DRIVER/Contents/MacOS/$DRIVER_NAME" --mic
else
    "$WORK/verify-dualscreen-audio" "$DRIVER/Contents/MacOS/$DRIVER_NAME"
fi
# Exercise the actual plug-in ABI with a mock HAL host, isolated from installed
# audio. Only the notification name differs from the shipped binary.
TEST_NAME="com.oleg.dualscreen.test.audio-presence.$$"
xcrun clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=13.0 \
  -std=gnu11 -O2 -fblocks -Wno-format-extra-args -bundle \
  -DDS_AUDIO_PRESENCE_NOTIFY_NAME=\""$TEST_NAME"\" \
  -include "$SOURCE/modified/DualScreenAudioConfig.h" "$SOURCE/modified/BlackHole.c" \
  -framework CoreAudio -framework CoreFoundation -framework Accelerate -o "$WORK/presence-test.bundle"
if [[ "$MODE" == mic ]]; then
    "$WORK/verify-dualscreen-audio" "$WORK/presence-test.bundle" --mic "$TEST_NAME"
else
    "$WORK/verify-dualscreen-audio" "$WORK/presence-test.bundle" "$TEST_NAME"
fi
# Source and recipe accompany the binary, both externally and in pkg payload.
COPYFILE_DISABLE=1 tar -czf "$OUT/$DRIVER_NAME-source.tar.gz" -C "$SOURCE" .
cp "$OUT/$DRIVER_NAME-source.tar.gz" "$SUPPORT/"
cp "$SOURCE/LICENSE" "$SOURCE/NOTICE.txt" "$SOURCE/UPSTREAM_SHA" "$SOURCE/VERSION" "$SOURCE/PRESENCE_PROTOCOL.txt" "$SUPPORT/"
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
PKG="$OUT/$DRIVER_NAME-$VERSION.pkg"
pkgbuild --root "$ROOT" --component-plist "$WORK/components.plist" \
  --identifier "$INSTALLER_ID" --version "$VERSION" \
  --ownership recommended --install-location / "$PKG"
# Local copies are for inspection, not HAL registration or installation.
if [[ -e "$OUT/$DRIVER_NAME.driver" ]]; then rm -rf "$OUT/$DRIVER_NAME.driver"; fi
cp -R "$DRIVER" "$OUT/$DRIVER_NAME.driver"
cp "$WORK/verify-dualscreen-audio" "$OUT/verify-dualscreen-audio"
cp "$SOURCE/NOTICE.txt" "$SOURCE/UPSTREAM_SHA" "$OUT/"
shasum -a 256 "$PKG" "$OUT/$DRIVER_NAME-source.tar.gz"
printf 'PKG=%s\nDRIVER_UID=%s\nSOURCE_SHA=%s\n' "$PKG" "$DRIVER_UID" "$PIN"

# macOS application packaging

Run from the repository on macOS with Command Line Tools:

```sh
./scripts/build-macos-app.sh --version 1.0.0
DUALSCREEN_TEST_ARTIFACTS=dist/macos python3 -m unittest discover -s tests -p test_macos_packaging.py -v
```

The default build uses SwiftPM's release DualScreenHost product for arm64. It
creates `dist/macos/DualScreen.app`, `DualScreen-v1.0.0-macos-arm64.pkg`, and
`DualScreen-v1.0.0-macos-arm64.zip`. The app includes a full-resolution ICNS
icon generated from `assets/branding/dualscreen-icon.png`, adb and its NOTICE,
and the signed vendor Sparkle framework with its license and symlinks intact.
`component.plist` records nonrelocatable, version-checked atomic bundle upgrade
semantics used by the installer.

## Prerequisites and overrides

- `packaging/macos/sparkle-public-key.txt` must contain the real, 32-byte,
  base64-encoded Ed25519 public key corresponding to the release signing key.
  Missing or malformed keys are fatal; there are no placeholder keys.
- The pinned SwiftPM Sparkle artifact must have been resolved. The default
  framework path is `host/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework`.
- `adb` must be on PATH (or supply `--adb`); its resolved directory must contain
  `NOTICE.txt`. The builder rejects Homebrew/local dynamic dependencies and
  requires adb to link only Apple system libraries.
- Useful options: `--public-key FILE`, `--sparkle-framework PATH`,
  `--sparkle-license FILE`, `--adb-notice FILE`, `--host-binary FILE`,
  `--output DIR`, `--arch arm64|x86_64`. A prebuilt host must genuinely link
  Sparkle and support the requested architecture; it is not a stub fallback.
- Environment equivalents: `VERSION`, `SPARKLE_PUBLIC_KEY_FILE`,
  `SPARKLE_FRAMEWORK`, `SPARKLE_LICENSE`, `ADB_BINARY`, `ADB_NOTICE`,
  `CODESIGN_IDENTITY`, `INSTALLER_IDENTITY`.

The script reproduces the packaging procedure and validates inputs. It does
not promise byte-identical ZIP/PKG files across toolchains, signing timestamps,
or source file timestamps. Use a clean checkout and fixed tool/dependency
versions when reproducing a release.

## Installation and updates

The default build requires the native HAL components at
`dist/DualScreenAudio/DualScreenAudio-1.1.0.pkg` and
`dist/DualScreenMic/DualScreenMic-1.1.0.pkg` (or explicit
`AUDIO_COMPONENT_PKG` / `--audio-component-pkg` and `MIC_COMPONENT_PKG` /
`--mic-component-pkg` inputs). It validates each component receipt ID, branded
driver UID, signature, architecture, license/NOTICE and self-contained
corresponding-source archive before embedding it. It rejects unexpected payload
files and audio install scripts. There is **no automatic fallback to the old
permanent-device 1.0.0 driver**. The 1.1.0 drivers supply the runtime-dependent
tablet-output and tablet-mic presence behavior; build/verification of that
behavior belongs to the audio components, not this packaging script.

The default PKG is a complete first-install distribution with all components
selected: application at `/Applications/DualScreen.app`, the native
`DualScreenAudio.driver` (tablet output, `DualScreenAudio_UID`) and
`DualScreenMic.driver` (tablet microphone, `DualScreenMic_UID`) at
`/Library/Audio/Plug-Ins/HAL/`, plus GPL license, NOTICE, pin and corresponding
source under `/Library/Application Support/DualScreenAudio/` and
`/Library/Application Support/DualScreenMic/`. They use the existing
`com.dualscreen.audio.installer` and `com.dualscreen.audio.installer.mic`
receipts; neither creates an aggregate or installs a separate BlackHole device.
Both audio installations declare `RequireRestart` to macOS Installer instead of
killing CoreAudio. The build never installs packages or restarts audio.

Use `--app-only` only to intentionally build a PKG without the HAL component.
The app component is nonrelocatable and atomically upgrades only the installed
bundle. Its preinstall script gracefully terminates only the exact installed
executable, waits at most 20 seconds, and fails rather than forcing a shutdown.
It does not stop a development/repository host or launch an app as root.
Subsequent app updates always use the app-only Sparkle ZIP; they leave the HAL
untouched and do not require a driver/admin installation on every app update.
Driver upgrades, if required later, need a new complete installer. The signed
stable appcast is:

`https://github.com/oproskyrin/DualScreenPOI/releases/download/macos-updates/appcast.xml`

Automatic update **checks** are enabled; automatic download/install is disabled.
Both the feed and archive must be signed by the matching Ed25519 key; signature
verification is required before extraction. This script neither publishes the
feed nor signs release archives; use the release publisher for that step.

### Publishing a signed app update

The private update key stays in the maintainer's macOS Keychain under the Sparkle
account `com.oleg.dualscreen.host`; it is not a GitHub Actions secret. CI tests and
builds the full package but does not advance the update feed. On the signing Mac:

```sh
# Build and verify the artifacts before signing them.
python3 scripts/macos_release.py --version 1.0.0 --artifacts dist/macos
# After CI created the matching stable versioned GitHub Release:
python3 scripts/macos_release.py --version 1.0.0 --artifacts dist/macos --verify-only --publish
```

The publisher uses Sparkle's official tools, checks the bundle ID, version, feed,
public key, archive signature and signed XML, uploads immutable native assets,
reads them back, and advances the fixed `macos-updates` prerelease feed last.
Never rebuild and replace an already published ZIP under the same version: bump
the version instead. Retain the signing Keychain item; losing it prevents signing
updates accepted by existing installations. Do not export a private key into the
repository or print it in CI/chat. Additional driver changes require a new full
installer and its matching GPL corresponding source, not just a Sparkle app ZIP.

## Signing boundaries

Default output has an **ad-hoc signed application and unsigned installer**.
It is local-test output, not Developer ID signed or notarized; Gatekeeper
acceptance on another Mac has not been established. Optionally supply
`--codesign-identity` and `--installer-identity` for release certificates;
notarization and stapling remain separate release steps. Vendor Sparkle
framework/helper signatures are preserved rather than blindly deep-resigned.
The builder validates `codesign --verify --deep --strict` before output.

Tests expand the installer and ZIP, verify the payload and symlinks, and
validate code signatures without installing or launching anything. Read-only
Installer queries verify that both components are selected and restart is
required. Artifact tests expect audio version 1.1.0 by default; an intentional
older packaging fixture can be checked using `DUALSCREEN_TEST_AUDIO_VERSION`,
but is not the current end-user release acceptance target. Real
end-user install, permissions/TCC, launch/login behavior, and an end-to-end
Sparkle update still require separate interactive verification.

<div align="center">
  <img src="assets/branding/dualscreen-icon.png" width="112" height="112" alt="DualScreen icon">
  <h1>DualScreen</h1>
  <p><strong>Your Android tablet, a second screen for your Mac.</strong></p>
  <p>Extend or mirror over USB or Wi-Fi · audio · keyboard and touch · text clipboard · tablet microphone</p>
  <p><strong>English</strong> · <a href="README.ru.md">Русский</a></p>
  <p><a href="https://github.com/oproskyrin/DualScreenPOI/releases/latest"><strong>Download for Mac + Android</strong></a> · <a href="#quick-start">Quick start</a> · <a href="#feedback">Report your device</a></p>
  <img src="docs/screenshots/hero.jpg" width="820" alt="Mac desktop streamed to the Android client, with its floating menu button">
  <p><em>A streamed Mac desktop with the client panel hidden. This is a screen capture, not a photograph of the tablet.</em></p>
</div>

**Public beta.** Tested with an Apple Silicon Mac and **Lenovo Xiaoxin Pad Pro 12.7 (2023), TB371FC**. The declared minimums are **macOS 13+** and **Android 8+**; they are not a tested OS/device compatibility matrix. Other tablets need community testing. Use only on a network whose participants you trust: the streaming protocol has **no pairing, authentication or encryption**.

### Interface languages

Starting with **v1.7.0**, both platforms include **English and Russian in one app**. By default each device follows its own system language preferences, with English as the fallback. On Android, **Settings → App language** offers **System / Русский / English**; changing it stops the current connection, so reconnect afterward. The Mac host follows macOS system/per-app language preferences.

<details>
<summary><strong>English and Russian interface screenshots</strong></summary>

| English | Русский |
|---|---|
| ![English home screen](docs/screenshots/home-en.jpg) | ![Russian home screen](docs/screenshots/home-ru.jpg) |
| ![English settings](docs/screenshots/settings-en.jpg) | ![Russian settings](docs/screenshots/settings-ru.jpg) |

Actual tablet captures from an isolated UI test build; no connection or microphone recording was started for these screenshots.
</details>

[Features](#features) · [Installation](#installation) · [USB / Wi-Fi](#connection) · [Input](#input) · [Audio / microphone](#audio) · [Clipboard](#clipboard) · [Performance](#performance) · [Troubleshooting](#troubleshooting) · [Contributing](CONTRIBUTING.md)

<a id="features"></a>
## What it does

Move an editor, reference document or chat window onto your tablet. Apps keep running on the Mac; the Android client receives video and audio and sends input back.

| Feature | What to expect |
|---|---|
| Desktop | Extended desktop or mirror; mode, resolution and requested frame rate controls on Mac and Android |
| Display layout | Saves the extended display position; places it to the right on first use |
| HiDPI | Tested tablet target: 1472×920 logical points / 2944×1840 backing pixels |
| Transport | USB through bundled `adb`; Wi-Fi discovery with mDNS or manual `IP:7381` |
| Video | HEVC by default; H.264 alternative negotiated with the client; hardware decoder compatibility varies |
| Input | Touch, drag, two-finger scroll, long-press right click, on-screen keyboard, physical keyboard and mouse/trackpad |
| Audio | Selectable tablet output on Mac, with system volume and mute |
| Clipboard | Text only, subject to Android clipboard focus restrictions |
| Microphone | Optional tablet-to-Mac audio; requires the microphone HAL driver and Android permission |
| Controls | Hideable panel, draggable **☰** handle, settings presets and diagnostic overlay |

<table>
  <tr>
    <td><img src="docs/screenshots/stats.jpg" alt="Streamed desktop with diagnostic overlay and latency history at bottom left"></td>
    <td><img src="docs/screenshots/settings.jpg" alt="Android settings showing presets, playback, diagnostics, clipboard and microphone controls"></td>
  </tr>
  <tr>
    <td><em>Diagnostic overlay and sample history—UI illustration, not benchmark evidence. Labels containing “screen” do not establish physical display latency.</em></td>
    <td><em>Android settings: presets, playback, diagnostics, clipboard and microphone. Screenshots show the Russian UI; wording may vary by version.</em></td>
  </tr>
</table>

<a id="quick-start"></a>
## Quick start

1. From the [release page](https://github.com/oproskyrin/DualScreenPOI/releases/latest), download the full **`DualScreen-vX.Y.Z-macos-arm64.pkg`** and **`DualScreenClient-vX.Y.Z.apk`**.
2. Install the Mac package, restart when prompted, and open **DualScreen** from Applications. It runs in the **menu bar**, not the Dock.
3. Grant **Screen Recording** and **Accessibility** on Mac as described below. Install and open the APK on Android.
4. For USB, enable Android **USB debugging**, connect a data-capable cable, unlock the tablet and authorize your Mac. Choose **Connect via USB** in the client.
5. Arrange the displays in macOS Displays settings and move a window onto the tablet. For tablet audio, select **Xiaoxin Pad Pro 12.7** as the Mac output.

Prefer Wi-Fi? Use **Find Mac via Wi-Fi**, then choose your Mac, on the same trusted local network. No USB debugging is needed for Wi-Fi.

<a id="installation"></a>
## Installation and permissions

### Mac

The full package targets **Apple Silicon / macOS 13+** and requires administrator approval and a restart for its system audio components. Intel is not a supported full-installer target. End users do not need Homebrew, Xcode or a separate BlackHole/`adb` installation.

The current full-package builder includes:

- `/Applications/DualScreen.app`, including `adb` and the Sparkle updater;
- `/Library/Audio/Plug-Ins/HAL/DualScreenAudio.driver` — tablet output;
- `/Library/Audio/Plug-Ins/HAL/DualScreenMic.driver` — tablet microphone input;
- licenses, notices and corresponding driver source in `/Library/Application Support/DualScreenAudio/` and `/Library/Application Support/DualScreenMic/`.

An app-only ZIP or legacy host-binary archive is **not** a complete first installation. Older installed packages may lack the mic driver; an app update cannot add it.

In **System Settings → Privacy & Security**, grant:

- **Screen Recording** (section name varies by macOS) for video;
- **Accessibility** for injected mouse, touch and keyboard input;
- **Local Network**, if requested, for local connections/discovery.

Quit and reopen the app if macOS asks. Signing identity changes, especially ad-hoc builds, can require granting permissions again after an update.

> **Signing caveat:** do not assume Apple Developer ID signing or notarization. The default packaging uses an ad-hoc app signature and an unsigned installer; maintainer builds may use a local signing identity. Gatekeeper acceptance on another Mac is not guaranteed. Verify the download source, and use macOS **Open Anyway** only if you trust the file and the option is available. Do not disable Gatekeeper or SIP, or install someone else's local signing certificate as a workaround. Sparkle's update signature is not Apple notarization.

### Android

Install the APK from the same release. Android may ask you to allow installation from your browser or file manager. USB requires Developer options → **USB debugging** and approval for your own Mac. On Android 13+, notification permission lets you return to the session from the notification shade; it is not required for connection. Microphone permission is requested only when enabling mic forwarding.

APK signing currently uses the build environment's debug key. Builds from different environments may not update in place. Do not uninstall casually: uninstalling removes client settings. Report a signature mismatch with the old/new download sources rather than bypassing signature verification.

<a id="connection"></a>
## USB and Wi-Fi

**USB:** start the Mac app, connect a data cable, unlock and authorize the tablet. The host configures `adb reverse` for TCP 7381 using its bundled `adb`. Open the client and choose **Connect via USB** if necessary; there is no need to type `localhost`. Trust USB debugging only on computers you control.

**Wi-Fi:** start the host on the same trusted local network. Choose **Find Mac via Wi-Fi**, then select a computer; discovery does not automatically choose the first result. If mDNS is blocked, enter the Mac's `IP:7381`. Guest isolation, VPNs and firewall/local-network permissions can prevent discovery or connection. USB and Wi-Fi addresses are kept separately.

**Security boundary:** USB does not turn DSXP into an authenticated protocol or necessarily disable the network listener. A network peer that can reach the host port can attempt to receive the stream, inject input, exchange clipboard text or send mic data. Never forward TCP 7381 to the internet; avoid public/shared networks. See [SECURITY.md](SECURITY.md).

The client panel provides settings, keyboard and disconnect controls. **Hide panel** leaves a draggable **☰** handle; tap it to restore controls. **Disconnect** or **Cancel connection** stops automatic retries until you initiate another connection. The Android session notification returns to the existing client session; process termination is not a guaranteed recovery path.

<a id="input"></a>
## Keyboard, touch and pointer

Connect the keyboard/mouse/trackpad to **Android**, enable **Keyboard and trackpad** in client settings, and focus the streamed image. Mac Accessibility permission is required. Client dialogs and text fields retain Android input.

| Android modifier | Mac modifier |
|---|---|
| Meta | Command ⌘ |
| Alt | Option ⌥ |
| Ctrl | Control ⌃ |

Key down/up/repeat, mouse buttons and two-axis scrolling are forwarded. Held inputs are reset on focus loss/disconnect. Android-reserved shortcuts or gestures may never reach the Mac. Touch supports tapping, dragging, two-finger scrolling and long-press right click. Use the panel's keyboard action for the software keyboard. A local cursor is visual feedback, not proof that the Mac has processed an input event.

<a id="audio"></a>
## Audio and tablet microphone

### Mac → tablet sound

With the full HAL installation and host running, select **Xiaoxin Pad Pro 12.7** as the Mac sound output. During a connection, audio goes to the tablet. Selecting Mac speakers or another output stops tablet forwarding; this is not a simultaneous-output setup. System volume/mute and Android media volume both affect listening. Check the client's playback toggle too.

### Tablet → Mac microphone

1. Install a **full package containing `DualScreenMic.driver`** and restart as requested. A Sparkle/app-only update is not sufficient to add this system driver.
2. Enable **Forward microphone** in Android settings (off by default) and grant Android microphone permission.
3. If you enabled it after connecting, **disconnect and reconnect**: mic capability is advertised in the session hello, so the current session may not accept newly enabled mic audio.
4. Select **Xiaoxin Pad Pro 12.7** as the **input** in macOS or the receiving application. This is separate from the identically named output. Grant that Mac application's microphone permission if requested.

Recording stops on toggle-off or disconnection; the enabled preference is saved and can resume recording on a later connection. The HAL device's availability follows the **Mac host process**, not the Android toggle or connection, so seeing an input device does not prove recording or incoming audio. No mic PCM is written to the connection logs. [Protocol and implementation notes](docs/mic-0x07.md).

<a id="clipboard"></a>
## Text clipboard: Android limitation

Clipboard sync is enabled by default for capable peers and can be disabled in client settings. It transfers **text only, up to 1 MiB of UTF-8 text**; not images or files. Avoid copying secrets during a shared session.

**Mac → Android** is the verified normal-use direction. **Android → Mac is not an unrestricted background clipboard bridge:** Android 10+ restricts clipboard reading to a focused app. Copying in another app removes DualScreen's focus, and returning to DualScreen is **not guaranteed to resend** that clipboard: the current implementation listens for changes and does not explicitly re-read on resume. A readable clipboard change while DualScreen has focus is needed. Do not rely on this direction for a seamless copy-switch-paste workflow. See [clipboard details](docs/clipboard-sync.md).

<a id="performance"></a>
## Performance: what the numbers mean

A **limited TB371FC USB test** with HEVC, 2944×1840 backing pixels and a 120 fps request reported roughly **25–30 ms** for the overlay's capture metric. This is a historical observation, **not a latency promise** or a cross-device benchmark.

That metric begins at the **ScreenCaptureKit callback** and ends around Android **`MediaCodec.releaseOutputBuffer`**, when the decoded frame is submitted to the surface. It does **not** measure capture before the callback, compositor/presentation queues, physical panel scanout or touch-to-photon latency. Input transit ends at server message parsing, not application response. Do not add overlapping overlay intervals or a guessed display delay to manufacture a total.

Clock synchronization and FIFO frame pairing also limit precision, particularly when frames drop. Use a moving source, a sample series and a fixed configuration, not one screenshot. [Measurement boundaries and codec comparisons](docs/codec-negotiation.md).

The host requests **120 fps** by default, not 120 physically displayed frames per second. ScreenCaptureKit may emit few frames on a static desktop. Requested FPS, virtual display mode, Android panel refresh and decoder throughput are different quantities. H.264 is an alternative, not a guaranteed speed improvement; HEVC remains the default.

<a id="troubleshooting"></a>
## Troubleshooting and updates

| Symptom | First checks |
|---|---|
| Black/no image | Host running; Screen Recording allowed for this app/signature; quit/reopen after permission changes; reconnect |
| Image works, input does not | Accessibility permission; client input toggle; focus the stream rather than a client dialog |
| USB unavailable | Data cable, unlocked tablet, USB debugging, Mac authorization, installed client |
| Wi-Fi discovery empty | Same trusted subnet; isolation/VPN/firewall/mDNS; try `IP:7381` without exposing the port publicly |
| No tablet audio | Full HAL package installed and restarted; host running; selected Mac output; volume/mute and client playback |
| Mic device absent or silent | Mic HAL installed; restart after package; Android permission/toggle; reconnect after enabling; select Mac input |
| Latency increased | Verify moving content, resolution/codec, sustained load and transport; compare sample series rather than stale values |

Use **Check for Updates…** in the Mac menu. Sparkle checks for updates, but download/install requires confirmation. Ed25519 feed/archive verification does not establish Apple Developer ID trust. App-only updates leave system HAL drivers untouched; driver additions/upgrades need a new full package and administrator approval/restart. Update Android using the release APK. Recheck permissions after a signing change.

Logs: Mac `~/Library/Logs/DualScreen/host.log` and `host.log.1`; Android **Settings → Connection log**, with files under `Android/data/com.oleg.dualscreen/files/logs/` when accessible. Logs include connection metadata and clipboard sizes/hashes, not clipboard text, video/audio payloads or typed text/key codes. **Review and redact logs and screenshots before sharing**; metadata can identify your devices and network.

### Known limits

- One connected client; only TB371FC is currently verified, not a broad tablet/OS matrix.
- Extended displays use private `CGVirtualDisplay` APIs, which Apple can change.
- No secure pairing/authentication/encryption, HDR, stylus pressure/tilt, or complete sleep/orientation handling.
- Android clipboard focus restrictions and device-specific decoder/input behavior apply.

<a id="feedback"></a>
## Help test the beta

**Does your tablet work? Tell us—even if everything works.** Open a [device compatibility report](https://github.com/oproskyrin/DualScreenPOI/issues/new?template=device-compatibility.yml) with the exact model, OS/app versions, USB/Wi-Fi and features tested. For failures, use the [bug report](https://github.com/oproskyrin/DualScreenPOI/issues/new?template=bug-report.yml). English and Russian reports are welcome. A request for testing is not a claim of compatibility.

Please share only screenshots you own and have reviewed for private desktop content. Security vulnerabilities belong in the [private reporting process](SECURITY.md), not public bug reports.

## Build and contribute

See [CONTRIBUTING.md](CONTRIBUTING.md) for build/test commands and review expectations, [macOS packaging](packaging/macos/README.md) for installer requirements, and the protocol notes for [codecs](docs/codec-negotiation.md), [clipboard](docs/clipboard-sync.md) and [mic](docs/mic-0x07.md). Build/test success alone does not establish installation, granted permissions or live hardware behavior.

## Licenses

The main app is **[MIT](LICENSE)**. Both separate BlackHole-derived HAL drivers, **DualScreenAudio and DualScreenMic**, are **GPL-3.0**. Each driver ships its license, change/attribution notice, pinned upstream commit, full corresponding-source archive (`*-source.tar.gz`) and rebuild instructions in its Application Support directory. The MIT license does not replace the drivers' GPL obligations. Sparkle and `adb` notices are bundled with the app.

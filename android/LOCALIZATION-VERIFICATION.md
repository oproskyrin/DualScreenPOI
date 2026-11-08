# Android localization verification

## Behavior

- One APK contains the English fallback (`res/values/strings.xml`) and Russian (`res/values-ru/strings.xml`). A matching `values-en` catalog guarantees that an explicit English override wins even when Russian is a secondary system locale; a parity test prevents its English copy from drifting. An unsupported system language uses English; there is no runtime translation dictionary or rendered-view text replacement.
- Settings → App language / Настройки → Язык приложения offers System / Русский / English. AndroidX AppCompat stores the override on Android 8–12; Android 13+ uses per-app languages and exposes the same supported languages in system app settings.
- Changing the in-app language deliberately **stops the current connection** before Activity recreation. This is explained next to the selector. Reconnect manually using USB or Wi-Fi afterward. Normal cancellation fences callbacks, releases held input, stops microphone/audio/decoder, removes the notification, and sets `user_stopped`; a stale autoconnect intent cannot resume it. Choosing the already-selected language does nothing.
- Native controls, dialogs, accessibility descriptions, notifications/channel descriptions, graph units, diagnostic sentences and client-side errors use resources. Wire identifiers, endpoint text, codec names and connection-log metadata are not translated. Unknown server error text remains exact in diagnostic metadata; the UI shows localized guidance rather than guessing its translation.

## Automated checks (no device required)

From `android/`:

```sh
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  gradle assembleRelease test lint --no-daemon -q
```

`LocalizationResourcesTest` parses the shipped XML catalogs, checks duplicate keys and key parity, checks indexed format argument/type parity and malformed placeholders, and exercises formatting under English and Russian locales. `ResourceTestStrings` loads the same resource files for bilingual notification/error tests rather than keeping test translations. Existing loopback protocol, cancellation/ownership, input, clipboard and microphone tests remain enabled.

## Screenshot/Surface QA — isolated emulator only, no tablet taps

This change has **not** been installed or visually verified on a tablet. JVM tests and APK compilation do not prove clipping, system permission dialogs, notification return, or live Surface rendering.

For later visual QA, use an explicitly selected disposable emulator, never an unqualified `adb` command and never the user's tablet or live Mac session. Any installation or interaction needs separate authorization. Drive native controls by accessibility text/resource identity through an instrumented UI test, not coordinate taps. Take screenshots using instrumentation (`UiAutomation.takeScreenshot()`) or an emulator-qualified read-only `exec-out screencap -p`; collect EN and RU at identical resolutions and font scales. Do not send touchscreen input while streaming: Surface events are remote Mac input.

Required captures and assertions:

1. System English, system Russian, and an unsupported system locale such as French with System selected; confirm English fallback for French. Repeat explicit English/Russian override across process restart and return to System.
2. Home, USB help, manual address/error, settings (all scroll sections), language picker/warning, notification permission explanation and empty connection log. Check long Russian labels, landscape/portrait, and enlarged font scale for clipping and accessible descriptions.
3. For Surface/stream screenshots, use a **disposable local DSXP fixture**, not the production host. It must negotiate valid video plus timing/stats and stream actual test frames into SurfaceView. Capture with home hidden, first with diagnostics visible and then with the control panel hidden. The remote frame itself remains the fixture's content in both languages; only client controls/diagnostics/units change. Confirm the handle remains glyph-only, transparent at rest, View.alpha=1, with no new background/border. Do not substitute a fake screenshot or plain black Surface for a decoded-frame result.
4. Capture connecting/reconnecting states and the ongoing notification in both languages; disconnect must remove it. A locale switch during connection/streaming must stop the session once, release mic/input, and return to a newly localized idle screen without automatic retry. A same-language selection must not stop/restart anything. Separately verify opening the ongoing notification returns to the existing session without changing transport.

No emulator, fixture, device installation, screenshot capture, tablet access or UI taps were performed as part of the code-only localization work.

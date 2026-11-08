# Contributing / Участие в разработке

English and Russian issues, documentation and pull requests are welcome. Start with the [English](README.md) or [Russian](README.ru.md) guide. For vulnerabilities, follow [SECURITY.md](SECURITY.md), not a public issue.

## Useful contributions

- Test an exact tablet model and share a [compatibility report](https://github.com/oproskyrin/DualScreenPOI/issues/new?template=device-compatibility.yml), including successful results.
- File a [reproducible bug](https://github.com/oproskyrin/DualScreenPOI/issues/new?template=bug-report.yml) with app/OS versions and transport.
- Improve both language guides together; keep UI instructions consistent with implementation.
- Discuss larger protocol, dependency, driver or UI changes in an issue before investing in a large patch.

## Build and test

Host: macOS, compatible Swift toolchain and Command Line Tools. Android: JDK 17, Gradle on PATH and Android SDK 35. Configure your local SDK path; do not commit machine-specific paths or signing keys. There is no Gradle wrapper assumed by these commands.

```sh
(cd host && swift build -c release)
(cd android && gradle assembleRelease test lint --no-daemon)
python3 -m unittest discover -s tests -v

# Choose relevant isolated host regressions:
bash scripts/test-host-server.sh
bash scripts/test-host-input.sh
bash scripts/test-host-clipboard.sh
bash scripts/test-host-mic.sh
bash scripts/test-host-timing.sh
bash scripts/test-host-codec.sh
bash scripts/test-host-layout.sh
bash scripts/test-host-app.sh

# Requires a fresh release host build; no real display/TCC session:
python3 scripts/test-host-app-smoke.py
```

For audio changes, also run `bash scripts/test-host-audio.sh` and `bash scripts/test-host-audio-presence.sh`. **Do not run device-mode audio tests casually:** `scripts/test-host-audio.sh --devices` temporarily changes the system output and volume. Installation, restart, actual input hardware, TCC permissions and live audio/video/update tests need separate explicit checks; isolated tests do not prove them.

Full macOS packaging needs **both** HAL components, their complete GPL corresponding source, portable `adb`/NOTICE and Sparkle/public-key inputs. See [packaging instructions](packaging/macos/README.md). Building is not installing, publishing or testing on another Mac. Do not commit generated packages, private keys, credentials or local configuration. Debug-signed Android builds from different environments may have incompatible keys.

## Pull request checklist

- Keep changes focused; describe the problem, implementation and limitations.
- Add a regression test for behavior changes; run the relevant checks and include actual results, not assumed success.
- For live tests, state exact hardware, OS/app versions, transport and settings. Mark untested behavior explicitly.
- Preserve DSXP capability negotiation and legacy-peer behavior; document protocol changes.
- Never log typed text, key codes, clipboard text or audio/video payloads. Redact device/network metadata and private desktop content in attachments.
- For latency claims, state timestamp boundaries and test conditions. `releaseOutputBuffer` is surface submission, **not physical presentation**. Avoid overlapping interval sums, one-screenshot benchmarks and unmeasured touch-to-photon claims.
- Update both READMEs for user-facing changes, keep relative links valid, and preserve MIT/GPL attribution and corresponding-source obligations.

## По-русски

Можно писать issue и PR на русском. Для ошибок нужны точные модель, версии, транспорт и шаги; полезны и успешные проверки совместимости. Для крупных изменений сначала обсудите подход. В PR укажите реально выполненные тесты и отдельно — что не проверялось на устройстве. Не публикуйте секреты, личные данные рабочего стола или необработанные журналы. Пользовательские изменения отражайте в обоих README; правила безопасности и лицензии драйверов сохраняйте.

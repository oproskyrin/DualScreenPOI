# Android codec negotiation verification

## Implemented

- Saved `preferred_codec` setting: HEVC default, H.264 optional. Changing the selection closes the current socket to renegotiate; no `setCodec` command is sent. USB/Wi-Fi endpoint and cancellation model are unchanged.
- Hello advertises dimension-aware MediaCodecList-supported `hevc` / `h264` decoders and the explicit preference. The same query checks actual ack dimensions and selects the decoder component by name.
- Ack codec is strict/canonical. Only a missing field falls back to legacy HEVC, and only when supported. Error/unknown/null/unadvertised/unsupported-size responses terminate negotiation before video/audio delivery, with a visible error rather than endless retries.
- Diagnostics/settings display the actual negotiated codec, separately from the preference.
- Pure Annex-B helper fixes mixed 3-/4-byte delimiter boundaries. AVC uses SPS in csd-0 and PPS in csd-1; HEVC uses ordered VPS/SPS/PPS in csd-0. IDR type 5 and HEVC IRAP types 16–21 are recognized independently of repeated parameter sets. Empty/truncated headers are rejected.

## Actual red/green evidence

Executed with JDK 17 from `android/`:

1. `gradle testDebugUnitTest --tests '*AnnexBTest' --no-daemon -q`: initially missing helper compilation failure, then a deliberate empty-helper stub produced **1 test, 1 failure**. Mixed-boundary implementation: passed.
2. AVC SPS/PPS/IDR test with unimplemented helper methods: **2 tests, 1 failure**. Implementation: passed.
3. Truncated-header regression: **4 tests, 1 failure**. Header bounds fix: passed.
4. Existing real-loopback hello test extended to require codec fields: **1 test, 1 failure**. Hello implementation: passed.
5. Real-loopback error/unsupported/legacy-without-HEVC rejection test: **1 test, 1 failure**. Validation and pre-ack gating: passed with existing protocol/parser tests.
6. Dimension-aware decoder query test with empty stub: **1 test, 1 failure**. Query implementation: passed in full suite.

Additional final regression assertions cover accepted AVC/HEVC, legacy HEVC, saved preference defaults, empty capabilities and actual ack dimensions. These assertions were added after the corresponding implementation; Android Activity/MediaCodec wiring was build/lint checked, not instrumented/TDD verified on-device.

## Final verification

```
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  gradle assembleRelease test lint --no-daemon --console=plain
BUILD SUCCESSFUL in 37s
Debug:   77 tests, 0 failures, 0 errors
Release: 77 tests, 0 failures, 0 errors
Lint: 0 errors, 7 warnings
```

Reports: `app/build/test-results/test{Debug,Release}UnitTest/`, `app/build/reports/lint-results-debug.{html,xml}`.
Full final command output retained at `/Users/oleg/.hermes/cache/scratch/dualscreen-android-codec-verification.log` (scratch, not committed).
APK: `app/build/outputs/apk/release/app-release.apk`.

Warnings: GradleDependency ×2, DiscouragedApi, DataExtractionRules, ObsoleteSdkInt, MonochromeLauncherIcon ×2; SDK XML version mismatch and Gradle deprecation notices also emitted. No dependency/version/signing changes were made.

No install, commits, pushes, version bumps, signing changes, or host/root edits by this Android task. Hardware decoding, saved settings/reconnect UI, USB/Wi-Fi operation and A/B latency were **not** exercised on the tablet. No performance improvement is claimed. The locally signed APK must not replace the canonical CI-signed installed build without separate authorization.

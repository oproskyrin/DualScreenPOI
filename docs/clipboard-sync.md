# DSXP clipboard sync (0x06)

Bidirectional text clipboard between Mac host and Android client. Disabled by
default only when the peer does not advertise it; on both sides the user can
turn it off in settings.

## Capability negotiation

The client adds `"clipboard": true` to the hello JSON (frame 0x00). The host
enables sync only when the flag is present and true. Legacy servers ignore the
unknown field — no sync, no error. The host may also decline (no
implementation): sync simply stays off.

## Frame

    [0x06][u32 BE length][UTF-8 JSON]

```json
{"v": 1, "text": "...", "hash": "16 hex of sha256(text utf-8)"}
```

- Text only in v1 (images/files later); `text` is UTF-8, capped at 1 MiB.
  Oversized payloads are dropped by the receiver with a log line (size only,
  never content).
- `hash` is the first 16 hex chars of `sha256(text)`, used for loop
  suppression, not for security.

## Loop suppression

Both sides keep `lastKnownHash`:

- On local clipboard change: compute hash; if it equals `lastKnownHash`,
  do not send. Otherwise send 0x06 and update `lastKnownHash`.
- On receiving 0x06: if `hash` equals `lastKnownHash`, skip applying (it is the
  echo of a clip we just set). Otherwise apply to the local clipboard and set
  `lastKnownHash = hash`.

This covers both directions with a single variable per side: a programmatic
set updates our own clipboard, the detector sees the new hash, matches
`lastKnownHash` from the incoming frame and stays silent. Rate limit: at most
one outgoing frame per 300 ms; latest clip wins.

## Detection

- Mac: poll `NSPasteboard.general.changeCount` every 700 ms on a utility
  queue. Reading strings: prefer `string(forType: .string)`; ignore empty.
- Android: `ClipboardManager.OnPrimaryClipChangedListener`, gated on streaming
  and the clipboard toggle. Android 10+ restricts clipboard reads to a focused
  app; streaming alone does not prove focus. Incoming text is applied through
  `setPrimaryClip` (failures are caught and logged without content).
- The client does **not** explicitly re-read the clipboard in `onResume` or
  `onWindowFocusChanged`. Returning after copying in another app is therefore
  not a guaranteed catch-up sync. Do not promise a background tablet → Mac
  copy-switch-paste workflow.

## Privacy

Clipboard text is never written to HostLog or ClientLog — only sizes and
hashes. Toast on the tablet shows at most the first 24 characters.

## Tests

- Host: `scripts/test-host-clipboard.sh` (pure loop-suppression core + frame
  round-trip), wired into CI next to the bitrate tests.
- Android: unit tests for hash/dedup core; listener glue is verified live.

## Live status (2026-11-08, v1.5.0)

Verified live over USB: pbcopy on the Mac reaches the tablet (system shows the
clipboard preview bubble); a fake client's 0x06 lands in the Mac pasteboard;
incoming clips produce no echo in either direction.

Tablet → Mac: the listener is gated on a live session, and Android 10+ only
lets the focused app read the clipboard. Copying from another app loses that
focus. A readable change while DualScreen has focus is needed; returning to
the client does not explicitly trigger a re-read. The protocol/send path and
core tests are not proof of a seamless real-device cross-app clipboard flow.
The fake-client Mac pasteboard check above is not an Android focus test.

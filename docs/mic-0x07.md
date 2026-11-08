# DSXP microphone (0x07) — tablet mic as a Mac input device

The tablet's microphone becomes an input device on the Mac, like the existing
tablet-audio output HAL but in the opposite direction. Status: implemented on
the Mac side (FrameServer 0x07 routing, MicInputRoute, DualScreenMic HAL
variant, packaging, tests); Android side pending.

## Frame

    [0x07][u32 BE length][raw PCM16LE mono 48 kHz]

- No codec: mic speech at 48 kHz mono 16-bit is ~768 kbit/s, cheap over USB
  and Wi-Fi.
- Frames carry ~20 ms of audio (1920 bytes). Batch a few samples per send;
  do not wait for full buffers longer than 60 ms.
- Capability flag `"mic": true` in the client hello, same rules as
  `"clipboard"`: legacy peers ignore it; the host enables the feature only
  when the flag is present and true.

## Mac side — input HAL "DualScreenMic"

- Second HAL variant built from the same BlackHole-derived sources as
  `DualScreenAudio` (scripts/build-dualscreen-audio.sh --mic), UID
  `DualScreenMic_UID`, device name «Xiaoxin Pad Pro 12.7», mono 48 kHz.
  Coexists with the output HAL: distinct bundle id
  `com.dualscreen.audio.driver.mic` and presence notify name
  `com.oleg.dualscreen.host.mic-pid`.
- Ring feed: a BlackHole-derived ring is only written by output IO, so the mic
  variant keeps an output stream as the host feed path and the host plays the
  received PCM into the device through ordinary CoreAudio (AudioUnit HAL
  output, MicInputRoute/MicHALWriter) — never direct coreaudiod access. Both
  default-device properties refuse the output scope, so the device is
  selectable as an input (and default input) but never as a default output.
- Presence follows the same Darwin-notify heartbeat contract as the output
  HAL: device appears while the host runs, disappears on exit/crash.
- The host drops 0x07 frames silently when mic is not negotiated, when no HAL
  is loaded, or when the ring is full; it never blocks the frame reader.
- Exclusive routing is NOT the goal: the mic device is just selectable as an
  input, macOS default-input switching is left to the user (sound settings),
  same as any USB mic.

## Android side

- `AudioRecord` (VOICE_COMMUNICATION default, 48 kHz mono PCM16, ~20 ms
  frames) started when the session negotiates mic=true and the user enabled
  the toggle «Передавать микрофон» (default OFF — recording indicator and
  privacy); stopped on disconnect/toggle.
- Sends 0x07 through the executor path. REQUIRES RECORD_AUDIO runtime
  permission: request when the user first enables the toggle; without it the
  toggle stays off with a hint.

## Host routing

- 0x07 → ring buffer write. Drop silently when the client did not advertise
  mic, when no HAL is loaded, or when the buffer is full (never block the
  read loop).
- HostLog records sizes/drop events only — no PCM.

## Privacy

Recording only happens when the user explicitly enables the toggle (runtime
permission first). No audio bytes in logs.

## Live status (2026-11-08, v1.6.0)

End-to-end verified on TB371FC over USB: a 440 Hz tone played on the Mac
(routes through the tablet output HAL to the speakers) was picked up by the
tablet microphone, streamed as 0x07 (receivedBytes ~234 KB for 5 s), written
into the DualScreenMic ring, and captured on the Mac via AVFoundation
(RMS −30.6 dB against a −inf silent baseline). Mic device appears as
"Xiaoxin Pad Pro 12.7" (UID DualScreenMic_UID) alongside the output HAL.

Deployment notes: the mic HAL pkg (dist/DualScreenMic/DualScreenMic-*.pkg)
installs with admin rights and restarts coreaudiod; the host sink re-scans
for the UID per callback, so no host restart is needed after installation.

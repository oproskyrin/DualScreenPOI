# Security / Безопасность

## Current trust boundary

DualScreen is a **public beta for trusted local environments**, not a secure remote desktop service.

- DSXP uses TCP (default **7381**) with **no pairing, authentication or transport encryption**.
- A peer able to reach the host listener can attempt to obtain screen/audio, inject Mac input, exchange clipboard text or submit microphone audio. Mac permissions and client settings are not a network authentication boundary.
- USB uses `adb reverse`; choosing USB does not necessarily disable the host's network listener. Authorize USB debugging only for computers you control.
- Do not expose the port through a router, tunnel or public/shared Wi-Fi. Use a network whose participants you trust and restrict inbound reachability. A network being called “home” does not make every peer trustworthy.
- Clipboard sharing can expose copied secrets. Mic forwarding is opt-in, requires Android permission and saves the enabled preference; disable it when not needed. A visible Mac mic HAL device follows host availability and does not by itself prove live recording.

Default package builds are **not Developer ID signed or Apple-notarized**: the app is ad-hoc signed and the installer unsigned unless identities are explicitly supplied. A maintainer's local certificate does not establish trust on your Mac. Do not disable Gatekeeper/SIP or install a foreign local signing certificate to bypass warnings. Sparkle Ed25519 verification protects the update feed/archive; it is not notarization or protocol authentication. Android release builds currently use the build environment's debug signing key; do not assume a stable production signing identity across build sources.

## Reporting a vulnerability

Do **not** put sensitive exploit details, tokens, private logs or desktop captures in a public issue.

Use the repository's **Security → Report a vulnerability** private reporting option **if it is available**. If it is unavailable, open a public issue containing only a request for a private security contact—no exploit details—and wait for a maintainer to arrange a channel. Do not assume a private email address or reporting service exists.

Include affected versions, platform/device, required network access or permissions, minimal reproduction, expected impact and a suggested mitigation if known. Review attachments for device addresses, usernames, clipboard hashes and private desktop data. No response-time SLA, bug bounty or support window for older versions is promised. Test only systems you own or have permission to assess.

## Кратко по-русски

Это бета для доверенной локальной среды. У DSXP нет пейринга, аутентификации и шифрования; доступ к TCP 7381 может дать доступ к трансляции и вводу. USB не гарантирует отключения сетевого порта. Не открывайте порт наружу, не используйте общую/публичную сеть, доверяйте отладку USB только своим компьютерам. Не отключайте защиту macOS ради установки. Подпись обновлений Sparkle не заменяет нотарификацию Apple и защиту протокола.

Об уязвимости сообщайте приватно через **Security → Report a vulnerability**, если кнопка доступна. Иначе создайте issue только с просьбой о приватном контакте, **без описания эксплуатации и чувствительных данных**. Срок ответа и поддержка старых версий не гарантированы.

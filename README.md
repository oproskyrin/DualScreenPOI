# DualScreen — планшет как второй монитор Mac

Своё решение без сторонних сервисов: Android-планшет становится полноценным
**расширенным** дисплеем macOS по USB-C или Wi-Fi, с нативным разрешением
и высокой частотой обновления.

Целевое устройство: **Lenovo Xiaoxin Pad Pro 12.7 (TB371FC)** — 2944×1840, 144 Гц,
Snapdragon 870 (аппаратный HEVC), Android 13. Работает с любым планшетом
Android 8+ с аппаратным HEVC/H.264-декодером.

## Архитектура

```
Mac (DualScreenHost)                          Android (DualScreenClient)
┌─────────────────────────────┐               ┌──────────────────────────┐
│ CGVirtualDisplay (private)  │               │ MediaCodec HEVC (low-lat)│
│   2944×1840@144 + HiDPI     │               │   → SurfaceView          │
│ ScreenCaptureKit (NV12)     │   HEVC over   │   нативное разрешение,   │
│ VideoToolbox HEVC realtime  │ ────────────► │   preferredDisplayModeId │
│ CGEvent (тач → курсор)      │ ◄──────────── │  (144/120/90/60 Гц)      │
└─────────────────────────────┘  JSON input   └──────────────────────────┘
        TCP 7381 (DSXP v1)
   USB: adb reverse | Wi-Fi: напрямую
```

## Протокол DSXP v1

TCP, фрейм: `[u8 type][u32 BE length][payload]`

| type | направление | содержимое |
|------|-------------|------------|
| 0x00 | клиент → сервер | hello JSON: `{"magic":"DSXP","version":1,"width":W,"height":H,"maxRefresh":R}` |
| 0x00 | сервер → клиент | ack JSON: `{"ok":true,"width":W,"height":H,"fps":F,"bitrate":B,"codec":"hevc"}` |
| 0x01 | сервер → клиент | Annex-B HEVC access unit (VPS/SPS/PPS инлайнятся в каждом keyframe) |
| 0x02 | клиент → сервер | input JSON: `{"t":"move\|down\|drag\|up\|right\|scroll","x":0..1,"y":0..1,"dx":…,"dy":…}` |
| 0x03 | обе стороны | stats JSON |

## Использование

### Mac-хост

Требования: macOS 13+, Apple Silicon, Command Line Tools (`xcode-select --install`), `adb` (`brew install android-platform-tools`).

```bash
cd host
swift build -c release
.build/release/DualScreenHost [--width 2944] [--height 1840] [--fps 120] \
    [--bitrate 80] [--port 7381] [--no-hidpi]
```

При первом запуске macOS запросит «Запись экрана» — разрешить
(Системные настройки → Конфиденциальность и безопасность → Запись экрана).

**USB-автопилот**: если `adb` установлен и планшет воткнут с включённой
отладкой, хост сам делает `adb reverse` и запускает приложение — воткнул
кабель, через пару секунд второй экран работает. Ручной режим для Wi-Fi:
в приложении указать IP мака (`ipconfig getifaddr en0`).

**Масштаб**: по умолчанию `--hidpi` = логический размер 1472×920 (элементы
нормальные). `--no-hidpi` = нативные 2944×1840 1:1 (мелко, но максимум места
и пиксель-в-пиксель).

### Android-клиент

```bash
cd android && ./gradlew assembleRelease
adb install app/build/outputs/apk/release/app-release.apk
```

Жесты: тап/драг — курсор и клики; два пальца — скролл; тап двумя пальцами
или долгое нажатие — правый клик; кнопка ⌨ — клавиатура Mac (ввод текста,
backspace/enter). Переподключение — автоматическое.

### Подключение

**USB (минимальная задержка):**
```bash
adb reverse tcp:7381 tcp:7381   # после включения отладки по USB
```
В приложении адрес `127.0.0.1:7381`.

**Wi-Fi:** оба устройства в одной сети (лучше 5 ГГц), в приложении указать IP мака
(`ipconfig getifaddr en0`).

## Статус

- [x] Mac-хост: виртуальный дисплей, захват, HEVC, TCP-сервер, инъекция ввода
- [x] Android-клиент: декод, тач, выбор герцовки
- [x] Проверено сквозным тестом на Lenovo Xiaoxin Pad Pro 12.7 (TB371FC) по USB
- [ ] Стабилизация, авто-переподключение, звук

## Известные ограничения

- CGVirtualDisplay — приватный API; может сломаться в будущих macOS.
- Частота кадров потока ≤ 120 fps (задаётся `--fps`); панель планшета при
  этом работает на своей полной частоте.
- HiDPI: по умолчанию логическое разрешение = нативному (2944×1840),
  `--no-hidpi` не влияет на размер элементов (см. TODO: выбор масштаба).

## Лицензия

MIT

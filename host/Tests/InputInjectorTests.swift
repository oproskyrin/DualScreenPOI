import Foundation
import CoreGraphics
import Carbon.HIToolbox

@main enum InputTests {
    static func main() {
        var events: [CGEvent] = []
        let input = InputInjector(bounds: CGRect(x: -100, y: 20, width: 1000, height: 600), eventSink: { events.append($0) })
        func key(_ code: Int, _ down: Bool = true, _ meta: Int = 0, _ repeatCount: Int = 0, _ text: String? = nil) {
            var json: [String: Any] = ["t":"hardwareKey", "code":code, "down":down, "repeat":repeatCount, "meta":meta]
            json["text"] = text
            input.handle(json)
        }
        func pointer(_ action: String, _ button: String = "left", _ meta: Int = 0) {
            input.handle(["t":"pointer", "action":action, "button":button, "x":0.5, "y":0.5, "meta":meta])
        }
        func clear() { input.reset(); events.removeAll() }
        func unicode(_ event: CGEvent) -> String {
            var units = [UniChar](repeating: 0, count: 64)
            var length = 0
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
            return String(decoding: units.prefix(length), as: UTF16.self)
        }
        key(29, true, 0, 0, "я😀")
        assert(events.count == 1 && events[0].type == .keyDown, "no automatic tap")
        assert(events[0].getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_A))
        assert(unicode(events[0]) == "я😀")
        key(29, true, 0, 1, "я😀")
        assert(events.count == 2 && events.last!.getIntegerValueField(.keyboardEventAutorepeat) == 1)
        key(29, true)
        assert(events.count == 2, "duplicate nonrepeat down ignored")
        key(29, false)
        key(29, false)
        assert(events.count == 3 && events.last!.type == .keyUp)
        clear()
        key(117, true, 0x10000)
        key(31, true, 0x10000, 0, "wrong")
        assert(events.count == 2 && events[0].type == .flagsChanged)
        assert(events[1].flags.contains(.maskCommand) && !events[1].flags.contains(.maskControl))
        assert(unicode(events[1]) != "wrong", "shortcut must use virtual key, not Unicode")
        input.reset()
        assert(events.count == 4 && events[2].type == .keyUp && events[3].type == .flagsChanged)
        assert(!events[3].flags.contains(.maskCommand))
        input.reset()
        assert(events.count == 4)
        clear()
        key(113, true, 0x1000)
        key(29, true, 0x1000)
        assert(events.last!.flags.contains(.maskControl) && !events.last!.flags.contains(.maskCommand))
        clear()
        key(59, true, 1); key(60, true, 1)
        key(59, false, 1)
        assert(events.last!.flags.contains(.maskShift), "other Shift still held")
        key(60, false, 1)
        assert(!events.last!.flags.contains(.maskShift), "stale up meta must not stick")
        clear()
        for button in ["left", "right", "middle"] {
            pointer("down", button); pointer("move", button); pointer("up", button); pointer("up", button)
        }
        assert(events.map(\.type) == [.leftMouseDown,.leftMouseDragged,.leftMouseUp,.rightMouseDown,.rightMouseDragged,.rightMouseUp,.otherMouseDown,.otherMouseDragged,.otherMouseUp])
        assert(events[3].getIntegerValueField(.mouseEventButtonNumber) == 1)
        assert(events[6].getIntegerValueField(.mouseEventButtonNumber) == 2)
        assert(events[0].location == CGPoint(x:400,y:320))
        clear()
        pointer("down", "right", 0x2)
        input.reset()
        assert(events.count == 2 && events[1].type == .rightMouseUp)
        input.reset(); assert(events.count == 2)
        clear()
        input.handle(["t":"pointer","action":"move","x":-3.0,"y":4.0])
        assert(events.last!.location == CGPoint(x:-100,y:620))
        for x in [Double.nan, Double.infinity, -Double.infinity] {
            input.handle(["t":"pointer","action":"down","x":x,"y":0.2])
            input.handle(["t":"scroll","dx":x,"dy":1.0])
        }
        assert(events.count == 1)
        input.handle(["t":"pointer","action":"move","x":true,"y":0.1])
        input.handle(["t":"pointer","action":"move","x":"0.1","y":0.1])
        assert(events.count == 1)
        clear()
        input.handle(["t":"pointer","action":"scroll","x":0.2,"y":0.5,"dx":1e300,"dy":-1e300,"meta":0x10000])
        assert(events.count == 1 && events[0].type == .scrollWheel)
        assert(events[0].location == CGPoint(x:100,y:320), "pointer scroll targets normalized stream position")
        assert(events[0].flags.contains(.maskCommand))
        assert(abs(events[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) <= 16384)
        clear()
        for bad: Any in [true, 29.5, Double.infinity, "29"] {
            input.handle(["t":"hardwareKey","code":bad,"down":true,"repeat":0,"meta":0])
        }
        input.handle(["t":"hardwareKey","code":29,"down":1,"repeat":0,"meta":0])
        key(9999); key(29, true, -1); key(29, true, 0, -1)
        assert(events.isEmpty)
        key(29, true, 0, 0, String(repeating:"x",count:17))
        assert(unicode(events.last!) != String(repeating:"x",count:17))
        clear()
        input.handle(["t":"key","ch":"hello"])
        assert(events.count == 2 && unicode(events[0]) == "hello")
        input.handle(["t":"key","special":"backspace"])
        assert(events.count == 4 && events[2].getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Delete))
        clear()
        input.handle(["t":"down","x":0.1,"y":0.2]); input.handle(["t":"drag","x":0.2,"y":0.3]); input.handle(["t":"up","x":0.2,"y":0.3])
        assert(events.map(\.type) == [.leftMouseDown,.leftMouseDragged,.leftMouseUp])
        assert(InputInjector.keyMap[119] == CGKeyCode(kVK_Function), "Android Function maps to Mac Fn")
        assert(InputInjector.metaFlags(8).contains(.maskSecondaryFn))
        assert(InputInjector.keyMap[122] == CGKeyCode(kVK_Home) && InputInjector.keyMap[3] == nil)
        assert(InputInjector.keyMap[112] == CGKeyCode(kVK_ForwardDelete))
        assert(InputInjector.keyMap[143] == CGKeyCode(kVK_ANSI_KeypadClear))
        assert(InputInjector.keyMap[131] == CGKeyCode(kVK_F1) && InputInjector.keyMap[142] == CGKeyCode(kVK_F12))
        assert(InputInjector.keyMap[144] == CGKeyCode(kVK_ANSI_Keypad0) && InputInjector.keyMap[160] == CGKeyCode(kVK_ANSI_KeypadEnter))
        clear()
        key(115, true, 0x100000)
        assert(events.last!.type == .flagsChanged, "CapsLock uses modifier event")
        print("PASS host input: key lifecycle, Unicode, shortcuts, modifiers, mouse buttons/drag, reset, validation, legacy and SDK mappings")
    }
}

import Foundation
import CoreGraphics
import CoreFoundation

/// DSXP input state. All access is serialized on main by HostApp; tests inject
/// geometry and a sink and never post events or query a live display.
final class InputInjector {
    private let displayID: CGDirectDisplayID?
    private var bounds: CGRect
    private let eventSink: (CGEvent) -> Void
    private var keys: Set<Int> = []
    private var buttons: Set<Int> = []
    private var flags: CGEventFlags = []
    private var lastPoint = CGPoint.zero

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        bounds = CGDisplayBounds(displayID)
        eventSink = { $0.post(tap: .cghidEventTap) }
    }

    init(bounds: CGRect, eventSink: @escaping (CGEvent) -> Void) {
        displayID = nil
        self.bounds = bounds
        self.eventSink = eventSink
    }

    func refreshBounds() {
        if let displayID { bounds = CGDisplayBounds(displayID) }
    }

    func handle(_ json: [String: Any]) {
        guard let type = json["t"] as? String else { return }
        switch type {
        case "hardwareKey": hardwareKey(json)
        case "pointer": pointer(json)
        case "inputReset": reset()
        // Legacy touchscreen/soft-keyboard protocol remains a tap/text API.
        case "move":
            if let p = point(json) { mouse(.mouseMoved, at: p, button: 0, clicks: 0) }
        case "down":
            if let p = point(json) { buttons.insert(0); mouse(.leftMouseDown, at: p, button: 0) }
        case "drag":
            if buttons.contains(0), let p = point(json) { mouse(.leftMouseDragged, at: p, button: 0) }
        case "up":
            if let p = point(json) { mouse(.leftMouseUp, at: p, button: 0) }
            buttons.remove(0)
        case "right":
            if let p = point(json) {
                mouse(.rightMouseDown, at: p, button: 1)
                mouse(.rightMouseUp, at: p, button: 1)
            }
        case "scroll": scroll(json, eventFlags: [])
        case "key":
            if let ch = json["ch"] as? String, !ch.isEmpty {
                for down in [true, false] { keyboard(0, down: down, text: ch, eventFlags: []) }
            } else if let special = json["special"] as? String,
                      let key = Self.specialKeys[special] {
                for down in [true, false] { keyboard(key, down: down, eventFlags: []) }
            }
        default: break
        }
    }

    /// Release normal keys before modifiers, then buttons, then each modifier.
    /// Never synthesize a shortcut tap or a second up for an already-up input.
    func reset() {
        for code in keys.sorted() where Self.modifier(code) == nil {
            if let key = Self.keyMap[code] { keyboard(key, down: false, eventFlags: flags) }
        }
        for button in buttons.sorted() {
            mouse(Self.mouseType(button, down: false), at: lastPoint, button: button)
        }
        buttons.removeAll()
        keys = keys.filter { Self.modifier($0) != nil }
        for code in keys.sorted() {
            keys.remove(code)
            flags = heldModifierFlags()
            keyboard(Self.keyMap[code]!, down: false, modifier: true, eventFlags: flags)
        }
        keys.removeAll()
        flags = []
    }

    private func hardwareKey(_ json: [String: Any]) {
        guard let code = Self.integer(json["code"]), let key = Self.keyMap[code],
              let value = json["down"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(),
              let count = Self.integer(json["repeat"]), count >= 0,
              let meta = Self.integer(json["meta"]), meta >= 0 else { return }
        let down = value.boolValue
        if !down && !keys.contains(code) { return }
        if down && keys.contains(code) && (count == 0 || Self.modifier(code) != nil) { return }
        if down { keys.insert(code) } else { keys.remove(code) }
        flags = Self.metaFlags(meta)
        let modifier = Self.modifier(code)
        if let modifier {
            // Android may report the pre-release meta state on the up event.
            // For the changing modifier family, physical held keys are truth.
            flags.remove(modifier)
        }
        flags.formUnion(heldModifierFlags())
        var text: String?
        if down, modifier == nil, !flags.contains(.maskControl),
           !flags.contains(.maskAlternate), !flags.contains(.maskCommand),
           let candidate = json["text"] as? String, !candidate.isEmpty,
           candidate.utf16.count <= 16,
           candidate.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            text = candidate
        }
        keyboard(key, down: down, modifier: modifier != nil, repeatCount: down ? count : 0,
                 text: text, eventFlags: flags)
    }

    private func heldModifierFlags() -> CGEventFlags {
        keys.reduce(into: CGEventFlags()) { result, code in
            if let flag = Self.modifier(code) { result.formUnion(flag) }
        }
    }

    private func pointer(_ json: [String: Any]) {
        guard let action = json["action"] as? String, let p = point(json) else { return }
        var eventFlags = flags
        if let value = json["meta"] {
            guard let meta = Self.integer(value), meta >= 0 else { return }
            eventFlags = Self.metaFlags(meta).union(heldModifierFlags())
        }
        if action == "scroll" { scroll(json, eventFlags: eventFlags, at: p); return }
        let button: Int
        switch json["button"] as? String ?? "left" {
        case "left": button = 0
        case "right": button = 1
        case "middle": button = 2
        default: return
        }
        switch action {
        case "move":
            let held = buttons.sorted().first
            let kind: CGEventType = held == 0 ? .leftMouseDragged : held == 1 ? .rightMouseDragged : held == 2 ? .otherMouseDragged : .mouseMoved
            mouse(kind, at: p, button: held ?? button, clicks: 0, eventFlags: eventFlags)
        case "down":
            guard buttons.insert(button).inserted else { return }
            mouse(Self.mouseType(button, down: true), at: p, button: button, eventFlags: eventFlags)
        case "up":
            guard buttons.remove(button) != nil else { return }
            mouse(Self.mouseType(button, down: false), at: p, button: button, eventFlags: eventFlags)
        default: break
        }
    }

    private static func mouseType(_ button: Int, down: Bool) -> CGEventType {
        button == 0 ? (down ? .leftMouseDown : .leftMouseUp) :
        button == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
    }

    private func keyboard(_ key: CGKeyCode, down: Bool, modifier: Bool = false,
                          repeatCount: Int = 0, text: String? = nil, eventFlags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
        if modifier { event.type = .flagsChanged }
        event.flags = eventFlags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatCount > 0 ? 1 : 0)
        if let text {
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
        }
        eventSink(event)
    }

    private func point(_ json: [String: Any]) -> CGPoint? {
        guard let x = Self.number(json["x"]), let y = Self.number(json["y"]),
              bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite,
              bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let p = CGPoint(x: bounds.minX + min(1, max(0, x)) * bounds.width,
                        y: bounds.minY + min(1, max(0, y)) * bounds.height)
        return p.x.isFinite && p.y.isFinite ? p : nil
    }

    private func mouse(_ kind: CGEventType, at p: CGPoint, button: Int, clicks: Int = 1,
                       eventFlags: CGEventFlags? = nil) {
        guard let b = CGMouseButton(rawValue: UInt32(button)),
              let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: p, mouseButton: b) else { return }
        event.flags = eventFlags ?? flags
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        lastPoint = p
        eventSink(event)
    }

    private func scroll(_ json: [String: Any], eventFlags: CGEventFlags, at point: CGPoint? = nil) {
        guard let dx = Self.number(json["dx"] ?? 0), let dy = Self.number(json["dy"] ?? 0) else { return }
        // Legacy ticks * 16 pixels, bounded before conversion (even 1e300 is safe).
        let x = Int32(-min(1024, max(-1024, dx)) * 16)
        let y = Int32(-min(1024, max(-1024, dy)) * 16)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: y, wheel2: x, wheel3: 0) else { return }
        event.flags = eventFlags
        if let point { event.location = point; lastPoint = point }
        eventSink(event)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let n = number(value), n.rounded(.towardZero) == n else { return nil }
        return Int(exactly: n)
    }

    // Android KeyEvent meta constants; Meta is Command, never Ctrl->Command.
    static func metaFlags(_ meta: Int) -> CGEventFlags {
        var result: CGEventFlags = []
        if meta & 0x000000c1 != 0 { result.insert(.maskShift) }
        if meta & 0x00000032 != 0 { result.insert(.maskAlternate) }
        if meta & 0x00007000 != 0 { result.insert(.maskControl) }
        if meta & 0x00070000 != 0 { result.insert(.maskCommand) }
        if meta & 0x00100000 != 0 { result.insert(.maskAlphaShift) }
        if meta & 0x00000008 != 0 { result.insert(.maskSecondaryFn) }
        return result
    }

    private static func modifier(_ code: Int) -> CGEventFlags? {
        switch code {
        case 59, 60: return .maskShift
        case 57, 58: return .maskAlternate
        case 113, 114: return .maskControl
        case 117, 118: return .maskCommand
        case 119: return .maskSecondaryFn
        default: return nil
        }
    }

    private static let specialKeys: [String: CGKeyCode] = [
        "backspace": 0x33, "enter": 0x24, "tab": 0x30, "esc": 0x35,
        "left": 0x7b, "right": 0x7c, "down": 0x7d, "up": 0x7e,
        "delete": 0x75, "home": 0x73, "end": 0x77,
    ]

    // Android: frameworks/base/core/java/android/view/KeyEvent.java (AOSP).
    // Mac: installed SDK Carbon/HIToolbox/Events.h kVK_* constants.
    // Android HOME=3 is system navigation, NOT MOVE_HOME=122.
    static let keyMap: [Int: CGKeyCode] = {
        var m: [Int: CGKeyCode] = [:]
        let letters: [CGKeyCode] = [0x00,0x0b,0x08,0x02,0x0e,0x03,0x05,0x04,0x22,0x26,0x28,0x25,0x2e,0x2d,0x1f,0x23,0x0c,0x0f,0x01,0x11,0x20,0x09,0x0d,0x07,0x10,0x06]
        for (i, key) in letters.enumerated() { m[29 + i] = key }
        let digits: [CGKeyCode] = [0x1d,0x12,0x13,0x14,0x15,0x17,0x16,0x1a,0x1c,0x19]
        for (i, key) in digits.enumerated() { m[7 + i] = key }
        let functions: [CGKeyCode] = [0x7a,0x78,0x63,0x76,0x60,0x61,0x62,0x64,0x65,0x6d,0x67,0x6f]
        for (i, key) in functions.enumerated() { m[131 + i] = key }
        let keypad: [CGKeyCode] = [0x52,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5b,0x5c]
        for (i, key) in keypad.enumerated() { m[144 + i] = key }
        let other: [Int: CGKeyCode] = [
            19:0x7e,20:0x7d,21:0x7b,22:0x7c,
            55:0x2b,56:0x2f,57:0x3a,58:0x3d,59:0x38,60:0x3c,
            61:0x30,62:0x31,66:0x24,67:0x33,68:0x32,69:0x1b,
            70:0x18,71:0x21,72:0x1e,73:0x2a,74:0x29,75:0x27,76:0x2c,
            92:0x74,93:0x79,111:0x35,112:0x75,113:0x3b,114:0x3e,
            115:0x39,117:0x37,118:0x36,119:0x3f,122:0x73,123:0x77,124:0x72,
            143:0x47,154:0x4b,155:0x43,156:0x4e,157:0x45,
            158:0x41,159:0x5f,160:0x4c,161:0x51,
        ]
        m.merge(other) { _, new in new }
        return m
    }()
}

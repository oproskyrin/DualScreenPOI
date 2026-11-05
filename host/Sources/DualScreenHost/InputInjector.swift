import Foundation
import CoreGraphics

/// Translates tablet touch events (JSON from the client, coordinates
/// normalized 0..1 within the virtual display) into macOS CGEvents.
final class InputInjector {
    private let displayID: CGDirectDisplayID
    private var bounds: CGRect
    private var dragging = false

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.bounds = CGDisplayBounds(displayID)
    }

    func refreshBounds() {
        bounds = CGDisplayBounds(displayID)
    }

    func handle(_ json: [String: Any]) {
        guard let type = json["t"] as? String else { return }
        switch type {
        case "move":
            if let p = point(json) { postMouse(.mouseMoved, at: p, clickCount: 0) }
        case "down":
            if let p = point(json) { postMouse(.leftMouseDown, at: p, clickCount: 1); dragging = true }
        case "drag":
            if dragging, let p = point(json) { postMouse(.leftMouseDragged, at: p, clickCount: 1) }
        case "up":
            if let p = point(json) { postMouse(.leftMouseUp, at: p, clickCount: 1) }
            dragging = false
        case "right":
            if let p = point(json) {
                postMouse(.rightMouseDown, at: p, clickCount: 1)
                postMouse(.rightMouseUp, at: p, clickCount: 1)
            }
        case "scroll":
            let dx = json["dx"] as? Double ?? 0
            let dy = json["dy"] as? Double ?? 0
            postScroll(dx: dx, dy: dy)
        case "key":
            if let ch = json["ch"] as? String, !ch.isEmpty {
                postUnicode(ch)
            } else if let special = json["special"] as? String {
                postSpecialKey(special)
            }
        default:
            break
        }
    }

    // MARK: keyboard

    private func postUnicode(_ string: String) {
        let utf16 = Array(string.utf16)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        utf16.withUnsafeBufferPointer { buf in
            for event in [down, up] {
                event?.keyboardSetUnicodeString(stringLength: utf16.count,
                                                unicodeString: buf.baseAddress)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// macOS virtual key codes for the special keys the tablet sends.
    private static let specialKeys: [String: (vkey: CGKeyCode, withShift: Bool)] = [
        "backspace": (0x33, false),
        "enter": (0x24, false),
        "tab": (0x30, false),
        "esc": (0x35, false),
        "left": (0x7B, false),
        "right": (0x7C, false),
        "down": (0x7D, false),
        "up": (0x7E, false),
        "delete": (0x75, false),
        "home": (0x73, false),
        "end": (0x77, false),
    ]

    private func postSpecialKey(_ name: String) {
        guard let key = Self.specialKeys[name] else { return }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: key.vkey, keyDown: down)
            if key.withShift { e?.flags = .maskShift }
            e?.post(tap: .cghidEventTap)
        }
    }

    private func point(_ json: [String: Any]) -> CGPoint? {
        guard let x = json["x"] as? Double, let y = json["y"] as? Double else { return nil }
        return CGPoint(
            x: bounds.minX + CGFloat(x) * bounds.width,
            y: bounds.minY + CGFloat(y) * bounds.height
        )
    }

    private func postMouse(_ kind: CGEventType, at p: CGPoint, clickCount: Int) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: kind,
                                  mouseCursorPosition: p, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(dx: Double, dy: Double) {
        // Tablet deltas arrive in "ticks": +/- 1 per gesture step.
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(-dy * 16),
                                  wheel2: Int32(-dx * 16),
                                  wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }
}

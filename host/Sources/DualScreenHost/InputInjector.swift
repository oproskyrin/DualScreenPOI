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
        default:
            break
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

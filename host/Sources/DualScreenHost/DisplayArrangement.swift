import Foundation
import CoreGraphics

struct SavedDisplayPlacement: Codable, Equatable {
    enum Edge: String, Codable { case leading, trailing }
    let anchorKey: String
    let dx: CGFloat
    let dy: CGFloat
    let horizontalEdge: Edge?
    let verticalEdge: Edge?

    init(anchorKey: String, anchor: CGRect, tablet: CGRect) {
        self.anchorKey = anchorKey
        dx = tablet.minX - anchor.minX
        dy = tablet.minY - anchor.minY
        horizontalEdge = abs(tablet.maxX - anchor.minX) < 2 ? .leading :
            (abs(tablet.minX - anchor.maxX) < 2 ? .trailing : nil)
        verticalEdge = abs(tablet.maxY - anchor.minY) < 2 ? .leading :
            (abs(tablet.minY - anchor.maxY) < 2 ? .trailing : nil)
    }

    func origin(anchor: CGRect, tabletSize: CGSize) -> CGPoint {
        var x = anchor.minX + dx, y = anchor.minY + dy
        if horizontalEdge == .leading { x = anchor.minX - tabletSize.width }
        if horizontalEdge == .trailing { x = anchor.maxX }
        if verticalEdge == .leading { y = anchor.minY - tabletSize.height }
        if verticalEdge == .trailing { y = anchor.maxY }
        return CGPoint(x: x, y: y)
    }
}

/// Pure geometry selection; a corner contact alone is not adjacency.
struct DisplayPlacementAnchor {
    let id: CGDirectDisplayID
    let key: String
    let bounds: CGRect

    static func select(tablet: CGRect, candidates: [Self], preferredID: CGDirectDisplayID) -> Self? {
        let touching = candidates.compactMap { candidate -> (Self, CGFloat)? in
            let anchor = candidate.bounds
            guard tablet.width > 0, tablet.height > 0, anchor.width > 0, anchor.height > 0 else { return nil }
            let overlapX = max(0, min(tablet.maxX, anchor.maxX) - max(tablet.minX, anchor.minX))
            let overlapY = max(0, min(tablet.maxY, anchor.maxY) - max(tablet.minY, anchor.minY))
            let side = abs(tablet.maxX - anchor.minX) < 2 || abs(tablet.minX - anchor.maxX) < 2
            let topBottom = abs(tablet.maxY - anchor.minY) < 2 || abs(tablet.minY - anchor.maxY) < 2
            let sharedEdge = max(side ? overlapY : 0, topBottom ? overlapX : 0)
            return sharedEdge > 0 ? (candidate, sharedEdge) : nil
        }
        if let preferred = touching.first(where: { $0.0.id == preferredID }) { return preferred.0 }
        return touching.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.key != $1.0.key { return $0.0.key < $1.0.key }
            return $0.0.id < $1.0.id
        }.first?.0
    }
}

final class DisplayPlacementStore {
    private let defaults: UserDefaults
    private let key = "tabletDisplayPlacement.v1"
    init(defaults: UserDefaults = AppRuntimePolicy.sharedDefaults()) {
        self.defaults = defaults
    }
    func load() -> SavedDisplayPlacement? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedDisplayPlacement.self, from: data)
    }
    func save(_ placement: SavedDisplayPlacement) {
        guard placement != load(), let data = try? JSONEncoder().encode(placement) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }
}

/// Main-thread owner. Saves settled macOS layout changes, not transient creation
/// states. Positions are relative to a physical anchor, never an ephemeral CG ID.
final class DisplayArrangement {
    struct Environment {
        var displays: () -> [CGDirectDisplayID]
        var bounds: (CGDirectDisplayID) -> CGRect
        var key: (CGDirectDisplayID) -> String
        var isBuiltin: (CGDirectDisplayID) -> Bool
        var mainDisplay: () -> CGDirectDisplayID
        var isMirrored: (CGDirectDisplayID) -> Bool
        var moveOrigin: (CGDirectDisplayID, CGPoint) -> CGError
        var observe: (DisplayArrangement) -> Void
        var stopObserving: (DisplayArrangement) -> Void

        static let live = Environment(
            displays: {
                var count: UInt32 = 0
                guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
                var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
                guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
                return Array(ids.prefix(Int(count)))
            }, bounds: { CGDisplayBounds($0) },
            key: { "\(CGDisplayVendorNumber($0)):\(CGDisplayModelNumber($0)):\(CGDisplaySerialNumber($0)):\(CGDisplayIsBuiltin($0))" },
            isBuiltin: { CGDisplayIsBuiltin($0) != 0 }, mainDisplay: { CGMainDisplayID() },
            isMirrored: { CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay },
            moveOrigin: { id, origin in
                var configuration: CGDisplayConfigRef?
                let begin = CGBeginDisplayConfiguration(&configuration)
                guard begin == .success else {
                    print("[display] begin configuration failed: \(begin.rawValue)")
                    return begin
                }
                let move = CGConfigureDisplayOrigin(configuration, id, Int32(origin.x), Int32(origin.y))
                guard move == .success else {
                    print("[display] configure origin failed: \(move.rawValue)")
                    CGCancelDisplayConfiguration(configuration)
                    return move
                }
                let result = CGCompleteDisplayConfiguration(configuration, .forSession)
                if result != .success { print("[display] complete configuration failed: \(result.rawValue)") }
                return result
            }, observe: {
                CGDisplayRegisterReconfigurationCallback(callback, Unmanaged.passUnretained($0).toOpaque())
            }, stopObserving: {
                CGDisplayRemoveReconfigurationCallback(callback, Unmanaged.passUnretained($0).toOpaque())
            })
    }

    private let store: DisplayPlacementStore
    private let environment: Environment
    private var displayID: CGDirectDisplayID = 0
    private var anchorID: CGDirectDisplayID = 0
    private var attachmentSucceeded = false
    private var observing = false
    private var pendingSave: DispatchWorkItem?
    var onChange: (() -> Void)?

    init(store: DisplayPlacementStore = DisplayPlacementStore(), environment: Environment = .live) {
        self.store = store
        self.environment = environment
    }

    private static let callback: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard !flags.contains(.beginConfigurationFlag), let context else { return }
        let owner = Unmanaged<DisplayArrangement>.fromOpaque(context).takeUnretainedValue()
        // CG invokes callbacks on the main thread; defer reads until layout settles.
        owner.pendingSave?.cancel()
        let work = DispatchWorkItem { [weak owner] in owner?.saveCurrent() }
        owner.pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func attach(_ id: CGDirectDisplayID) {
        detach()
        displayID = id
        let saved = store.load()
        let candidates = environment.displays().filter { $0 != id }
        anchorID = candidates.first(where: { environment.key($0) == saved?.anchorKey }) ??
            candidates.first(where: { environment.isBuiltin($0) }) ??
            candidates.first(where: { $0 == environment.mainDisplay() }) ?? candidates.first ?? 0
        guard anchorID != 0 else { return }
        let anchor = environment.bounds(anchorID)
        let size = environment.bounds(id).size
        let origin = saved?.origin(anchor: anchor, tabletSize: size) ?? CGPoint(x: anchor.maxX, y: anchor.minY)
        guard origin.x.isFinite, origin.y.isFinite,
              abs(origin.x) < CGFloat(Int32.max), abs(origin.y) < CGFloat(Int32.max) else { return }
        let result = environment.moveOrigin(id, origin)
        print("[display] \(saved == nil ? "default" : "restored") origin \(Int(origin.x)),\(Int(origin.y)): \(result.rawValue)")
        guard result == .success else { return }
        attachmentSucceeded = true
        environment.observe(self)
        observing = true
        saveCurrent()
    }

    func saveCurrent() {
        guard attachmentSucceeded, displayID != 0, anchorID != 0,
              !environment.isMirrored(displayID) else { return }
        let online = environment.displays()
        guard online.contains(displayID) else { return }
        let tablet = environment.bounds(displayID)
        let candidates = online.filter { $0 != displayID }.map {
            DisplayPlacementAnchor(id: $0, key: environment.key($0), bounds: environment.bounds($0))
        }
        // Keep offset-only layouts if no shared edge exists, but follow a new
        // neighbor as soon as the user moves the tablet to another display.
        guard let selected = DisplayPlacementAnchor.select(tablet: tablet, candidates: candidates, preferredID: anchorID) ??
            candidates.first(where: { $0.id == anchorID }) else { return }
        anchorID = selected.id
        let anchor = selected.bounds
        guard tablet.width > 0, tablet.height > 0, anchor.width > 0 else { return }
        let placement = SavedDisplayPlacement(anchorKey: selected.key, anchor: anchor, tablet: tablet)
        if placement != store.load() {
            store.save(placement)
            print("[display] saved relative origin \(Int(placement.dx)),\(Int(placement.dy))")
        }
        onChange?()
    }

    func detach() {
        pendingSave?.cancel(); pendingSave = nil
        if observing {
            environment.stopObserving(self)
        }
        saveCurrent()
        observing = false
        attachmentSucceeded = false
        displayID = 0; anchorID = 0
    }
}

import Foundation
import CoreGraphics

@main struct DisplayPlacementTests {
    static func main() throws {
        let anchor = CGRect(x: 0, y: 0, width: 1200, height: 750)
        let left = SavedDisplayPlacement(anchorKey: "builtin", anchor: anchor,
            tablet: CGRect(x: -1472, y: 100, width: 1472, height: 920))
        let restored = left.origin(anchor: CGRect(x: 400, y: 200, width: 1200, height: 750),
                                   tabletSize: CGSize(width: 1920, height: 1200))
        precondition(restored == CGPoint(x: -1520, y: 300), "Left edge must stay attached after resize")
        let above = SavedDisplayPlacement(anchorKey: "builtin", anchor: anchor,
            tablet: CGRect(x: 200, y: -920, width: 1472, height: 920))
        precondition(above.origin(anchor: anchor, tabletSize: CGSize(width: 1920, height: 1200)) == CGPoint(x: 200, y: -1200))
        let right = SavedDisplayPlacement(anchorKey: "builtin", anchor: anchor,
            tablet: CGRect(x: 1200, y: -75, width: 1472, height: 920))
        precondition(right.origin(anchor: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            tabletSize: CGSize(width: 1472, height: 920)) == CGPoint(x: 1600, y: -75))
        let decoded = try JSONDecoder().decode(SavedDisplayPlacement.self, from: JSONEncoder().encode(left))
        precondition(decoded == left)
        let suite = "DualScreen.PlacementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DisplayPlacementStore(defaults: defaults)
        precondition(store.load() == nil)
        store.save(left)
        precondition(DisplayPlacementStore(defaults: defaults).load() == left)
        testFailedRestorePreservesPlacement(store: store, saved: left)
        testMovedToExternalAnchor(store: store)
        testAnchorSelection()
        print("PASS left/above/right positioning, resize, anchor movement and persisted round trip")
    }

    static func testAnchorSelection() {
        let tablet = CGRect(x: 0, y: 0, width: 100, height: 100)
        let short = DisplayPlacementAnchor(id: 1, key: "z", bounds: CGRect(x: -100, y: 0, width: 100, height: 40))
        let long = DisplayPlacementAnchor(id: 2, key: "b", bounds: CGRect(x: 100, y: 0, width: 100, height: 100))
        let tied = DisplayPlacementAnchor(id: 3, key: "a", bounds: CGRect(x: 0, y: -100, width: 100, height: 100))
        let corner = DisplayPlacementAnchor(id: 4, key: "0", bounds: CGRect(x: -100, y: -100, width: 100, height: 100))
        let gap = DisplayPlacementAnchor(id: 5, key: "gap", bounds: CGRect(x: 103, y: 0, width: 100, height: 100))
        precondition(DisplayPlacementAnchor.select(tablet: tablet, candidates: [long, short], preferredID: 1)?.id == 1,
            "Keep the current anchor while it still shares a positive edge")
        precondition(DisplayPlacementAnchor.select(tablet: tablet, candidates: [short, long], preferredID: 0)?.id == 2,
            "Otherwise choose the longest shared edge")
        for candidates in [[short, long, tied, corner], [corner, tied, long, short]] {
            precondition(DisplayPlacementAnchor.select(tablet: tablet, candidates: candidates, preferredID: 4)?.id == 3,
                "Corner contact is not adjacency; ties use stable keys, not enumeration order")
        }
        precondition(DisplayPlacementAnchor.select(tablet: tablet, candidates: [corner, gap], preferredID: 4) == nil)
        let duplicateKey = DisplayPlacementAnchor(id: 6, key: "a", bounds: tied.bounds)
        precondition(DisplayPlacementAnchor.select(tablet: tablet, candidates: [duplicateKey, tied], preferredID: 0)?.id == 3)
        print("PASS anchor preference, shared-edge ranking, stable ties and corner/gap exclusion")
    }

    static func testMovedToExternalAnchor(store: DisplayPlacementStore) {
        let builtin = CGRect(x: 0, y: 0, width: 1200, height: 750)
        let external = CGRect(x: -2400, y: 0, width: 2400, height: 1600)
        var tablet = CGRect(x: 1200, y: 0, width: 1472, height: 920)
        let environment = DisplayArrangement.Environment(
            displays: { [1, 2, 3] },
            bounds: { $0 == 1 ? builtin : ($0 == 3 ? external : tablet) },
            key: { $0 == 1 ? "builtin" : ($0 == 3 ? "external" : "tablet") },
            isBuiltin: { $0 == 1 }, mainDisplay: { 1 }, isMirrored: { _ in false },
            moveOrigin: { _, origin in tablet.origin = origin; return .success },
            observe: { _ in }, stopObserving: { _ in })
        let arrangement = DisplayArrangement(store: store, environment: environment)
        for origin in [CGPoint(x: -3872, y: 100), CGPoint(x: -2200, y: -920)] {
            store.save(SavedDisplayPlacement(anchorKey: "builtin", anchor: builtin,
                tablet: CGRect(x: 1200, y: 0, width: 1472, height: 920)))
            arrangement.attach(2)
            tablet.origin = origin // User moves tablet next to the external monitor.
            arrangement.saveCurrent()
            precondition(store.load()?.anchorKey == "external", "Save must follow the actual adjacent external monitor")
            let saved = store.load()!
            arrangement.detach()
            tablet.size = CGSize(width: 1920, height: 1200)
            arrangement.attach(2)
            precondition(tablet.origin == saved.origin(anchor: external, tabletSize: tablet.size))
            precondition(origin.x == -3872 ? tablet.maxX == external.minX : tablet.maxY == external.minY,
                "External left/above edge must remain attached after resize")
            arrangement.detach()
            tablet.size = CGSize(width: 1472, height: 920)
        }
        print("PASS user movement selects external anchor and preserves left/above edges after resize")
    }

    static func testFailedRestorePreservesPlacement(store: DisplayPlacementStore, saved: SavedDisplayPlacement) {
        var attempts = 0
        var succeeds = false
        var observing = false
        var tablet = CGRect(x: 1200, y: 0, width: 1472, height: 920)
        let environment = DisplayArrangement.Environment(
            displays: { [1, 2] },
            bounds: { $0 == 1 ? CGRect(x: 0, y: 0, width: 1200, height: 750) : tablet },
            key: { $0 == 1 ? "builtin" : "tablet" },
            isBuiltin: { $0 == 1 }, mainDisplay: { 1 }, isMirrored: { _ in false },
            moveOrigin: { _, origin in
                attempts += 1
                guard succeeds else { return .failure }
                tablet.origin = origin
                return .success
            },
            observe: { _ in observing = true }, stopObserving: { _ in observing = false })
        let arrangement = DisplayArrangement(store: store, environment: environment)
        arrangement.attach(2)
        precondition(store.load() == saved, "Failed restoration must not overwrite saved placement")
        precondition(!observing, "Failed attachment must not subscribe to reconfiguration callbacks")
        arrangement.saveCurrent() // A delayed reconfiguration callback must also be harmless.
        arrangement.detach()
        precondition(store.load() == saved, "Failed attachment must not save on callbacks or detach")
        succeeds = true
        arrangement.attach(2)
        precondition(observing)
        precondition(attempts == 2, "Next attach must retry the preserved placement")
        precondition(tablet.origin == CGPoint(x: -1472, y: 100))
        tablet.origin.y = 125
        arrangement.saveCurrent()
        precondition(store.load()?.dy == 125, "Successful attachment must resume saving")
        arrangement.detach()
        print("PASS failed restoration preserves storage through callbacks/detach and retries")
    }
}

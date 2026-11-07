import AppKit
import Sparkle

/// Standard Sparkle UI owns downloading, EdDSA verification and installation.
/// See https://sparkle-project.org/documentation/programmatic-setup/.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    private weak var menuItem: NSMenuItem?
    private(set) var startupError: String?
    var onCanCheck: (() -> Void)?
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    init(start: Bool = true) {
        super.init()
        precondition(Thread.isMainThread)
        let bundle = Bundle.main
        guard AppRuntimePolicy.updaterEligible(bundleURL: bundle.bundleURL,
                  executableURL: bundle.executableURL, info: bundle.infoDictionary ?? [:]) else { return }
        // Pass false so smoke tests can initialize/start the updater without
        // the controller displaying a modal configuration error.
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                         updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            // Sparkle APIs and AppKit state are always consumed on main.
            DispatchQueue.main.async { [weak self] in
                self?.refreshMenuItem()
                if self?.canCheckForUpdates == true { self?.onCanCheck?() }
            }
        }
        if start {
            do { try controller.updater.start() }
            catch { startupError = error.localizedDescription }
        }
    }

    func attach(to item: NSMenuItem) {
        precondition(Thread.isMainThread)
        menuItem = item
        item.target = controller
        item.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        refreshMenuItem()
    }

    func refreshMenuItem() {
        precondition(Thread.isMainThread)
        // The host menu has autoenablesItems=false, so target validation alone
        // does not update it. KVO and menuNeedsUpdate both refresh explicitly.
        menuItem?.isEnabled = canCheckForUpdates && startupError == nil
        menuItem?.toolTip = startupError ?? (controller == nil ? "Обновления доступны только в установленном DualScreen.app с корректной конфигурацией Sparkle" : nil)
    }

    func checkForUpdates() {
        precondition(Thread.isMainThread)
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // No feed bodies, keys, or private user data in diagnostics.
        let error = error as NSError
        print("[updater] aborted domain=\(error.domain) code=\(error.code)")
    }

    func smokeResult(bundle: Bundle = .main, mode: String = "app-smoke-test") -> [String: Any] {
        let info = bundle.infoDictionary ?? [:]
        return ["mode": mode, "bundleIdentifier": bundle.bundleIdentifier ?? "",
                "version": info["CFBundleShortVersionString"] as? String ?? "",
                "build": info["CFBundleVersion"] as? String ?? "",
                "feed": info["SUFeedURL"] as? String ?? "",
                "publicKeyLoaded": (info["SUPublicEDKey"] as? String).flatMap { Data(base64Encoded: $0) }?.count == 32,
                "validBundle": AppRuntimePolicy.updaterEligible(bundleURL: bundle.bundleURL, executableURL: bundle.executableURL, info: info),
                "updaterInitialized": controller != nil,
                "canCheck": canCheckForUpdates,
                "error": startupError ?? ""]
    }
}

/// Sparkle 2.10 has no relaunch-arguments delegate API. A path-bound, short-lived
/// sidecar preserves the explicit isolated test session across bundle replacement
/// without modifying preferences shared with the real app. Never create one in
/// Applications. Removing the fixture/sidecar ends the test session.
enum UpdaterTestSession {
    private static var marker: URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("." + Bundle.main.bundleURL.lastPathComponent + ".updater-test.json")
    }
    static func begin() throws {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let applications = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        guard Bundle.main.bundleURL.pathExtension == "app", !applications.contains(where: { path.hasPrefix($0) }) else {
            throw NSError(domain: "DualScreen.UpdaterTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "--updater-test requires an isolated fixture outside Applications"])
        }
        let data = try JSONSerialization.data(withJSONObject: ["bundlePath": path, "expires": Date().addingTimeInterval(86400).timeIntervalSince1970])
        try data.write(to: marker, options: .atomic)
    }
    static var isActive: Bool {
        guard let data = try? Data(contentsOf: marker),
              let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              item["bundlePath"] as? String == Bundle.main.bundleURL.standardizedFileURL.path,
              let expires = item["expires"] as? Double, expires > Date().timeIntervalSince1970 else { return false }
        return true
    }
}

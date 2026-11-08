import AppKit

/// Strongly retained by the entry point (NSApplication.delegate is weak).
final class AppLifecycle: NSObject, NSApplicationDelegate {
    private let isStreaming: () -> Bool
    private let confirmActiveTermination: (() -> Bool)?
    private let prepare: () -> Void
    private var testStatusItem: NSStatusItem?
    private(set) var updater: AppUpdater?
    private var testCheckStarted = false

    init(isStreaming: @escaping () -> Bool = { false },
         confirmActiveTermination: (() -> Bool)? = nil,
         prepare: @escaping () -> Void = {}) {
        self.isStreaming = isStreaming
        self.confirmActiveTermination = confirmActiveTermination
        self.prepare = prepare
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        precondition(Thread.isMainThread)
        if isStreaming() {
            if let confirmation = confirmActiveTermination {
                guard confirmation() else { return .terminateCancel }
            } else {
                let alert = NSAlert()
                alert.messageText = L10n.text("session.end.title")
                alert.informativeText = L10n.text("session.end.body")
                alert.addButton(withTitle: L10n.text("session.end.confirm"))
                alert.addButton(withTitle: L10n.text("button.cancel"))
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            }
        }
        prepare()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        prepare() // idempotent fallback for external application termination
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.activate(ignoringOtherApps: true)
        return false
    }

    func initializeUpdater() -> AppUpdater {
        let instance = AppUpdater()
        updater = instance
        return instance
    }

    @discardableResult
    func runUpdaterTest() -> Bool {
        precondition(Thread.isMainThread)
        let updater = initializeUpdater()
        guard updater.controller != nil, updater.startupError == nil else {
            printJSON(updater.smokeResult(mode: "updater-test"))
            return false
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let check = NSMenuItem(title: L10n.text("menu.updates"), action: nil, keyEquivalent: "")
        updater.attach(to: check); menu.addItem(check)
        let quit = NSMenuItem(title: L10n.text("menu.endTest"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; menu.addItem(quit)
        testStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        testStatusItem?.button?.title = L10n.text("status.test")
        testStatusItem?.menu = menu
        updater.onCanCheck = { [weak self, weak updater] in
            guard let self, !self.testCheckStarted else { return }
            self.testCheckStarted = true
            printJSON(updater?.smokeResult(mode: "updater-test") ?? [:])
            updater?.checkForUpdates()
        }
        // Initial readiness can precede callback installation.
        DispatchQueue.main.async { [weak updater] in
            if updater?.canCheckForUpdates == true { updater?.onCanCheck?() }
        }
        withExtendedLifetime(self) { NSApp.run() }
        return true
    }
}

func printJSON(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text)
}

enum BundledPreferences {
    static func migrateKnownLegacyPlacement() {
        guard Bundle.main.bundleIdentifier == AppRuntimePolicy.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        let current = defaults.persistentDomain(forName: AppRuntimePolicy.bundleIdentifier) ?? [:]
        guard current["legacyPreferenceMigration.v1"] as? Bool != true else { return }
        let legacy = defaults.persistentDomain(forName: "DualScreenHost") ?? [:]
        let migrated = AppRuntimePolicy.migratedPreferences(current: current, legacy: legacy)
        let target = AppRuntimePolicy.sharedDefaults()
        if current["tabletDisplayPlacement.v1"] == nil, let data = migrated["tabletDisplayPlacement.v1"] as? Data {
            target.set(data, forKey: "tabletDisplayPlacement.v1")
        }
        target.set(true, forKey: "legacyPreferenceMigration.v1")
        target.synchronize()
    }
}

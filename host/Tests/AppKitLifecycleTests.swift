import Foundation
import AppKit

@main struct AppKitLifecycleTests {
    static func main() {
        _ = NSApplication.shared
        let updater = AppUpdater()
        assert(updater.controller == nil, "unbundled CLI must never instantiate Sparkle")
        let menu = NSMenu(); menu.autoenablesItems = false
        let check = NSMenuItem(title: "Проверить обновления…", action: nil, keyEquivalent: "")
        menu.addItem(check)
        updater.attach(to: check)
        assert(!check.isEnabled && check.target == nil)
        let gate = TerminationPreparation()
        var cleanups = 0
        let delegate = AppLifecycle(prepare: { gate.run { cleanups += 1 } })
        assert(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        assert(cleanups == 1)
        print("PASS CLI has no Sparkle instance or enabled update item; delegate cleanup is idempotent")
        var approved = false
        var activeCleanups = 0
        let active = AppLifecycle(isStreaming: { true }, confirmActiveTermination: { approved }, prepare: { activeCleanups += 1 })
        assert(active.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        assert(activeCleanups == 0)
        approved = true
        assert(active.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        assert(activeCleanups == 1)
        print("PASS active-session termination requires approval and cancellation leaves streaming untouched")
    }
}

import Foundation

/// Pure decisions shared by the app and device-free regression tests.
enum AppRuntimePolicy {
    static let bundleIdentifier = "com.oleg.dualscreen.host"

    static func launchAgent(bundleURL: URL, executableURL: URL) -> [String: Any] {
        let arguments = bundleURL.pathExtension == "app"
            ? ["/usr/bin/open", "-g", bundleURL.standardizedFileURL.path]
            : [executableURL.standardizedFileURL.path]
        return ["Label": bundleIdentifier, "ProgramArguments": arguments,
                "RunAtLoad": true, "KeepAlive": false]
    }

    static func adbCandidates(resourceURL: URL?) -> [String] {
        (resourceURL.map { [$0.path] } ?? []) + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
    }

    /// UserDefaults(suiteName:) returns nil when the suite name equals the
    /// running app's own bundle identifier (v1.0.0 launch crash, SIGTRAP).
    /// Standard defaults already ARE that domain for the bundled app, and for
    /// the CLI the explicit suite still resolves to the shared plist.
    static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: bundleIdentifier) ?? .standard
    }

    // DisplayArrangement already uses the stable bundle-ID suite, including CLI.
    // Only import the one known historical key; never import Sparkle preferences.
    static func migratedPreferences(current: [String: Any], legacy: [String: Any]) -> [String: Any] {
        var result = current
        let key = "tabletDisplayPlacement.v1"
        if result[key] == nil, let value = legacy[key] as? Data { result[key] = value }
        return result
    }

    static func updaterEligible(bundleURL: URL, executableURL: URL?, info: [String: Any]) -> Bool {
        guard bundleURL.pathExtension == "app",
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundlePackageType"] as? String == "APPL",
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              executableURL?.standardizedFileURL == bundleURL.appendingPathComponent("Contents/MacOS/\(executable)").standardizedFileURL,
              let version = info["CFBundleVersion"] as? String, !version.isEmpty,
              let displayVersion = info["CFBundleShortVersionString"] as? String, !displayVersion.isEmpty,
              let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
              url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32,
              info["SUAutomaticallyUpdate"] as? Bool != true,
              info["SUAllowsAutomaticUpdates"] as? Bool == false,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true else { return false }
        return true
    }
}

/// Main-thread cleanup gate, including reentrant NSApplication termination.
final class TerminationPreparation {
    private(set) var isPrepared = false
    func run(_ cleanup: () -> Void) {
        guard !isPrepared else { return }
        isPrepared = true
        cleanup()
    }
}

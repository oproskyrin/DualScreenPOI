import Foundation

@main
struct AppRuntimeTests {
    static func main() throws {
        let url = URL(fileURLWithPath: "/Applications/DualScreen.app")
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.oleg.dualscreen.host", "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "DualScreenHost", "CFBundleVersion": "0.13.0",
            "CFBundleShortVersionString": "0.13.0", "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "SUEnableAutomaticChecks": true, "SUAutomaticallyUpdate": false,
            "SUAllowsAutomaticUpdates": false,
            "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true
        ]
        assert(AppRuntimePolicy.updaterEligible(bundleURL: url, executableURL: url.appendingPathComponent("Contents/MacOS/DualScreenHost"), info: info))
        assert(!AppRuntimePolicy.updaterEligible(bundleURL: URL(fileURLWithPath: "/tmp"), executableURL: URL(fileURLWithPath: "/tmp/DualScreenHost"), info: info))
        for (key, value) in [("SUFeedURL", "http://example.com/feed"), ("SUPublicEDKey", "bad"), ("CFBundleIdentifier", "other")] {
            var invalid = info; invalid[key] = value
            assert(!AppRuntimePolicy.updaterEligible(bundleURL: url, executableURL: url.appendingPathComponent("Contents/MacOS/DualScreenHost"), info: invalid))
        }
        var unsafe = info; unsafe["SURequireSignedFeed"] = false
        assert(!AppRuntimePolicy.updaterEligible(bundleURL: url, executableURL: url.appendingPathComponent("Contents/MacOS/DualScreenHost"), info: unsafe))
        assert(!AppRuntimePolicy.updaterEligible(bundleURL: url, executableURL: URL(fileURLWithPath: "/tmp/DualScreenHost"), info: info))
        print("PASS bundled updater eligibility (CLI/invalid configuration rejected)")
        var autoinstall = info; autoinstall["SUAutomaticallyUpdate"] = true
        assert(!AppRuntimePolicy.updaterEligible(bundleURL: url, executableURL: url.appendingPathComponent("Contents/MacOS/DualScreenHost"), info: autoinstall), "silent automatic installation must not bypass active-session consent")
        for value: Any? in [nil, true, "false"] {
            var automatic = info
            automatic["SUAllowsAutomaticUpdates"] = value
            assert(!AppRuntimePolicy.updaterEligible(bundleURL: url, executableURL: url.appendingPathComponent("Contents/MacOS/DualScreenHost"), info: automatic), "automatic updates must be explicitly prohibited, not merely default off")
        }
        let appPlist = AppRuntimePolicy.launchAgent(bundleURL: url, executableURL: URL(fileURLWithPath: "/stale/.build/DualScreenHost"))
        assert(appPlist["ProgramArguments"] as? [String] == ["/usr/bin/open", "-g", "/Applications/DualScreen.app"])
        assert(appPlist["RunAtLoad"] as? Bool == true)
        assert(appPlist["KeepAlive"] as? Bool == false)
        let cliPlist = AppRuntimePolicy.launchAgent(bundleURL: URL(fileURLWithPath: "/tmp"), executableURL: URL(fileURLWithPath: "/stable/DualScreenHost"))
        assert(cliPlist["ProgramArguments"] as? [String] == ["/stable/DualScreenHost"])
        let roundtrip = try PropertyListSerialization.propertyList(from: PropertyListSerialization.data(fromPropertyList: appPlist, format: .xml, options: 0), format: nil) as! [String: Any]
        assert(roundtrip["KeepAlive"] as? Bool == false)
        assert(AppRuntimePolicy.adbCandidates(resourceURL: URL(fileURLWithPath: "/Applications/DualScreen.app/Contents/Resources/adb")).first == "/Applications/DualScreen.app/Contents/Resources/adb")
        var count = 0
        let once = TerminationPreparation()
        once.run { count += 1; once.run { count += 100 } }
        once.run { count += 10 }
        assert(count == 1)
        let migrated = AppRuntimePolicy.migratedPreferences(current: ["tabletDisplayPlacement.v1": Data([2])], legacy: ["tabletDisplayPlacement.v1": Data([1]), "arbitrary": "secret", "SUFeedURL": "http://evil"])
        assert(migrated["tabletDisplayPlacement.v1"] as? Data == Data([2]))
        assert(migrated["arbitrary"] == nil && migrated["SUFeedURL"] == nil)
        assert(AppRuntimePolicy.migratedPreferences(current: [:], legacy: ["tabletDisplayPlacement.v1": Data([1])])["tabletDisplayPlacement.v1"] as? Data == Data([1]))
        print("PASS stable autostart, bundled adb, idempotent cleanup, allowlisted migration")
    }
}

import Foundation

/// Opt-in login launch, never a self-respawning daemon. The plist is read at the
/// next login; registering it immediately would start a second raw CLI process.
enum LaunchAgent {
    static let label = AppRuntimePolicy.bundleIdentifier
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }
    static var isInstalled: Bool {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return plist["Label"] as? String == label
    }

    private static func readOwnPlist() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: plistPath) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: plistPath))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == label else {
            throw failure(L10n.format("autostart.foreign", plistPath))
        }
        return plist
    }

    static func install() throws {
        _ = try readOwnPlist() // never overwrite another label's file
        guard let executable = Bundle.main.executableURL else { throw failure(L10n.text("autostart.executable")) }
        let plist = AppRuntimePolicy.launchAgent(bundleURL: Bundle.main.bundleURL, executableURL: executable)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: plistPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let previous = FileManager.default.contents(atPath: plistPath)
        // Persist first: bootout can SIGTERM this very process when toggled
        // from an old launchd-managed CLI. Never leave its KeepAlive plist behind.
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        do { try unloadIfLoaded() }
        catch {
            if let previous { try previous.write(to: URL(fileURLWithPath: plistPath), options: .atomic) }
            else { try FileManager.default.removeItem(atPath: plistPath) }
            throw error
        }
    }

    static func uninstall() throws {
        guard try readOwnPlist() != nil else { return }
        let previous = try Data(contentsOf: URL(fileURLWithPath: plistPath))
        try FileManager.default.removeItem(atPath: plistPath)
        do { try unloadIfLoaded() }
        catch {
            try previous.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            throw error
        }
    }

    /// Only migrate an existing opt-in agent with our exact label and a known
    /// host executable. Do not create an agent for users who never enabled it.
    static func migrateLegacyIfNeeded() throws {
        guard Bundle.main.bundleURL.pathExtension == "app", let old = try readOwnPlist() else { return }
        let previous = old["ProgramArguments"] as? [String] ?? []
        let desired = AppRuntimePolicy.launchAgent(bundleURL: Bundle.main.bundleURL,
                                                   executableURL: Bundle.main.executableURL!)
        guard previous != desired["ProgramArguments"] as? [String] || old["KeepAlive"] as? Bool != false else { return }
        guard previous.first.map({ URL(fileURLWithPath: $0).lastPathComponent == "DualScreenHost" || $0 == "/usr/bin/open" }) == true else {
            throw failure(L10n.text("autostart.unknown"))
        }
        // A legacy launchd-managed instance must not unload itself mid-update.
        if previous.first == Bundle.main.executableURL?.path {
            throw failure(L10n.text("autostart.legacy"))
        }
        try install()
    }

    private static func unloadIfLoaded() throws {
        // `list <label>` only inspects the user's job. Never unload other labels.
        let listing = try run(["list", label])
        guard listing.status == 0 else {
            if listing.output.contains("Could not find service") || listing.output.contains("Could not find specified service") || listing.status == 113 { return }
            throw failure(L10n.format("autostart.inspect", listing.output))
        }
        let result = try run(["bootout", "gui/\(getuid())/\(label)"])
        guard result.status == 0 else { throw failure(L10n.format("autostart.disable", result.output)) }
    }

    private static func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        guard ended.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            throw failure(L10n.text("autostart.timeout"))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: label + ".autostart", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

import Foundation

/// One binary follows macOS's per-app/system language preferences. Unsupported
/// languages fall back to English. No preferences are written by localization.
enum L10n {
    static func language(for preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: ["en", "ru"], forPreferences: preferences).first ?? "en"
    }

    static var resourceBundle: Bundle {
        // The custom app builder copies catalogs directly into the installed
        // app. Check it FIRST: Bundle.module's generated accessor can fatalError
        // if the SwiftPM build directory is absent on another user's machine.
        if Bundle.main.path(forResource: "en", ofType: "lproj") != nil { return .main }
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func text(_ key: String, preferences: [String] = Locale.preferredLanguages,
                     bundle: Bundle = resourceBundle) -> String {
        let language = language(for: preferences)
        func lookup(_ language: String) -> String? {
            guard let path = bundle.path(forResource: language, ofType: "lproj"),
                  let localized = Bundle(path: path) else { return nil }
            let value = localized.localizedString(forKey: key, value: key, table: "Localizable")
            return value == key ? nil : value
        }
        return lookup(language) ?? lookup("en") ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: language(for: Locale.preferredLanguages)), arguments: arguments)
    }
}

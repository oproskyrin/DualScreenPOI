import Foundation

@main struct LocalizationTests {
    static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        assert(L10n.language(for: ["en-US"]) == "en")
        assert(L10n.language(for: ["ru-RU"]) == "ru")
        assert(L10n.language(for: ["fr-FR"]) == "en")
        assert(L10n.language(for: []) == "en")
        assert(L10n.language(for: ["de-DE", "ru-RU"]) == "ru")
        assert(L10n.text("menu.updates", preferences: ["en-US"], bundle: bundle) == "Check for Updates…")
        assert(L10n.text("menu.updates", preferences: ["ru-RU"], bundle: bundle) == "Проверить обновления…")
        assert(L10n.text("menu.updates", preferences: ["ja-JP"], bundle: bundle) == "Check for Updates…")
        assert(L10n.text("missing.key", preferences: ["ru"], bundle: bundle) == "missing.key")
        // A deliberately incomplete Russian table must fall back to English.
        let partial = Bundle(path: CommandLine.arguments[2])!
        assert(L10n.text("menu.updates", preferences: ["ru"], bundle: partial) == "Check for Updates…")
        for language in ["en", "ru"] {
            let format = L10n.text("error.port.body", preferences: [language], bundle: bundle)
            let message = String(format: format, 7381, "test error")
            assert(message.contains("7381") && message.contains("test error"))
        }
        print("PASS system language matching, EN fallback, RU catalog, missing-key fallback, formatting")
    }
}

import Foundation

/// A target locale to translate into.
///
/// Pairs the Apple locale identifier (used as the key in `.xcstrings` localizations and
/// as the `<locale>.lproj` directory name) with a human-readable English name suitable
/// for embedding in the model's instructions.
struct TargetLocale: Sendable, Hashable {
    /// The Apple locale identifier (e.g. `fr`, `pt-BR`, `zh-Hans`).
    let identifier: String

    /// The English display name (e.g. "French", "Portuguese (Brazil)", "Chinese, Simplified").
    let englishDisplayName: String

    /// Resolved `Locale.Language` for `SystemLanguageModel.supportsLocale(_:)` checks.
    var locale: Locale {
        Locale(identifier: identifier)
    }

    /// Default first-wave locale set: French, German, Spanish, Italian, Brazilian
    /// Portuguese, Simplified Chinese, Traditional Chinese, Japanese, Korean.
    static let defaults: [TargetLocale] = [
        "fr", "de", "es", "it", "pt-BR", "zh-Hans", "zh-Hant", "ja", "ko",
    ].map(TargetLocale.init(identifier:))

    /// Constructs a `TargetLocale` from an identifier, resolving the English display name
    /// via the system locale services. Falls back to the identifier itself if the system
    /// cannot resolve a name (which only happens for malformed identifiers).
    init(identifier: String) {
        self.identifier = identifier
        let englishLocale = Locale(identifier: "en_US")
        self.englishDisplayName = englishLocale.localizedString(forIdentifier: identifier)
            ?? englishLocale.localizedString(forLanguageCode: identifier)
            ?? identifier
    }
}

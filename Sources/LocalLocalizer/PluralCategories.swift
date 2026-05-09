import Foundation

/// CLDR plural category. Each language uses a specific subset of these. The exact
/// rules — which numeric values trigger which category — are defined per-locale
/// by the Unicode CLDR project.
enum PluralCategory: String, Sendable, CaseIterable, Hashable {
    case zero
    case one
    case two
    case few
    case many
    case other
}

/// The set of CLDR plural categories used by a given locale.
///
/// `Foundation.Locale` does not expose CLDR plural categories directly, so this
/// table is hardcoded for the locales the tool supports out of the box. Callers
/// passing a locale not in the table get a sensible English-style fallback
/// (`one, other`) plus a one-time warning at the orchestrator layer.
enum PluralCategories {
    /// Returns the plural categories required by the given locale identifier in the
    /// canonical order Xcode/Apple expects in `.xcstrings` (always with `other` last).
    static func categories(for localeIdentifier: String) -> [PluralCategory] {
        if let exact = table[localeIdentifier] {
            return exact
        }
        // Fall back on the language code only (e.g. `pt-BR` → `pt`, `zh-Hans` → `zh`).
        let languageOnly = String(localeIdentifier.split(separator: "-").first ?? "")
        return table[languageOnly] ?? Self.fallback
    }

    /// Whether the given locale identifier is in the hardcoded table. Callers can
    /// use this to emit a one-time "falling back to one/other" warning.
    static func isKnown(_ localeIdentifier: String) -> Bool {
        if table[localeIdentifier] != nil { return true }
        let languageOnly = String(localeIdentifier.split(separator: "-").first ?? "")
        return table[languageOnly] != nil
    }

    /// English-style fallback used for unknown locales. Two categories: `one` and
    /// `other`. The orchestrator pairs this with a warning so the user knows a hand
    /// review is especially important for that locale.
    private static let fallback: [PluralCategory] = [.one, .other]

    /// CLDR plural-category table for the nine default locales plus a few common
    /// extras (en for source detection, ru/ar for high-fanout categories that show
    /// up in the verification fixtures).
    private static let table: [String: [PluralCategory]] = [
        "en": [.one, .other],
        "fr": [.one, .many, .other],
        "de": [.one, .other],
        "es": [.one, .many, .other],
        "it": [.one, .many, .other],
        "pt-BR": [.one, .many, .other],
        "pt": [.one, .many, .other],
        "zh-Hans": [.other],
        "zh-Hant": [.other],
        "zh": [.other],
        "ja": [.other],
        "ko": [.other],
        "ru": [.one, .few, .many, .other],
        "ar": [.zero, .one, .two, .few, .many, .other],
    ]
}

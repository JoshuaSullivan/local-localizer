import Foundation

/// Errors thrown while loading a glossary file.
enum GlossaryError: Error, LocalizedError {
    case unreadable(URL, underlying: Error)
    case invalidJSON(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url, let err):
            return "Could not read glossary at \(url.path): \(err.localizedDescription)"
        case .invalidJSON(let url, let err):
            return "Could not parse glossary at \(url.path) as JSON: \(err.localizedDescription)"
        }
    }
}

/// Tone hint for the model. Used to nudge the model toward a particular register
/// (formal vs. informal vs. neutral). The hint is rendered into language-specific
/// guidance inside the prompt fragment.
enum Tone: String, Sendable, Hashable, Codable {
    case formal
    case informal
    case neutral
    case professional   // Synonymous with formal but reads better in some contexts.
    case polite         // Common shorthand for Japanese/Korean polite forms.
}

/// User-supplied translation guidance: brand-name preservation, per-locale tone
/// preferences, and forced term mappings.
///
/// All fields are optional; an empty glossary is valid and produces no prompt
/// fragment. The glossary is per-tool-invocation; it is not persisted into the
/// catalog file.
struct Glossary: Sendable, Codable {
    /// Brand names and other terms that MUST appear verbatim in every translation,
    /// untranslated. Case-sensitive matching is the model's responsibility — we
    /// just list the canonical spellings.
    var doNotTranslate: [String]?

    /// Per-locale tone preference. Keys are locale identifiers (e.g. `de`, `pt-BR`).
    /// The special key `default` applies when the locale has no specific entry.
    var tone: [String: Tone]?

    /// Forced term translations, keyed first by locale identifier and then by
    /// source-language term. The model is instructed to use the right-hand side
    /// rather than its own translation when it encounters the source term.
    var termMappings: [String: [String: String]]?

    /// Loads a glossary from disk. Returns an empty glossary if `url` is `nil`.
    static func load(from url: URL?) throws -> Glossary {
        guard let url else { return Glossary() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GlossaryError.unreadable(url, underlying: error)
        }
        do {
            return try JSONDecoder().decode(Glossary.self, from: data)
        } catch {
            throw GlossaryError.invalidJSON(url, underlying: error)
        }
    }

    /// Builds the prompt fragment for a particular target locale, combining
    /// brand-name preservation, term mappings, and tone. Returns `nil` when no
    /// fragment would have any content (i.e. the glossary contributes nothing for
    /// this locale and `cliTone` is also `nil`).
    func promptFragment(for locale: TargetLocale, cliTone: Tone?) -> String? {
        var sections: [String] = []

        if let brands = doNotTranslate, !brands.isEmpty {
            let bullets = brands.map { "- \($0)" }.joined(separator: "\n")
            sections.append("""
                Brand names and product names that MUST appear EXACTLY as written, untranslated:
                \(bullets)
                """)
        }

        if let mappings = termMappings?[locale.identifier], !mappings.isEmpty {
            let bullets = mappings
                .sorted { $0.key < $1.key }
                .map { "- \"\($0.key)\" → \"\($0.value)\"" }
                .joined(separator: "\n")
            sections.append("""
                Required term translations for \(locale.englishDisplayName):
                \(bullets)
                """)
        }

        let resolvedTone = tone?[locale.identifier] ?? tone?["default"] ?? cliTone
        if let resolvedTone, let toneFragment = Self.toneInstruction(resolvedTone, locale: locale) {
            sections.append("Tone: \(toneFragment)")
        }

        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// Renders a tone hint into language-specific guidance the model can act on.
    /// For locales without specific guidance, falls back to a generic phrasing.
    private static func toneInstruction(_ tone: Tone, locale: TargetLocale) -> String? {
        switch (tone, locale.identifier) {
        case (.formal, "de"), (.professional, "de"):
            return "formal (use Sie/Ihr forms; full sentences; avoid contractions)."
        case (.informal, "de"):
            return "informal (use du/dein forms; conversational)."
        case (.formal, "fr"), (.professional, "fr"):
            return "formal (use vous; full sentences)."
        case (.informal, "fr"):
            return "informal (use tu; conversational)."
        case (.formal, "es"), (.professional, "es"):
            return "formal (use usted)."
        case (.informal, "es"):
            return "informal (use tú)."
        case (.formal, "it"), (.professional, "it"):
            return "formal (use Lei)."
        case (.informal, "it"):
            return "informal (use tu)."
        case (.polite, "ja"), (.formal, "ja"), (.professional, "ja"):
            return "polite (use です/ます forms throughout)."
        case (.informal, "ja"):
            return "casual (plain forms; no です/ます)."
        case (.polite, "ko"), (.formal, "ko"), (.professional, "ko"):
            return "polite (use 합쇼체 -습니다/-ㅂ니다 forms)."
        case (.informal, "ko"):
            return "casual (해체 plain forms)."
        case (.formal, _), (.professional, _):
            return "formal and professional."
        case (.informal, _):
            return "informal and conversational."
        case (.polite, _):
            return "polite and respectful."
        case (.neutral, _):
            return nil
        }
    }
}

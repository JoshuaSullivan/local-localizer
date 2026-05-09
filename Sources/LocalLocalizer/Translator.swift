import Foundation
import FoundationModels

/// Errors thrown by ``Translator`` for situations the orchestration layer needs to react
/// to (versus generic generation errors that just get logged and skipped).
enum TranslatorError: Error, LocalizedError {
    /// Apple Intelligence is not enabled or otherwise unavailable on this system.
    case modelUnavailable(SystemLanguageModel.Availability.UnavailableReason)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is not enabled. Open System Settings > Apple Intelligence & Siri to turn it on."
        case .modelUnavailable(.deviceNotEligible):
            return "This device does not support Apple Intelligence."
        case .modelUnavailable(.modelNotReady):
            return "The on-device model is still downloading. Try again in a few minutes."
        case .modelUnavailable(let other):
            return "Apple Intelligence is unavailable: \(other)."
        }
    }
}

/// Drives translation of individual `(comment, sourceValue)` pairs against the
/// on-device system language model.
///
/// A new ``LanguageModelSession`` is created per call (Apple's documented
/// recommendation for single-turn tasks). The translator is `Sendable` so the
/// orchestrator can fan out concurrent calls — each call gets its own session,
/// so the per-session "one request at a time" rule is satisfied automatically.
struct Translator: Sendable {
    /// The decoded translation result. ``Generable`` constrains the model output
    /// so we receive a typed `String` instead of having to parse free-form text.
    @Generable
    struct Translation {
        @Guide(description: "The translated string only. No quotes. No explanation.")
        var text: String
    }

    let model: SystemLanguageModel
    let temperature: Double
    let glossary: Glossary
    let cliTone: Tone?

    init(temperature: Double, glossary: Glossary = Glossary(), cliTone: Tone? = nil) {
        self.model = SystemLanguageModel.default
        self.temperature = temperature
        self.glossary = glossary
        self.cliTone = cliTone
    }

    /// Verifies the model is available before any work begins.
    /// Throws ``TranslatorError/modelUnavailable(_:)`` if not.
    func verifyAvailability() throws {
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw TranslatorError.modelUnavailable(reason)
        }
    }

    /// Whether the model supports translating into the given locale.
    func supports(_ locale: TargetLocale) -> Bool {
        model.supportsLocale(locale.locale)
    }

    /// Translates a single source string into the given target locale, using the
    /// developer's context comment plus any per-locale glossary and tone hints
    /// to disambiguate. When `pluralCategory` is non-nil, the prompt includes a
    /// plural-form hint so the model produces the right grammatical form.
    /// - Returns: The translated text, trimmed of surrounding whitespace.
    func translate(
        source: String,
        comment: String?,
        into locale: TargetLocale,
        pluralCategory: PluralCategory? = nil
    ) async throws -> String {
        let instructions = self.instructions(for: locale)
        let session = LanguageModelSession(instructions: instructions)
        let prompt = Self.prompt(source: source, comment: comment, pluralCategory: pluralCategory)
        let options = GenerationOptions(temperature: temperature)
        let response = try await session.respond(
            to: prompt,
            generating: Translation.self,
            options: options
        )
        return response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the per-locale instructions block. Apple recommends the exact phrase
    /// "You MUST respond in {LANGUAGE}" to force output language. The glossary
    /// fragment (if any) is appended so per-locale brand-name preservation, term
    /// mappings, and tone hints land in the same prompt.
    private func instructions(for locale: TargetLocale) -> String {
        var lines: [String] = [
            "You are a professional iOS app localization translator.",
            "Translate the source string (between the <<< and >>> markers) into \(locale.englishDisplayName).",
            "You MUST respond in \(locale.englishDisplayName).",
            "Use the developer's context comment to inform tone, brevity, and grammar.",
            "Format specifiers (%@, %d, %lld, %f, %1$@, %2$d, etc.) are runtime placeholders — translate the words around them, but keep each literal % placeholder intact in your translation. Example: \"%lld file\" → \"%lld fichier\" (translate \"file\", keep \"%lld\"). Do not replace placeholders with literal numbers or words.",
            "Preserve every line break: if the source has multiple lines, the translation must have the same number of lines in the same positions.",
            "Do not include the <<< or >>> markers in your response.",
            "Do not add quotation marks, markdown, or any explanation.",
        ]
        if let glossaryFragment = glossary.promptFragment(for: locale, cliTone: cliTone) {
            lines.append("")
            lines.append(glossaryFragment)
        }
        return lines.joined(separator: "\n")
    }

    /// Builds the per-string prompt. Wraps the source in `<<<` / `>>>` delimiters
    /// so the model can unambiguously recognize where the source ends, and
    /// includes an explicit line-count hint plus (optional) plural-category hint.
    private static func prompt(source: String, comment: String?, pluralCategory: PluralCategory?) -> String {
        let context = comment?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "no context provided"
        let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
        let lineRequirement = lineCount > 1
            ? "The source has exactly \(lineCount) lines. Your translation MUST also have exactly \(lineCount) lines, separated by line breaks in the same positions."
            : "The source is a single line. Your translation MUST also be a single line."
        var lines = ["Context: \(context)", lineRequirement]
        if let pluralCategory {
            lines.append(Self.pluralHint(for: pluralCategory))
        }
        lines.append("Source:")
        lines.append("<<<")
        lines.append(source)
        lines.append(">>>")
        return lines.joined(separator: "\n")
    }

    /// Renders a plural-category hint into a sentence the model can act on.
    private static func pluralHint(for category: PluralCategory) -> String {
        switch category {
        case .zero:
            return "Generate the plural form used when the count is exactly zero."
        case .one:
            return "Generate the singular form used when the count is exactly one."
        case .two:
            return "Generate the dual form used when the count is exactly two."
        case .few:
            return "Generate the plural form used for a small number of items (the language's 'few' category)."
        case .many:
            return "Generate the plural form used for a large number of items (the language's 'many' category)."
        case .other:
            return "Generate the general plural form used for any count not covered by another category."
        }
    }
}

private extension String {
    /// Returns `nil` for an empty string, otherwise `self`. Useful for collapsing empty
    /// strings into optionals via `??`.
    var nonEmpty: String? { isEmpty ? nil : self }
}

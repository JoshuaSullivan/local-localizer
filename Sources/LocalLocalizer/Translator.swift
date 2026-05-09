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

/// Drives translation of individual `(comment, sourceValue)` pairs against the on-device
/// system language model.
///
/// A new ``LanguageModelSession`` is created per call. Apple's documentation explicitly
/// recommends single-turn sessions for independent tasks; reusing one session across
/// hundreds of unrelated strings would accumulate transcript history and risk a context
/// window overflow.
struct Translator: Sendable {
    /// The decoded translation result. ``Generable`` constrains the model output so we
    /// receive a typed `String` instead of having to parse free-form text.
    @Generable
    struct Translation {
        @Guide(description: "The translated string only. No quotes. No explanation.")
        var text: String
    }

    let model: SystemLanguageModel
    let temperature: Double

    init(temperature: Double) {
        self.model = SystemLanguageModel.default
        self.temperature = temperature
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
    /// developer's context comment to disambiguate.
    /// - Returns: The translated text, trimmed of surrounding whitespace.
    /// - Throws: Any `LanguageModelSession.GenerationError` from the underlying call,
    ///   or a `URLError`-style transport error in pathological cases.
    func translate(
        source: String,
        comment: String?,
        into locale: TargetLocale
    ) async throws -> String {
        let instructions = Self.instructions(for: locale)
        let session = LanguageModelSession(instructions: instructions)
        let prompt = Self.prompt(source: source, comment: comment)
        let options = GenerationOptions(temperature: temperature)
        let response = try await session.respond(
            to: prompt,
            generating: Translation.self,
            options: options
        )
        return response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the per-locale instructions block.
    ///
    /// The exact phrase "You MUST respond in {LANGUAGE}" is documented by Apple as the
    /// recommended pattern for forcing the model's output language. The source string
    /// is delimited with `<<<` / `>>>` markers in the prompt so multi-line sources
    /// don't collapse into single-line translations.
    private static func instructions(for locale: TargetLocale) -> String {
        """
        You are a professional iOS app localization translator.
        Translate the source string (between the <<< and >>> markers) into \(locale.englishDisplayName).
        You MUST respond in \(locale.englishDisplayName).
        Use the developer's context comment to inform tone, brevity, and grammar.
        Preserve every format specifier (%@, %d, %lld, %1$@, %2$d, etc.) exactly as-is.
        Preserve every line break: if the source has multiple lines, the translation must have the same number of lines in the same positions.
        Do not include the <<< or >>> markers in your response.
        Do not add quotation marks, markdown, or any explanation.
        """
    }

    /// Builds the per-string prompt. Wraps the source in `<<<` / `>>>` delimiters so
    /// the model can unambiguously recognize where the source ends, and includes an
    /// explicit line-count constraint — without this, the model tends to collapse
    /// short multi-line sources into a single sentence when the target language reads
    /// more naturally that way.
    private static func prompt(source: String, comment: String?) -> String {
        let context = comment?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "no context provided"
        let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
        let lineRequirement = lineCount > 1
            ? "The source has exactly \(lineCount) lines. Your translation MUST also have exactly \(lineCount) lines, separated by line breaks in the same positions."
            : "The source is a single line. Your translation MUST also be a single line."
        return """
        Context: \(context)
        \(lineRequirement)
        Source:
        <<<
        \(source)
        >>>
        """
    }
}

private extension String {
    /// Returns `nil` for an empty string, otherwise `self`. Useful for collapsing empty
    /// strings into optionals via `??`.
    var nonEmpty: String? { isEmpty ? nil : self }
}

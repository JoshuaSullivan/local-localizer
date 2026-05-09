import ArgumentParser
import Foundation
import FoundationModels

/// Command-line entry point.
///
/// Detects the input file format from the extension and dispatches to the matching
/// ``CatalogDocument`` implementation. Iterates `(entry × locale)` sequentially,
/// asking ``Translator`` for each translation, and saves the document to disk after
/// every successful translation so a crash mid-run loses at most one in-flight call.
@main
struct LocalLocalizer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "local-localizer",
        abstract: "Translate a String Catalog (.xcstrings) or legacy .strings file into multiple locales using Apple Foundation Models."
    )

    @Argument(help: "Path to a .xcstrings or .strings file.")
    var input: String

    @Option(name: .long, help: ArgumentHelp(
        "Comma-separated locale identifiers (e.g., fr,de,pt-BR).",
        discussion: "Defaults to French, German, Spanish, Italian, Brazilian Portuguese, Simplified Chinese, Traditional Chinese, Japanese, Korean."
    ))
    var locales: String?

    @Option(name: .customLong("source-locale"), help: ArgumentHelp(
        "Source language for legacy .strings files.",
        discussion: "Ignored for .xcstrings (read from the file's sourceLanguage field). For .strings, defaults to the parent .lproj directory name (Base.lproj → en)."
    ))
    var sourceLocale: String?

    @Flag(name: .long, help: "Re-translate keys even when the target locale already has a translation.")
    var overwrite = false

    @Option(name: .long, help: "Write .xcstrings result to a different path. Ignored for .strings input.")
    var output: String?

    @Option(name: .long, help: "Sampling temperature (0.0–2.0). Lower values are more deterministic.")
    var temperature: Double = 0.2

    @Flag(name: .long, help: "Print the work plan; don't call the model or write any files.")
    var dryRun = false

    @Flag(name: [.short, .long], help: "Include translation prompts in the progress log.")
    var verbose = false

    func run() async throws {
        let inputURL = URL(filePath: input)
        let extLower = inputURL.pathExtension.lowercased()

        let translator = Translator(temperature: temperature)
        try translator.verifyAvailability()

        let document: any CatalogDocument
        switch extLower {
        case "xcstrings":
            let outputURL = output.map { URL(filePath: $0) } ?? inputURL
            let xc = try XCStringsDocument(inputPath: inputURL, outputPath: outputURL)
            for notice in xc.skipped {
                FileHandle.standardError.write(Data("warning: \(notice.key): \(notice.reason)\n".utf8))
            }
            document = xc
        case "strings":
            if output != nil {
                FileHandle.standardError.write(Data("warning: --output is ignored for .strings input; per-locale files are written to sibling .lproj directories\n".utf8))
            }
            document = try LegacyStringsDocument(inputPath: inputURL, explicitSourceLocale: sourceLocale)
        default:
            throw ValidationError("Unsupported file extension '.\(extLower)'. Supported extensions: .xcstrings, .strings")
        }

        let requestedLocales = parseLocales()
        let supported = requestedLocales.filter { translator.supports($0) }
        for unsupported in requestedLocales where !translator.supports(unsupported) {
            FileHandle.standardError.write(Data("warning: locale '\(unsupported.identifier)' is not supported by Apple Intelligence; skipping\n".utf8))
        }
        guard !supported.isEmpty else {
            throw ValidationError("No supported target locales remain after filtering.")
        }

        let totalUnits = document.entries.count * supported.count
        let progress = ConsoleProgress(total: totalUnits, verbose: verbose)

        var index = 0
        for entry in document.entries {
            for locale in supported {
                index += 1

                if !overwrite, document.hasTranslation(forKey: entry.key, locale: locale.identifier) {
                    progress.reportSkip(index: index, locale: locale.identifier, key: entry.key, reason: "already translated")
                    continue
                }

                if entry.sourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    progress.reportSkip(index: index, locale: locale.identifier, key: entry.key, reason: "empty source value")
                    continue
                }

                if dryRun {
                    progress.reportSuccess(index: index, locale: locale.identifier, key: entry.key, translation: "(dry run)", prompt: nil)
                    continue
                }

                do {
                    let translated = try await translator.translate(
                        source: entry.sourceValue,
                        comment: entry.comment,
                        into: locale
                    )
                    if translated.isEmpty {
                        progress.reportSkip(index: index, locale: locale.identifier, key: entry.key, reason: "model returned empty result")
                        continue
                    }
                    try document.setTranslation(translated, forKey: entry.key, locale: locale.identifier)
                    try document.save()
                    progress.reportSuccess(
                        index: index,
                        locale: locale.identifier,
                        key: entry.key,
                        translation: translated,
                        prompt: verbose ? entry.sourceValue : nil
                    )
                } catch {
                    progress.warn("[\(locale.identifier) \(entry.key)] \(error.localizedDescription)")
                }
            }
        }
    }

    /// Parses the comma-separated `--locales` argument, falling back to
    /// ``TargetLocale/defaults`` when the user passed nothing.
    private func parseLocales() -> [TargetLocale] {
        guard let raw = locales?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return TargetLocale.defaults
        }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(TargetLocale.init(identifier:))
    }
}

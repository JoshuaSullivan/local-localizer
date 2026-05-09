import ArgumentParser
import Foundation
import FoundationModels

/// Command-line entry point.
///
/// Detects the input file format from the extension and dispatches to the matching
/// ``CatalogDocument`` implementation. For each entry, fans out one concurrent
/// translation per `(locale, plural-category)` pair, then applies the results and
/// persists the document. The semaphore caps simultaneous in-flight model calls
/// so we don't oversubscribe the on-device model.
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

    @Option(name: .long, help: "Path to a JSON glossary (do-not-translate list, term mappings, per-locale tone).")
    var glossary: String?

    @Option(name: .long, help: ArgumentHelp(
        "Default tone for translations.",
        discussion: "One of: formal, informal, neutral, professional, polite. Per-locale overrides come from the glossary file."
    ))
    var tone: Tone?

    @Option(name: .long, help: ArgumentHelp(
        "State to write into new translations.",
        discussion: "One of: translated, needs_review. Default: needs_review (machine translations should be reviewed before shipping)."
    ))
    var state: TranslationState = .needsReview

    @Flag(name: .long, help: "Validate without translating: exit 0 if everything is current, 1 if any key is missing or needs review.")
    var check = false

    @Option(name: .long, help: "Comma-separated list of keys to translate (others are ignored).")
    var keys: String?

    @Option(name: .customLong("keys-from"), help: "Path to a newline-separated list of keys to translate.")
    var keysFrom: String?

    @Option(name: .long, help: "Maximum simultaneous in-flight translation calls. Default: number of target locales (capped at 9).")
    var concurrency: Int?

    func run() async throws {
        let inputURL = URL(filePath: input)
        let extLower = inputURL.pathExtension.lowercased()

        let glossaryURL = glossary.map { URL(filePath: $0) }
        let resolvedGlossary = try Glossary.load(from: glossaryURL)

        let translator = Translator(
            temperature: temperature,
            glossary: resolvedGlossary,
            cliTone: tone
        )
        // --check shouldn't require Apple Intelligence to be enabled.
        if !check {
            try translator.verifyAvailability()
        }

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

        // Warn once per unknown plural-locale.
        var warnedPluralLocales: Set<String> = []
        for locale in supported where !PluralCategories.isKnown(locale.identifier) {
            if warnedPluralLocales.insert(locale.identifier).inserted {
                FileHandle.standardError.write(Data("warning: locale '\(locale.identifier)' has no hardcoded plural rule; falling back to one/other\n".utf8))
            }
        }

        let keyFilter = try buildKeyFilter(documentKeys: Set(document.entries.map(\.key)))
        let entries = filterEntries(document.entries, keyFilter: keyFilter)

        // Plan all the (entry, locale, plural-category, source) tuples that need work.
        let plan = planWork(entries: entries, supported: supported, document: document)
        let totalUnits = plan.count

        if check {
            runCheckMode(plan: plan, supported: supported)
            if totalUnits > 0 { throw ExitCode(1) }
            return
        }

        let progress = ConsoleProgress(total: totalUnits, verbose: verbose)

        if dryRun {
            for (index, unit) in plan.enumerated() {
                progress.reportSuccess(
                    index: index + 1,
                    locale: unit.locale.identifier,
                    key: unit.displayKey,
                    translation: "(dry run)",
                    prompt: nil
                )
            }
            return
        }

        let maxConcurrency = max(1, concurrency ?? min(9, supported.count))
        let semaphore = AsyncSemaphore(value: maxConcurrency)
        let outputState = state
        var index = 0

        // Group plan units by entry key so we can save once per key.
        let unitsByEntry = Dictionary(grouping: plan, by: \.entryKey)
        for entry in entries {
            guard let entryUnits = unitsByEntry[entry.key], !entryUnits.isEmpty else { continue }

            let collected = await withTaskGroup(of: TranslationResult?.self) { group -> [TranslationResult] in
                for unit in entryUnits {
                    let unitCopy = unit
                    let translatorCopy = translator
                    group.addTask {
                        return await semaphore.with {
                            do {
                                let translation = try await translatorCopy.translate(
                                    source: unitCopy.sourceValue,
                                    comment: unitCopy.comment,
                                    into: unitCopy.locale,
                                    pluralCategory: unitCopy.pluralCategory
                                )
                                if translation.isEmpty {
                                    return TranslationResult(unit: unitCopy, value: nil, skipReason: "model returned empty result")
                                }
                                return TranslationResult(unit: unitCopy, value: translation, skipReason: nil)
                            } catch {
                                return TranslationResult(unit: unitCopy, value: nil, skipReason: error.localizedDescription)
                            }
                        }
                    }
                }
                var results: [TranslationResult] = []
                for await result in group {
                    if let result { results.append(result) }
                }
                return results
            }

            // Apply results sequentially in the same order they appear in entryUnits
            // so progress lines stay deterministic across runs.
            let resultsByDescriptor = Dictionary(uniqueKeysWithValues: collected.map {
                ($0.unit.descriptor, $0)
            })
            for unit in entryUnits {
                index += 1
                guard let result = resultsByDescriptor[unit.descriptor] else { continue }
                if let translation = result.value {
                    try document.setTranslation(
                        translation,
                        forKey: entry.key,
                        locale: unit.locale.identifier,
                        pluralCategory: unit.pluralCategory,
                        state: outputState
                    )
                    progress.reportSuccess(
                        index: index,
                        locale: unit.locale.identifier,
                        key: unit.displayKey,
                        translation: translation,
                        prompt: verbose ? unit.sourceValue : nil
                    )
                } else if let reason = result.skipReason {
                    progress.warn("[\(unit.locale.identifier) \(unit.displayKey)] \(reason)")
                }
            }
            try document.save()
        }
    }

    // MARK: - Argument parsing helpers

    /// Parses the comma-separated `--locales` argument, falling back to defaults.
    private func parseLocales() -> [TargetLocale] {
        guard let raw = locales?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return TargetLocale.defaults
        }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(TargetLocale.init(identifier:))
    }

    /// Builds the optional set of keys the orchestration loop should consider, from
    /// `--keys` (comma-separated) and `--keys-from` (newline-separated file). Returns
    /// `nil` when neither flag is supplied (i.e. translate everything).
    private func buildKeyFilter(documentKeys: Set<String>) throws -> Set<String>? {
        var requested: Set<String> = []
        if let keys = keys?.trimmingCharacters(in: .whitespaces), !keys.isEmpty {
            for part in keys.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { requested.insert(trimmed) }
            }
        }
        if let path = keysFrom?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            let url = URL(filePath: path)
            let body = try String(contentsOf: url, encoding: .utf8)
            for line in body.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { requested.insert(trimmed) }
            }
        }
        guard !requested.isEmpty else { return nil }
        let unknown = requested.subtracting(documentKeys)
        for key in unknown.sorted() {
            FileHandle.standardError.write(Data("warning: requested key '\(key)' not found in catalog; skipping\n".utf8))
        }
        return requested.intersection(documentKeys)
    }

    private func filterEntries(_ entries: [CatalogEntry], keyFilter: Set<String>?) -> [CatalogEntry] {
        guard let keyFilter else { return entries }
        return entries.filter { keyFilter.contains($0.key) }
    }

    // MARK: - Planning

    /// One unit of work: translate one source value into one (locale, plural-category)
    /// destination. The orchestrator builds these up-front so progress totals are
    /// accurate and `--check` can report without doing any model work.
    private struct WorkUnit: Sendable {
        let entryKey: String
        let comment: String?
        let sourceValue: String
        let locale: TargetLocale
        let pluralCategory: PluralCategory?

        /// Display string for progress lines; includes the plural category when present.
        var displayKey: String {
            if let pluralCategory {
                return "\(entryKey)[\(pluralCategory.rawValue)]"
            }
            return entryKey
        }

        /// Stable identifier for matching results back to plan units.
        var descriptor: String {
            "\(entryKey)|\(locale.identifier)|\(pluralCategory?.rawValue ?? "")"
        }
    }

    /// The translation result produced by a single TaskGroup task.
    private struct TranslationResult: Sendable {
        let unit: WorkUnit
        let value: String?
        let skipReason: String?
    }

    /// Walks entries × locales × plural categories and emits one ``WorkUnit`` per
    /// `(entry, locale, category)` that genuinely needs translation right now —
    /// honoring the resumability rules and skipping empty source values.
    private func planWork(
        entries: [CatalogEntry],
        supported: [TargetLocale],
        document: any CatalogDocument
    ) -> [WorkUnit] {
        var units: [WorkUnit] = []
        for entry in entries {
            for locale in supported {
                for category in pluralCategoriesFor(entry: entry, locale: locale) {
                    if !overwrite, document.hasTranslation(forKey: entry.key, locale: locale.identifier, pluralCategory: category) {
                        continue
                    }
                    let source = sourceValue(for: category, entry: entry)
                    if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    units.append(WorkUnit(
                        entryKey: entry.key,
                        comment: entry.comment,
                        sourceValue: source,
                        locale: locale,
                        pluralCategory: category
                    ))
                }
            }
        }
        return units
    }

    /// For a given entry and target locale, the categories needing translation:
    /// `[nil]` for non-plural entries, or the locale's CLDR categories for
    /// plural entries.
    private func pluralCategoriesFor(entry: CatalogEntry, locale: TargetLocale) -> [PluralCategory?] {
        if entry.pluralForms == nil {
            return [nil]
        }
        return PluralCategories.categories(for: locale.identifier).map { Optional($0) }
    }

    /// Picks the source value to translate for a given (entry, target plural category)
    /// pair. For non-plural entries: the simple `sourceValue`. For plural entries with
    /// a target category that the source supplies directly: that exact form. Otherwise:
    /// the source's `other` form (which is always present).
    private func sourceValue(for category: PluralCategory?, entry: CatalogEntry) -> String {
        guard let category, let plurals = entry.pluralForms else {
            return entry.sourceValue
        }
        return plurals[category] ?? plurals[.other] ?? entry.sourceValue
    }

    // MARK: - Check mode

    private func runCheckMode(plan: [WorkUnit], supported: [TargetLocale]) {
        var perLocale: [String: Int] = [:]
        for locale in supported { perLocale[locale.identifier] = 0 }
        for unit in plan {
            perLocale[unit.locale.identifier, default: 0] += 1
        }
        print("local-localizer: checking \(input)")
        for locale in supported {
            let count = perLocale[locale.identifier] ?? 0
            print("  \(locale.identifier.padding(toLength: 8))  \(count) pending")
        }
        print("total: \(plan.count) pending across \(supported.count) locale(s)")
    }
}

// MARK: - ArgumentParser conformances

extension Tone: ExpressibleByArgument {}
extension TranslationState: ExpressibleByArgument {}

// MARK: - AsyncSemaphore

/// A small semaphore actor used to cap simultaneous in-flight translation calls.
/// Apple's `LanguageModelSession` allows multiple sessions to run concurrently
/// (one request per session at a time), but the on-device model itself doesn't
/// scale linearly — empirically a handful of concurrent calls is the sweet spot.
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.value = value
    }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            value += 1
        }
    }

    /// Convenience for `wait() / operation() / signal()` with proper error rethrowing.
    /// Always signals on the way out, even when the operation throws.
    func with<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await wait()
        do {
            let result = try await operation()
            signal()
            return result
        } catch {
            signal()
            throw error
        }
    }
}

private extension String {
    func padding(toLength length: Int) -> String {
        if count >= length { return self }
        return self + String(repeating: " ", count: length - count)
    }
}

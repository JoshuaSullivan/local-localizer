import Foundation

/// Errors thrown by ``XCStringsDocument`` for malformed input that the orchestration
/// layer can surface to the user.
enum XCStringsError: Error, LocalizedError {
    case invalidJSON(URL, underlying: Error)
    case missingSourceLanguage(URL)
    case malformedRoot(URL)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let url, let err):
            return "Could not parse \(url.path) as JSON: \(err.localizedDescription)"
        case .missingSourceLanguage(let url):
            return "\(url.path) has no top-level `sourceLanguage` field."
        case .malformedRoot(let url):
            return "\(url.path) is valid JSON but does not match the .xcstrings schema."
        }
    }
}

/// A modern Apple String Catalog (`.xcstrings`) document.
///
/// Backed by a `[String: Any]` tree from `JSONSerialization` to round-trip every
/// field — known or unknown — without lossy `Codable` re-encoding. The tool only
/// reads `sourceLanguage`, `strings.<key>.comment`, and the source-language
/// `stringUnit` / plural-`variations` values, and writes
/// `strings.<key>.localizations.<targetLocale>.stringUnit = {state, value}` for
/// simple entries or under `variations.plural.<category>` for plural entries.
///
/// Source entries with `device` variations are skipped in v2 with a warning
/// surfaced via ``skipped``.
final class XCStringsDocument: CatalogDocument {
    /// A note about a key skipped at load time, surfaced to the orchestrator for warning.
    struct SkipNotice {
        let key: String
        let reason: String
    }

    private let outputPath: URL
    private var root: [String: Any]
    let sourceLanguage: String
    let entries: [CatalogEntry]
    let skipped: [SkipNotice]

    /// Loads `.xcstrings` from `inputPath`. If `outputPath` differs, the constructor
    /// records the destination but does *not* copy yet — the first ``save()`` call
    /// writes the entire current tree.
    init(inputPath: URL, outputPath: URL) throws {
        self.outputPath = outputPath

        let data: Data
        do {
            data = try Data(contentsOf: inputPath)
        } catch {
            throw XCStringsError.invalidJSON(inputPath, underlying: error)
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw XCStringsError.invalidJSON(inputPath, underlying: error)
        }

        guard let dict = parsed as? [String: Any] else {
            throw XCStringsError.malformedRoot(inputPath)
        }
        self.root = dict

        guard let sourceLanguage = dict["sourceLanguage"] as? String else {
            throw XCStringsError.missingSourceLanguage(inputPath)
        }
        self.sourceLanguage = sourceLanguage

        var collectedEntries: [CatalogEntry] = []
        var skipped: [SkipNotice] = []
        let strings = dict["strings"] as? [String: Any] ?? [:]
        for key in strings.keys.sorted() {
            guard let entry = strings[key] as? [String: Any] else { continue }
            if let extractionState = entry["extractionState"] as? String, extractionState == "stale" {
                continue
            }
            let comment = entry["comment"] as? String
            let localizations = entry["localizations"] as? [String: Any] ?? [:]

            let sourceLoc = localizations[sourceLanguage] as? [String: Any]

            // Plural variations: extract one source value per CLDR category.
            if let variations = sourceLoc?["variations"] as? [String: Any] {
                if let pluralBlock = variations["plural"] as? [String: Any] {
                    let pluralForms = Self.extractPluralForms(from: pluralBlock)
                    if let other = pluralForms[.other], !pluralForms.isEmpty {
                        collectedEntries.append(CatalogEntry(
                            key: key,
                            comment: comment,
                            sourceValue: other,
                            pluralForms: pluralForms
                        ))
                        continue
                    } else {
                        skipped.append(.init(key: key, reason: "source plural variations missing the 'other' category"))
                        continue
                    }
                }
                if variations["device"] != nil {
                    skipped.append(.init(key: key, reason: "source uses device variations (v2 doesn't translate these)"))
                    continue
                }
                skipped.append(.init(key: key, reason: "source uses an unsupported variations type"))
                continue
            }

            // Simple stringUnit (or fall back to using the key as the source value).
            let sourceValue: String
            if let unit = sourceLoc?["stringUnit"] as? [String: Any],
               let value = unit["value"] as? String {
                sourceValue = value
            } else {
                sourceValue = key
            }
            collectedEntries.append(CatalogEntry(
                key: key,
                comment: comment,
                sourceValue: sourceValue,
                pluralForms: nil
            ))
        }
        self.entries = collectedEntries
        self.skipped = skipped
    }

    func hasTranslation(forKey key: String, locale: String, pluralCategory: PluralCategory?) -> Bool {
        guard let strings = root["strings"] as? [String: Any],
              let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let target = localizations[locale] as? [String: Any] else {
            return false
        }
        if let pluralCategory {
            guard let variations = target["variations"] as? [String: Any],
                  let plural = variations["plural"] as? [String: Any],
                  let category = plural[pluralCategory.rawValue] as? [String: Any],
                  let unit = category["stringUnit"] as? [String: Any] else {
                return false
            }
            return Self.unitIsCurrent(unit)
        } else {
            if let unit = target["stringUnit"] as? [String: Any] {
                return Self.unitIsCurrent(unit)
            }
            return false
        }
    }

    func setTranslation(
        _ value: String,
        forKey key: String,
        locale: String,
        pluralCategory: PluralCategory?,
        state: TranslationState
    ) throws {
        var strings = root["strings"] as? [String: Any] ?? [:]
        var entry = strings[key] as? [String: Any] ?? [:]
        var localizations = entry["localizations"] as? [String: Any] ?? [:]
        let stringUnit: [String: Any] = ["state": state.rawValue, "value": value]

        if let pluralCategory {
            var target = localizations[locale] as? [String: Any] ?? [:]
            // Plural entries can never coexist with a top-level stringUnit at the
            // same locale, so wipe that slot if some prior write left one.
            target.removeValue(forKey: "stringUnit")
            var variations = target["variations"] as? [String: Any] ?? [:]
            var plural = variations["plural"] as? [String: Any] ?? [:]
            plural[pluralCategory.rawValue] = ["stringUnit": stringUnit]
            variations["plural"] = plural
            target["variations"] = variations
            localizations[locale] = target
        } else {
            // Simple write — overwrites any prior stringUnit for that locale.
            localizations[locale] = ["stringUnit": stringUnit]
        }
        entry["localizations"] = localizations
        strings[key] = entry
        root["strings"] = strings
    }

    func save() throws {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try JSONSerialization.data(withJSONObject: root, options: options)
        // Xcode terminates the file with a trailing newline; match that.
        try (data + Data([0x0A])).write(to: outputPath, options: .atomic)
    }

    // MARK: - Private

    /// Reads source-side plural forms out of a `variations.plural` block.
    private static func extractPluralForms(from block: [String: Any]) -> [PluralCategory: String] {
        var result: [PluralCategory: String] = [:]
        for (rawCategory, raw) in block {
            guard let category = PluralCategory(rawValue: rawCategory),
                  let inner = raw as? [String: Any],
                  let unit = inner["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String,
                  !value.isEmpty else {
                continue
            }
            result[category] = value
        }
        return result
    }

    /// A `stringUnit` counts as "current" when it has a non-empty value AND its
    /// state isn't `needs_review` or `stale`. The orchestrator skips current
    /// translations and re-runs anything else.
    private static func unitIsCurrent(_ unit: [String: Any]) -> Bool {
        guard let value = unit["value"] as? String, !value.isEmpty else { return false }
        let state = unit["state"] as? String
        if state == "needs_review" || state == "stale" { return false }
        return true
    }
}

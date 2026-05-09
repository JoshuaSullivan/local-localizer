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
/// reads `sourceLanguage`, `strings.<key>.comment`, and
/// `strings.<key>.localizations.<sourceLanguage>.stringUnit.value`, and writes
/// `strings.<key>.localizations.<targetLocale>.stringUnit = {state, value}`.
///
/// Source entries that use plural / device `variations` are filtered out of
/// ``entries`` in v1 and reported via ``skipped`` so the orchestrator can warn.
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
        // Sort keys for deterministic processing order (matches Xcode's alphabetical UI).
        for key in strings.keys.sorted() {
            guard let entry = strings[key] as? [String: Any] else { continue }
            if let extractionState = entry["extractionState"] as? String, extractionState == "stale" {
                continue
            }
            let comment = entry["comment"] as? String
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            // The source string lives under localizations.<sourceLanguage>.stringUnit.value.
            // If absent, fall back to the key itself — Xcode leaves the source slot empty
            // for keys whose source string equals the key.
            let sourceValue: String
            if let sourceLoc = localizations[sourceLanguage] as? [String: Any] {
                if sourceLoc["variations"] != nil {
                    skipped.append(.init(key: key, reason: "source uses plural/device variations (v1 only handles plain stringUnit)"))
                    continue
                }
                if let unit = sourceLoc["stringUnit"] as? [String: Any],
                   let value = unit["value"] as? String {
                    sourceValue = value
                } else {
                    sourceValue = key
                }
            } else {
                sourceValue = key
            }
            collectedEntries.append(.init(key: key, comment: comment, sourceValue: sourceValue))
        }
        self.entries = collectedEntries
        self.skipped = skipped
    }

    func hasTranslation(forKey key: String, locale: String) -> Bool {
        guard let strings = root["strings"] as? [String: Any],
              let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let target = localizations[locale] as? [String: Any] else {
            return false
        }
        // Variations also count as "has translation" — we don't overwrite them.
        if target["variations"] != nil { return true }
        if let unit = target["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String,
           !value.isEmpty {
            return true
        }
        return false
    }

    func setTranslation(_ value: String, forKey key: String, locale: String) throws {
        var strings = root["strings"] as? [String: Any] ?? [:]
        var entry = strings[key] as? [String: Any] ?? [:]
        var localizations = entry["localizations"] as? [String: Any] ?? [:]
        let stringUnit: [String: Any] = ["state": "translated", "value": value]
        localizations[locale] = ["stringUnit": stringUnit]
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
}

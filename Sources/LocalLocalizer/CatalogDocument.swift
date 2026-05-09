import Foundation

/// A translatable string entry pulled from a localization document, paired with the
/// developer-supplied context comment used to disambiguate ambiguous source strings
/// (e.g. "Open" as a verb versus an adjective).
struct CatalogEntry: Sendable {
    /// The stable identifier the source code references (e.g. `helloWorld`).
    let key: String

    /// Optional translator-facing context written by the developer.
    let comment: String?

    /// The source-language string to translate.
    let sourceValue: String
}

/// Format-agnostic interface for a localization document.
///
/// Both modern `.xcstrings` String Catalogs and legacy `.strings` files conform to this
/// protocol so that the orchestration loop in ``LocalLocalizer`` can iterate entries and
/// upsert translations without branching on file format.
protocol CatalogDocument: AnyObject {
    /// The source language identifier (e.g. `en`, `en-GB`). For `.xcstrings`, read from
    /// the file's `sourceLanguage` field. For legacy `.strings`, derived from the
    /// containing `.lproj` directory or supplied via `--source-locale`.
    var sourceLanguage: String { get }

    /// All translatable entries in document order. Skipped entries (variations, stale
    /// extraction state) are omitted by the document implementation.
    var entries: [CatalogEntry] { get }

    /// Whether the document already contains a translation for the given key in the
    /// given target locale. Used to skip already-translated entries on resumed runs.
    func hasTranslation(forKey key: String, locale: String) -> Bool

    /// Insert or replace a translation for the given key in the given target locale.
    func setTranslation(_ value: String, forKey key: String, locale: String) throws

    /// Persist the current state of the document to disk. Called after every successful
    /// translation so a crash mid-run loses at most one in-flight call.
    func save() throws
}

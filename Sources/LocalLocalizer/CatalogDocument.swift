import Foundation

/// A translatable string entry pulled from a localization document.
///
/// For a simple key/value pair (the common case), `pluralForms` is `nil` and
/// `sourceValue` carries the source string. For a key with plural variations
/// in the source localization, `pluralForms` carries one entry per source-side
/// CLDR plural category (`one`, `other`, etc.) and `sourceValue` is the value
/// of the `other` form (used as a fallback when a target locale needs a plural
/// category the source doesn't supply).
struct CatalogEntry: Sendable {
    /// The stable identifier the source code references (e.g. `helloWorld`).
    let key: String

    /// Optional translator-facing context written by the developer.
    let comment: String?

    /// The source-language string for the simple case, or the source's `other`
    /// plural form when `pluralForms` is non-nil. Always non-empty.
    let sourceValue: String

    /// When non-nil, this entry uses plural variations: one source string per
    /// CLDR plural category. The map always contains at least `.other`.
    let pluralForms: [PluralCategory: String]?
}

/// The state to write into a translation slot. `.xcstrings` honors this directly
/// in the per-locale `state` field; legacy `.strings` files have no state field
/// and ignore the value.
enum TranslationState: String, Sendable {
    case translated
    case needsReview = "needs_review"
}

/// Format-agnostic interface for a localization document.
///
/// Both modern `.xcstrings` String Catalogs and legacy `.strings` files conform
/// to this protocol so the orchestration loop can iterate entries and upsert
/// translations without branching on file format. Plural-category support is
/// `.xcstrings`-only — the `.strings` implementation asserts that
/// `pluralCategory` is `nil` on every call.
protocol CatalogDocument: AnyObject {
    /// The source language identifier (e.g. `en`, `en-GB`). For `.xcstrings`,
    /// read from the file's `sourceLanguage` field. For legacy `.strings`,
    /// derived from the containing `.lproj` directory or supplied via
    /// `--source-locale`.
    var sourceLanguage: String { get }

    /// All translatable entries in document order. Entries that are entirely
    /// stale or unsupported (in v1) are filtered out by the implementation.
    var entries: [CatalogEntry] { get }

    /// Whether the document already has a usable translation for the given
    /// `(key, locale)` (and `pluralCategory` for plural entries). Translations
    /// in the `needs_review` state are treated as *not* usable so they get
    /// re-translated on the next run.
    func hasTranslation(forKey key: String, locale: String, pluralCategory: PluralCategory?) -> Bool

    /// Insert or replace a translation. `state` is honored by `.xcstrings` and
    /// ignored by legacy `.strings`. `pluralCategory` is required for plural
    /// entries and a programming error for legacy `.strings`.
    func setTranslation(
        _ value: String,
        forKey key: String,
        locale: String,
        pluralCategory: PluralCategory?,
        state: TranslationState
    ) throws

    /// Persist the current state of the document to disk.
    func save() throws
}

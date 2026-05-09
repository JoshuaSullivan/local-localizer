import Foundation

/// Errors thrown by ``LegacyStringsDocument`` for malformed input or convention violations.
enum LegacyStringsError: Error, LocalizedError {
    case notInsideLproj(URL)
    case sourceLanguageUnresolvable(URL)
    case unreadable(URL, underlying: Error)
    case parseError(URL, line: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notInsideLproj(let url):
            return "\(url.path) is not inside an .lproj directory. Move it under (e.g.) en.lproj/ or pass --source-locale and a path inside an .lproj dir."
        case .sourceLanguageUnresolvable(let url):
            return "Cannot infer the source language for \(url.path). The parent directory \"\(url.deletingLastPathComponent().lastPathComponent)\" is not a recognized .lproj name. Pass --source-locale to disambiguate."
        case .unreadable(let url, let err):
            return "Could not read \(url.path): \(err.localizedDescription)"
        case .parseError(let url, let line, let message):
            return "\(url.path):\(line): \(message)"
        }
    }
}

/// A single parsed `.strings` entry: an optional comment plus its key and value.
private struct LegacyEntry {
    let comment: String?
    let key: String
    let value: String
}

/// A legacy `.strings` localization document.
///
/// Reads a single source-language `.strings` file (which must live inside an `.lproj`
/// directory). Per-locale outputs are written as sibling `<locale>.lproj/<filename>`
/// files next to the input. Each per-locale output file is loaded lazily on first
/// query so already-translated keys can be skipped on resumed runs.
final class LegacyStringsDocument: CatalogDocument {
    private let inputPath: URL
    private let outputContainerDir: URL
    private let outputFilename: String
    private let sourceEntries: [LegacyEntry]
    /// Per-locale state: ordered (key, value) pairs, built from existing output file +
    /// new translations. We keep the order matching the source file's entry order.
    private var perLocale: [String: [String: String]] = [:]
    private var loadedLocales: Set<String> = []
    private var dirtyLocales: Set<String> = []

    let sourceLanguage: String
    let entries: [CatalogEntry]
    let skipped: [XCStringsDocument.SkipNotice] = []

    /// Loads the source `.strings` file. Throws ``LegacyStringsError`` for malformed
    /// inputs or convention violations.
    /// - Parameters:
    ///   - inputPath: Path to a `.strings` file inside an `.lproj` directory.
    ///   - explicitSourceLocale: User-supplied `--source-locale` override. If `nil`, the
    ///     source language is inferred from the parent `.lproj` directory name (with
    ///     `Base.lproj` defaulting to `en`).
    init(inputPath: URL, explicitSourceLocale: String?) throws {
        self.inputPath = inputPath
        self.outputFilename = inputPath.lastPathComponent

        let parent = inputPath.deletingLastPathComponent()
        let parentName = parent.lastPathComponent
        guard parentName.hasSuffix(".lproj") else {
            throw LegacyStringsError.notInsideLproj(inputPath)
        }
        self.outputContainerDir = parent.deletingLastPathComponent()

        if let explicit = explicitSourceLocale {
            self.sourceLanguage = explicit
        } else {
            let stem = String(parentName.dropLast(".lproj".count))
            if stem.isEmpty {
                throw LegacyStringsError.sourceLanguageUnresolvable(inputPath)
            }
            // "Base.lproj" by Apple convention typically maps to the development
            // region — default to English.
            self.sourceLanguage = (stem == "Base") ? "en" : stem
        }

        let source: String
        do {
            source = try String(contentsOf: inputPath, encoding: .utf8)
        } catch {
            // Fall back to the older UTF-16 encoding some legacy .strings files use.
            do {
                source = try String(contentsOf: inputPath, encoding: .utf16)
            } catch {
                throw LegacyStringsError.unreadable(inputPath, underlying: error)
            }
        }

        let parsed = try Self.parse(source: source, fileURL: inputPath)
        self.sourceEntries = parsed
        self.entries = parsed.map {
            CatalogEntry(key: $0.key, comment: $0.comment, sourceValue: $0.value)
        }
    }

    func hasTranslation(forKey key: String, locale: String) -> Bool {
        ensureLocaleLoaded(locale)
        return perLocale[locale]?[key]?.isEmpty == false
    }

    func setTranslation(_ value: String, forKey key: String, locale: String) throws {
        ensureLocaleLoaded(locale)
        perLocale[locale, default: [:]][key] = value
        dirtyLocales.insert(locale)
    }

    func save() throws {
        for locale in dirtyLocales {
            try writeLocale(locale)
        }
        dirtyLocales.removeAll()
    }

    // MARK: - Private

    /// Lazily reads any pre-existing translations for `locale` from disk so that
    /// resumed runs skip already-translated keys.
    private func ensureLocaleLoaded(_ locale: String) {
        guard !loadedLocales.contains(locale) else { return }
        loadedLocales.insert(locale)
        let file = outputFile(for: locale)
        guard FileManager.default.fileExists(atPath: file.path) else {
            perLocale[locale] = [:]
            return
        }
        let raw: String
        do {
            raw = try String(contentsOf: file, encoding: .utf8)
        } catch {
            // If the existing per-locale file is unreadable we treat it as empty rather
            // than abort — the user can delete it and retry. Warn via stderr.
            FileHandle.standardError.write(Data("warning: could not read existing \(file.path): \(error.localizedDescription)\n".utf8))
            perLocale[locale] = [:]
            return
        }
        do {
            let existing = try Self.parse(source: raw, fileURL: file)
            perLocale[locale] = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0.value) })
        } catch {
            FileHandle.standardError.write(Data("warning: could not parse existing \(file.path): \(error.localizedDescription)\n".utf8))
            perLocale[locale] = [:]
        }
    }

    /// Resolves the absolute path of the per-locale output file.
    private func outputFile(for locale: String) -> URL {
        outputContainerDir
            .appending(path: "\(locale).lproj", directoryHint: .isDirectory)
            .appending(path: outputFilename, directoryHint: .notDirectory)
    }

    /// Writes a single per-locale output file. Iterates the source entries in their
    /// original order so the translation file mirrors the source layout, with the
    /// source comment retained as context.
    private func writeLocale(_ locale: String) throws {
        let file = outputFile(for: locale)
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let translations = perLocale[locale] ?? [:]
        var output = ""
        for (index, entry) in sourceEntries.enumerated() {
            guard let value = translations[entry.key] else { continue }
            if let comment = entry.comment, !comment.isEmpty {
                output.append("/* \(comment) */\n")
            }
            output.append("\"\(Self.escape(entry.key))\" = \"\(Self.escape(value))\";\n")
            if index < sourceEntries.count - 1 {
                output.append("\n")
            }
        }
        try output.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Parsing

    /// Parses the `.strings` source text into ordered `LegacyEntry` values.
    ///
    /// Recognises `/* block */` and `// line` comments (concatenated with `\n` if
    /// multiple precede an entry), `"key" = "value";` pairs, and the standard escape
    /// sequences (`\"`, `\\`, `\n`, `\t`, `\r`, `\0`).
    private static func parse(source: String, fileURL: URL) throws -> [LegacyEntry] {
        var entries: [LegacyEntry] = []
        var pendingComments: [String] = []
        var i = source.startIndex
        var line = 1

        func bumpLine(through end: String.Index) {
            var c = i
            while c < end {
                if source[c] == "\n" { line += 1 }
                c = source.index(after: c)
            }
        }

        while i < source.endIndex {
            let c = source[i]

            if c.isWhitespace {
                if c == "\n" { line += 1 }
                i = source.index(after: i)
                continue
            }

            if source[i...].hasPrefix("/*") {
                let openLine = line
                let bodyStart = source.index(i, offsetBy: 2)
                guard let closeRange = source.range(of: "*/", range: bodyStart..<source.endIndex) else {
                    throw LegacyStringsError.parseError(fileURL, line: openLine, message: "unterminated /* block comment")
                }
                let comment = String(source[bodyStart..<closeRange.lowerBound])
                pendingComments.append(comment.trimmingCharacters(in: .whitespacesAndNewlines))
                bumpLine(through: closeRange.upperBound)
                i = closeRange.upperBound
                continue
            }

            if source[i...].hasPrefix("//") {
                let bodyStart = source.index(i, offsetBy: 2)
                let lineEnd = source[bodyStart...].firstIndex(of: "\n") ?? source.endIndex
                pendingComments.append(String(source[bodyStart..<lineEnd]).trimmingCharacters(in: .whitespaces))
                if lineEnd < source.endIndex {
                    line += 1
                    i = source.index(after: lineEnd)
                } else {
                    i = source.endIndex
                }
                continue
            }

            if c == "\"" {
                let entryStartLine = line
                let (key, afterKey) = try parseQuotedString(in: source, startingAt: i, fileURL: fileURL, line: line)
                bumpLine(through: afterKey)
                i = skipWhitespace(in: source, from: afterKey, line: &line)

                guard i < source.endIndex, source[i] == "=" else {
                    throw LegacyStringsError.parseError(fileURL, line: entryStartLine, message: "expected '=' after key \"\(key)\"")
                }
                i = source.index(after: i)
                i = skipWhitespace(in: source, from: i, line: &line)

                guard i < source.endIndex, source[i] == "\"" else {
                    throw LegacyStringsError.parseError(fileURL, line: entryStartLine, message: "expected quoted value after '=' for key \"\(key)\"")
                }
                let (value, afterValue) = try parseQuotedString(in: source, startingAt: i, fileURL: fileURL, line: line)
                bumpLine(through: afterValue)
                i = skipWhitespace(in: source, from: afterValue, line: &line)

                guard i < source.endIndex, source[i] == ";" else {
                    throw LegacyStringsError.parseError(fileURL, line: entryStartLine, message: "expected ';' after value for key \"\(key)\"")
                }
                i = source.index(after: i)

                let combinedComment = pendingComments.isEmpty
                    ? nil
                    : pendingComments.joined(separator: "\n")
                entries.append(LegacyEntry(comment: combinedComment, key: key, value: value))
                pendingComments = []
                continue
            }

            throw LegacyStringsError.parseError(fileURL, line: line, message: "unexpected character '\(c)'")
        }

        return entries
    }

    /// Parses a `"…"` literal starting at the opening quote. Returns the unescaped value
    /// plus the index immediately after the closing quote.
    private static func parseQuotedString(
        in source: String,
        startingAt start: String.Index,
        fileURL: URL,
        line: Int
    ) throws -> (String, String.Index) {
        var result = ""
        var i = source.index(after: start)
        while i < source.endIndex {
            let c = source[i]
            if c == "\"" {
                return (result, source.index(after: i))
            }
            if c == "\\" {
                let next = source.index(after: i)
                guard next < source.endIndex else {
                    throw LegacyStringsError.parseError(fileURL, line: line, message: "unterminated escape sequence")
                }
                let esc = source[next]
                switch esc {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "0": result.append("\0")
                case "'": result.append("'")
                default:
                    // Pass unknown escapes through verbatim (keeping the backslash) so we
                    // don't silently corrupt unusual content.
                    result.append("\\")
                    result.append(esc)
                }
                i = source.index(after: next)
                continue
            }
            result.append(c)
            i = source.index(after: i)
        }
        throw LegacyStringsError.parseError(fileURL, line: line, message: "unterminated string literal")
    }

    private static func skipWhitespace(
        in source: String,
        from start: String.Index,
        line: inout Int
    ) -> String.Index {
        var i = start
        while i < source.endIndex, source[i].isWhitespace {
            if source[i] == "\n" { line += 1 }
            i = source.index(after: i)
        }
        return i
    }

    /// Escapes a value for `.strings` output. Inverse of the parser's escape handling.
    private static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for c in value {
            switch c {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            case "\r": out.append("\\r")
            default: out.append(c)
            }
        }
        return out
    }
}

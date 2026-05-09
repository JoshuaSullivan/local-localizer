import Foundation

/// Compact stdout progress reporter for the translation loop.
///
/// Output format: `[3/420] de  hello_world → Hallo`
///
/// In `--verbose` mode each translation also gets a `prompt:` line.
struct ConsoleProgress: Sendable {
    let total: Int
    let verbose: Bool

    init(total: Int, verbose: Bool) {
        self.total = total
        self.verbose = verbose
    }

    /// Emits a single completed-translation line.
    func reportSuccess(
        index: Int,
        locale: String,
        key: String,
        translation: String,
        prompt: String?
    ) {
        let truncated = translation.singleLinePreview(maxLength: 80)
        print("[\(index)/\(total)] \(locale.padding(toLength: 7))  \(key) → \(truncated)")
        if verbose, let prompt {
            print("    prompt: \(prompt.singleLinePreview(maxLength: 200))")
        }
    }

    /// Emits a skipped-entry line at less prominence.
    func reportSkip(index: Int, locale: String, key: String, reason: String) {
        print("[\(index)/\(total)] \(locale.padding(toLength: 7))  \(key) ⊘ \(reason)")
    }

    /// Emits a non-fatal warning that doesn't tie to a specific entry.
    func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }

    /// Emits a fatal error message before the process exits.
    func error(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }
}

private extension String {
    /// Collapses internal whitespace to a single space and truncates to `maxLength`,
    /// suffixing with `…` if truncated. Used to keep progress lines on one terminal row.
    func singleLinePreview(maxLength: Int) -> String {
        let collapsed = split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if collapsed.count <= maxLength {
            return collapsed
        }
        return collapsed.prefix(maxLength - 1) + "…"
    }

    func padding(toLength length: Int) -> String {
        if count >= length { return self }
        return self + String(repeating: " ", count: length - count)
    }
}

# local-localizer

A macOS command-line tool that machine-translates an iOS/macOS String Catalog (`.xcstrings`) or legacy `.strings` file into multiple locales using the on-device Apple Foundation Models framework.

Translations run entirely on-device. No API keys, no network, no per-call cost.

## Requirements

- macOS 26 or later
- Apple Silicon
- Apple Intelligence enabled (System Settings → Apple Intelligence & Siri)
- Xcode 27 toolchain (for building from source)

## Install

```sh
swift build -c release
cp .build/release/local-localizer /usr/local/bin/
```

Or use SwiftPM's installer (puts it in `~/.swiftpm/bin`, which you'll need on `PATH`):

```sh
swift package experimental-install
```

## Usage

```
local-localizer <input> [options]
```

### String Catalog (`.xcstrings`)

In-place modification of the input file. All locales live in the same JSON file.

```sh
local-localizer Resources/Localizable.xcstrings
local-localizer Resources/Localizable.xcstrings --locales fr,de,ja
local-localizer Resources/Localizable.xcstrings --output /tmp/translated.xcstrings
```

### Legacy `.strings`

Per-locale outputs are written to sibling `<locale>.lproj/` directories next to the input.

```sh
local-localizer Project/en.lproj/Localizable.strings
# produces Project/fr.lproj/Localizable.strings, Project/de.lproj/..., etc.
```

The input must live inside an `.lproj` directory. Source language is inferred from the parent directory name (`en.lproj` → `en`, `Base.lproj` → `en`); pass `--source-locale` to override.

## Options

| Flag | Default | Purpose |
|---|---|---|
| `<input>` | — (required) | Path to a `.xcstrings` or `.strings` file |
| `--locales` | the nine defaults below | Comma-separated locale identifiers |
| `--source-locale` | inferred | Source language for legacy `.strings` (ignored for `.xcstrings`) |
| `--overwrite` | off | Re-translate keys even if a translation already exists |
| `--output` | in-place | `.xcstrings` only: write to a different path |
| `--temperature` | `0.2` | Sampling temperature, 0.0–2.0 |
| `--dry-run` | off | Print the work plan, don't call the model or write files |
| `-v`, `--verbose` | off | Include source prompts in the progress log |

## Default locales

| Display name | Identifier |
|---|---|
| French | `fr` |
| German | `de` |
| Spanish | `es` |
| Italian | `it` |
| Brazilian Portuguese | `pt-BR` |
| Simplified Chinese | `zh-Hans` |
| Traditional Chinese | `zh-Hant` |
| Japanese | `ja` |
| Korean | `ko` |

## Resumability

Already-translated keys are skipped by default, so you can interrupt a long run with Ctrl-C and re-invoke the same command to pick up where it left off. Pass `--overwrite` to re-translate everything.

For `.xcstrings`, "already translated" means the key has a `stringUnit` for that locale. For `.strings`, it means the per-locale output file already contains an entry for that key.

## Notes and limitations

- **Hand-review the output.** These are machine translations. The tool sets each new translation's state to `translated` — but for production strings you should still review them in Xcode or with a native speaker.
- **Format specifiers (`%@`, `%d`, `%lld`, `%1$@`, etc.) are preserved** because the model is instructed to leave them as-is, and the source comment helps it understand context.
- **Plural and device variations are skipped (with a warning) in v1.** Entries that use `variations` (`.xcstrings` plurals/device branches, or `.stringsdict` files) are not translated.
- **Multi-line sources may collapse to a single line in some target languages.** The on-device model occasionally prefers a single sentence over preserving the exact line layout, even with explicit instructions.
- **Comments matter.** The developer comment (`/* ... */` in `.strings` or `comment` in `.xcstrings`) is sent to the model as disambiguation context. Strings like "Open" or "Mark" translate noticeably better with a comment like "Verb, button label" than without.

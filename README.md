# l10n_health

> Read the article: [A health check for your Flutter translations](https://medium.com/@noatubic/a-health-check-for-your-flutter-translations-936fe2e35917)

A health check for the translation layer of Dart and Flutter apps.

`l10n_health` reads your `.arb` files and your Dart code together, and
reports what neither the analyzer nor the code generator will tell you:
keys nobody uses, translations that are missing or were never translated,
placeholders that differ between languages, text that bypasses localization
entirely, and invisible characters hiding in your strings. It can then prune
the dead keys for you, safely.

It works with Flutter's built-in `gen_l10n`, with `flutter_intl` /
`intl_utils`, and with any other ARB-based setup. Configuration is
optional; the setup is detected from `l10n.yaml` or `pubspec.yaml`.

```text
$ l10n_health
l10n_health  flutter_intl · template de · 2439 keys · 2931 Dart files · strict usage · 235 ms

  Locales   de 2434  en 2406

Placeholder mismatches (placeholder_mismatch)  2
  error lib/l10n/intl_en.arb:313:3  Placeholders in "hint1" differ from de: missing {day} {month} {year}, unexpected {DateTime}
  ...
Malformed ICU messages (icu_syntax)  2
  error lib/l10n/intl_de.arb:1801:3  Malformed message "delivery_address_semantics_label": select has no "other" branch
  ...
Missing translations (missing_translation)  38
Invisible Unicode (invisible_unicode)  10
  warn  lib/l10n/intl_de.arb:1060:25  U+200B ZERO WIDTH SPACE in "order_again"
Hardcoded strings (hardcoded_string)  247
  warn  lib/.../select_satellite_pharmacy_page.dart:34:61  Hardcoded text "Filiale wählen" bypasses localization (prose with non-ASCII letters)
Unused keys (unused_key)  365
...
```

## Install

```sh
dart pub global activate l10n_health
```

or as a dev dependency, to pin the version per project:

```sh
dart pub add --dev l10n_health
dart run l10n_health
```

## Usage

```sh
l10n_health                              # check, terminal output
l10n_health --format html -o l10n.html   # browsable, self-contained report
l10n_health --format md -o L10N.md       # for merge requests and wikis
l10n_health --format json                # for scripts and dashboards
l10n_health --only unused_key,missing_translation

l10n_health prune                        # dry run: what would be removed
l10n_health prune --apply                # remove unused keys from every locale
l10n_health sort                         # sort keys, metadata kept with its key
l10n_health sort --check                 # CI: fail if a file is unsorted
l10n_health init                         # write a starter l10n_health.yaml
```

Useful flags: `--keep 'error_*,dyn_*'` for keys read dynamically,
`--sources lib,packages/ui/lib` for monorepos (Pub workspace members are
picked up automatically), `--quiet` for counts only, and `--format gitlab`
or `--format github` for merge-request and pull-request annotations.

Exit codes: `0` ok, `1` findings at or above `--fail-on` (default `error`),
`64` usage or configuration error.

## Checks

| Check | Default | What it finds |
|---|---|---|
| `arb_syntax` | error | ARB file that is not valid JSON |
| `duplicate_key` | error | Key defined twice in one file. JSON parsers keep the last one silently |
| `placeholder_mismatch` | error | Translation whose `{placeholders}` differ from the template, or from its `@key` metadata |
| `icu_syntax` | error | Unbalanced braces, broken `plural`/`select`, missing `other` branch |
| `plural_forms` | warning | Plural lacking a CLDR category its language needs (Croatian `few`, Polish `many`), or carrying one it never selects |
| `locale_tag` | warning | `@@locale` missing or disagreeing with the file name |
| `missing_translation` | warning | Key present in one locale and absent in another, in both directions |
| `empty_translation` | warning | Translation that is an empty string |
| `invisible_unicode` | warning | Zero-width characters, bidi controls, look-alike spaces, soft hyphens and Unicode tag characters, in ARB files and Dart code |
| `hardcoded_string` | warning | Text in Dart code that bypasses localization |
| `unused_key` | warning | Key never read from Dart code |
| `orphan_metadata` | info | `@key` metadata whose key no longer exists |
| `untranslated` | info | Value identical in the template and another locale |
| `duplicate_value` | info | Several keys holding the same text |
| `key_naming` | off | Keys not in the configured style (`camelCase`, `snake_case` or a regex) |
| `missing_description` | off | Template keys without an `@key` description for translators |

Keys whose metadata says `"x-ignore": true`, or whose description says "do
not translate", are skipped by `untranslated` and `duplicate_value`.

### How unused keys are found

`strict` mode (the default when the localizations class is known) counts a
key as used only when it is read through the localizations object:

```dart
S.current.title
S.of(context).title
AppLocalizations.of(context)!.title
context.l10n.title          // any getter, field or parameter typed S
final s = S.of(context); s.title
```

Aliases are found automatically: any variable, field, parameter or getter
typed as the localizations class, or initialised from one, counts. That
covers the usual `extension on BuildContext { S get l10n => ... }`. Add
anything else under `usage.accessors`.

`loose` mode counts any `.title` member access anywhere. It never reports a
used key as unused, but keys with common names (`title`, `close`, `show`)
always look used.

Commented-out code does not count as a use. Keys that exist only in a
translation, not in the template, are checked too.

### How hardcoded strings are found

Every string literal in the scanned sources is classified. It is reported
when it reads as human language: it matches an existing translation (the
finding then names the key to use), contains non-ASCII letters, contains
common words of German, English, Croatian, French, Spanish or Italian, or
reads like a sentence.

Ignored automatically: imports, annotations, map keys and indexes, `switch`
cases, comparisons, `throw`, exception and error constructors, anything
passed to logging or analytics calls (`log`, `logDebug`, `_logger.info`,
`debugPrint`, `trackEvent`, `recordError`, ...), `toString()` bodies,
anything inside classes
named `*Logger`, `*Logging`, `*Log` or `*Tracker`, string operations
(`replaceAll`, `split`, `contains`, ...), `Key`/`RegExp`/`DateFormat`
arguments, identifiers, paths, URLs, date patterns and design-token names
like `'Buttons/primary-bg'`.

Medium-confidence hits are reported as `info`. Raise
`checks.hardcoded_string.min_confidence` to `high` to see only the clearest
cases.

## Pruning, safely

```sh
l10n_health prune            # dry run (the default)
l10n_health prune --apply
```

- Without `--apply` nothing is written, ever. `--dry-run` is accepted for
  scripts that want to be explicit.
- Each key is removed from every locale, together with its `@key` metadata.
- Files are edited as text, not re-serialised: every other line keeps its
  formatting, so the diff is exactly the removed lines.
- Each edited file is re-parsed before anything is written. If it does not
  round-trip, nothing is written at all.
- Files are written to a temporary sibling and renamed into place.
- Ambiguous keys are kept and listed: keys that appear as a string literal
  somewhere (possibly looked up dynamically) and, in strict mode, keys
  whose name is accessed through some other object. Review them, then pass
  `--include-ambiguous`, or name them with `--key <name>`.
- Keys matching `keep` globs are never reported or pruned.
- Refuses to run while any ARB file is invalid.

Afterwards, regenerate (`flutter gen-l10n` or `dart run
intl_utils:generate`) and build. A key that was still used fails at compile
time, never silently at runtime.

## Configuration

Everything is optional. `l10n_health init` writes a starter file with the
detected values.

```yaml
# l10n_health.yaml
arb_dir: lib/l10n
template_locale: en

sources: [lib]             # Dart directories to scan
exclude: ['lib/legacy/**'] # generated files are always excluded

usage:
  mode: strict             # strict | loose
  class: AppLocalizations  # detected from l10n.yaml / pubspec.yaml
  accessors: ['context.l10n', 'L10n.of(*)']

keep:                      # keys used dynamically
  - 'error_code_*'

checks:
  hardcoded_string:
    min_confidence: medium # low | medium | high
    min_length: 3
    ignore_calls: [showDebugBanner]
    ignore_named_args: [semanticsIdentifier]
    ignore_classes: ['Logger$', 'Fake']
    ignore_patterns: ['^[A-Z_]+$']
  invisible_unicode:
    allow: ['U+00A0']      # permit no-break spaces
  untranslated:
    min_length: 4
    ignore_keys: ['brand_*']
  duplicate_value:
    all_locales: false
  key_naming:
    style: snake_case      # camelCase | snake_case | a regex; enables the check
  orphan_metadata: false   # switch a check off
  unused_key:
    severity: error        # or re-grade it
```

### Suppressing a finding in Dart code

```dart
// l10n_health: ignore hardcoded_string - debug screen only
const title = 'Debug-Menü';

Text('Nur für Tests'); // l10n_health: ignore

// l10n_health: ignore-file
```

## CI

Adopting on an existing project is easier with a baseline: record today's
findings once, and fail only on new ones.

```sh
l10n_health --update-baseline       # writes l10n_health_baseline.json
l10n_health --fail-on warning       # fails only on findings not in the baseline
```

GitLab:

```yaml
l10n:
  stage: analyze
  script:
    - dart pub global activate l10n_health
    - l10n_health --fail-on warning --format html --output l10n.html
  artifacts:
    when: always
    paths: [l10n.html]
```

GitHub Actions:

```yaml
- run: dart pub global activate l10n_health
- run: l10n_health --fail-on warning
```

## Programmatic use

```dart
import 'package:l10n_health/l10n_health.dart';

Future<void> main() async {
  final analysis = await analyze(L10nConfig.load('.'));
  for (final f in analysis.findings) {
    print('${f.file}:${f.line} ${f.check} ${f.message}');
  }
}
```

## Performance

On a production Flutter app with 2,931 Dart files and 2,439 keys in two
locales, a full run of every check takes about a quarter of a second
(compiled with `dart compile exe`, 12-core Mac). Files are parsed without
resolving types, so no `pub get` is needed, and the work is spread across
all cores.

## License

MIT

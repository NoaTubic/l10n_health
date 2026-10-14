import 'package:l10n_health/src/config.dart';
import 'package:l10n_health/src/finding.dart';

/// Human-readable title and one-line explanation for each check.
const Map<String, (String, String)> checkInfo = {
  'arb_syntax': (
    'Invalid ARB file',
    'The file is not valid JSON, so no generator can read it.',
  ),
  'duplicate_key': (
    'Duplicate keys',
    'A key defined twice in one file. JSON parsers keep the last one '
        'silently, so the first translation is dead.',
  ),
  'placeholder_mismatch': (
    'Placeholder mismatches',
    'A translation uses different {placeholders} from the template. '
        'Generated code fails to compile or shows raw braces.',
  ),
  'icu_syntax': (
    'Malformed ICU messages',
    'Unbalanced braces or broken plural/select syntax.',
  ),
  'plural_forms': (
    'Plural forms',
    'A plural lacking a category the language needs (Croatian "few", '
        'Polish "many"), or carrying one it never selects. Users see '
        'the "other" text for those counts.',
  ),
  'locale_tag': (
    'Locale tags',
    'An ARB file whose "@@locale" is missing or disagrees with its file '
        'name.',
  ),
  'missing_translation': (
    'Missing translations',
    'Keys present in one locale and absent in another. Users of that '
        'locale see the fallback language.',
  ),
  'empty_translation': (
    'Empty translations',
    'A key whose translation is an empty string renders as nothing.',
  ),
  'invisible_unicode': (
    'Invisible Unicode',
    'Zero-width, bidi-control and look-alike space characters. They break '
        'search, diffs, comparisons and line wrapping, and cannot be seen.',
  ),
  'hardcoded_string': (
    'Hardcoded strings',
    'Text in Dart code that bypasses localization. Every user sees it in '
        'one language.',
  ),
  'unused_key': (
    'Unused keys',
    'Keys never read from Dart code. Safe to prune once confirmed.',
  ),
  'orphan_metadata': (
    'Orphan metadata',
    'An @key description whose key no longer exists.',
  ),
  'untranslated': (
    'Possibly untranslated',
    'A value identical in two locales, usually copied and never '
        'translated.',
  ),
  'duplicate_value': (
    'Duplicate values',
    'Several keys holding the same text. Often fine, often a sign the '
        'same string was added twice.',
  ),
  'key_naming': (
    'Key naming',
    'Keys that do not follow the configured naming style.',
  ),
  'missing_description': (
    'Missing descriptions',
    'Keys without an @key description to give translators context.',
  ),
};

String checkTitle(String id) => checkInfo[id]?.$1 ?? id;
String checkWhy(String id) => checkInfo[id]?.$2 ?? '';

/// Findings grouped by check, in the canonical check order.
Map<String, List<Finding>> byCheck(Iterable<Finding> findings) {
  final map = <String, List<Finding>>{
    for (final id in defaultSeverities.keys) id: [],
  };
  for (final f in findings) {
    map.putIfAbsent(f.check, () => []).add(f);
  }
  map.removeWhere((_, v) => v.isEmpty);
  return map;
}

Map<Severity, int> severityCounts(Iterable<Finding> findings) => {
  for (final s in Severity.values)
    s: findings.where((f) => f.severity == s).length,
};

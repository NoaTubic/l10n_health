import 'dart:io';

import 'package:l10n_health/src/config.dart';
import 'package:path/path.dart' as p;

/// Writes a starter `l10n_health.yaml` to [root], pre-filled with what was
/// detected. Returns an exit code.
int initConfig(String root, {bool force = false}) {
  final path = p.join(root, 'l10n_health.yaml');
  if (File(path).existsSync() && !force) {
    stderr.writeln('l10n_health: $path already exists (use --force)');
    return 1;
  }
  final config = L10nConfig.load(root, configPath: null);
  final arbDir = p.relative(config.arbDir, from: root);
  final accessorHint =
      config.className == null
          ? '  # accessors: [context.l10n]'
          : '  # ${config.className}.current and ${config.className}.of(...) '
              'are always accessors.\n'
              '  # accessors: [context.l10n]';

  File(path).writeAsStringSync('''
# l10n_health configuration. Every setting is optional; the values below
# were detected from this project (${config.generator}).

arb_dir: $arbDir
template_locale: ${config.templateLocale ?? 'en'}

# Directories scanned for Dart code. Generated files are always excluded.
sources: [lib]
# exclude: ['lib/legacy/**']

usage:
  # strict: only <localizations>.key counts as a use (precise).
  # loose:  any .key member access counts (never a false "unused").
  mode: ${config.usageMode.name}
$accessorHint

# Keys that are used dynamically and must never be reported or pruned.
keep: []
#  - 'error_code_*'

checks:
  hardcoded_string:
    min_confidence: medium   # low | medium | high
    min_length: 3
    # ignore_calls: [trackEvent]
    # ignore_named_args: [semanticsIdentifier]
    # ignore_patterns: ['^[A-Z_]+\$']
  invisible_unicode:
    allow: []                # e.g. ['U+00A0'] to permit no-break spaces
  untranslated:
    min_length: 4
    # ignore_keys: ['brand_*']
  duplicate_value:
    severity: info
    all_locales: false
  # Opt-in style checks:
  # key_naming: {style: snake_case}   # camelCase | snake_case | regex
  # missing_description: true
  # Any check can be switched off or re-graded:
  # orphan_metadata: false
  # unused_key: {severity: error}
''');
  stdout.writeln('l10n_health: wrote ${p.relative(path, from: root)}');
  return 0;
}

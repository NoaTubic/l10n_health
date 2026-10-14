import 'dart:io';

import 'package:glob/glob.dart';
import 'package:l10n_health/src/arb.dart';
import 'package:l10n_health/src/config.dart';
import 'package:l10n_health/src/dart_scan.dart';
import 'package:l10n_health/src/finding.dart';
import 'package:l10n_health/src/icu.dart';
import 'package:l10n_health/src/plural_rules.dart';
import 'package:l10n_health/src/text_heuristics.dart';
import 'package:l10n_health/src/unicode.dart';
import 'package:path/path.dart' as p;

/// Prefix of the `unused_key` detail for keys that might still be used.
/// Prune skips these unless told otherwise.
const ambiguousPrefix = 'Check before pruning:';

/// Headline numbers for a report.
class Stats {
  Stats({
    required this.locales,
    required this.templateLocale,
    required this.keys,
    required this.dartFiles,
    required this.usageMode,
    required this.generator,
    required this.elapsed,
  });

  /// Message count per locale.
  final Map<String, int> locales;
  final String templateLocale;

  /// Distinct message keys across all locales.
  final int keys;
  final int dartFiles;
  final UsageMode usageMode;
  final String generator;
  final Duration elapsed;

  Map<String, Object?> toJson() => {
    'templateLocale': templateLocale,
    'locales': locales,
    'keys': keys,
    'dartFiles': dartFiles,
    'usageMode': usageMode.name,
    'generator': generator,
    'elapsedMs': elapsed.inMilliseconds,
  };
}

/// The result of analysing one project.
class Analysis {
  Analysis({
    required this.config,
    required this.arbFiles,
    required this.template,
    required this.findings,
    required this.stats,
  });

  final L10nConfig config;
  final List<ArbFile> arbFiles;
  final ArbFile template;
  final List<Finding> findings;
  final Stats stats;

  /// Keys the `unused_key` check reported, in template order.
  List<String> get unusedKeys => [
    for (final f in findings)
      if (f.check == 'unused_key') f.key!,
  ];

  String relative(String path) => p.relative(path, from: config.root);
}

/// Loads every ARB file and runs every enabled check.
Future<Analysis> analyze(L10nConfig config) async {
  final watch = Stopwatch()..start();
  final findings = <Finding>[];
  String rel(String path) =>
      p.posix.joinAll(p.split(p.relative(path, from: config.root)));

  // --- ARB files -----------------------------------------------------------
  final arbPaths =
      Directory(config.arbDir)
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((path) => path.endsWith('.arb'))
          .toList()
        ..sort();
  if (arbPaths.isEmpty) {
    throw L10nConfigException('no .arb files in ${rel(config.arbDir)}');
  }

  final arbFiles = <ArbFile>[];
  for (final path in arbPaths) {
    try {
      arbFiles.add(ArbFile.load(path));
    } on ArbFormatException catch (e) {
      _add(
        findings,
        config,
        Finding(
          check: 'arb_syntax',
          severity: config.check('arb_syntax').severity,
          file: rel(path),
          line: e.line,
          column: e.column,
          message: 'Invalid JSON: ${e.message}',
          identity: rel(path),
        ),
      );
    }
  }
  if (arbFiles.isEmpty) {
    throw L10nConfigException(
      'no readable .arb files in ${rel(config.arbDir)}',
    );
  }

  final template = arbFiles.firstWhere(
    (f) => f.locale == config.templateLocale,
    orElse:
        () => arbFiles.reduce(
          (a, b) => b.messages.length > a.messages.length ? b : a,
        ),
  );
  final others = [
    for (final f in arbFiles)
      if (f != template) f,
  ];

  final allKeys = <String>{
    ...template.messages.keys,
    for (final f in others) ...f.messages.keys,
  };

  // --- Dart sources --------------------------------------------------------
  final scan = await scanDart(config, keys: allKeys);
  bool suppressed(Finding f) =>
      scan.suppressions.isSuppressed(f.file, f.line, f.check);

  // --- Per-file checks -----------------------------------------------------
  for (final file in arbFiles) {
    final name = rel(file.path);

    if (config.check('duplicate_key').enabled) {
      final seen = <String, ArbEntry>{};
      for (final e in file.entries) {
        final first = seen[e.key];
        if (first != null) {
          _add(
            findings,
            config,
            Finding(
              check: 'duplicate_key',
              severity: config.check('duplicate_key').severity,
              file: name,
              line: e.line,
              column: e.column,
              key: e.key,
              locale: file.locale,
              message:
                  'Key "${e.key}" is defined twice; the generator keeps '
                  'only the last one',
              detail: 'first defined on line ${first.line}',
              identity: '$name:${e.key}',
            ),
          );
        } else {
          seen[e.key] = e;
        }
      }
    }

    if (config.check('empty_translation').enabled) {
      for (final e in file.messages.values) {
        if (e.value is String && (e.value as String).trim().isEmpty) {
          _add(
            findings,
            config,
            Finding(
              check: 'empty_translation',
              severity: config.check('empty_translation').severity,
              file: name,
              line: e.line,
              column: e.column,
              key: e.key,
              locale: file.locale,
              message: 'Translation for "${e.key}" is empty',
              identity: '${file.locale}:${e.key}',
            ),
          );
        }
      }
    }

    if (config.check('icu_syntax').enabled) {
      for (final e in file.messages.values) {
        final value = e.value;
        if (value is! String) continue;
        final error = IcuMessage.parse(value).error;
        if (error == null) continue;
        _add(
          findings,
          config,
          Finding(
            check: 'icu_syntax',
            severity: config.check('icu_syntax').severity,
            file: name,
            line: e.line,
            column: e.column,
            key: e.key,
            locale: file.locale,
            message: 'Malformed message "${e.key}": $error',
            detail: value,
            identity: '${file.locale}:${e.key}',
          ),
        );
      }
    }

    if (config.check('orphan_metadata').enabled) {
      for (final MapEntry(key: key, value: meta) in file.metadata.entries) {
        if (file.messages.containsKey(key)) continue;
        _add(
          findings,
          config,
          Finding(
            check: 'orphan_metadata',
            severity: config.check('orphan_metadata').severity,
            file: name,
            line: meta.line,
            column: meta.column,
            key: key,
            locale: file.locale,
            message: 'Metadata "@$key" describes a key that does not exist',
            identity: '${file.locale}:@$key',
          ),
        );
      }
    }

    if (config.check('invisible_unicode').enabled) {
      for (final hit in findInvisible(
        file.text,
        allow: config.allowedInvisible,
      )) {
        final entry = _entryAt(file, hit.offset);
        final where =
            entry == null
                ? ''
                : entry.isMeta
                ? ' in metadata "${entry.key}"'
                : ' in "${entry.key}"';
        _add(
          findings,
          config,
          Finding(
            check: 'invisible_unicode',
            severity: config.check('invisible_unicode').severity,
            file: name,
            line: hit.line,
            column: hit.column,
            key: entry?.key,
            locale: file.locale,
            message: '${hit.label}$where',
            detail:
                entry?.value is String ? _reveal(entry!.value as String) : null,
            identity:
                '${file.locale}:${entry?.key}:${hit.codepoint}:'
                '${hit.offset - (entry?.keyStart ?? 0)}',
          ),
        );
      }
    }
  }

  // --- Cross-locale checks -------------------------------------------------
  if (config.check('missing_translation').enabled) {
    final severity = config.check('missing_translation').severity;
    for (final key in allKeys) {
      final owner =
          template.messages.containsKey(key)
              ? template
              : others.firstWhere((f) => f.messages.containsKey(key));
      final ownerEntry = owner.messages[key]!;
      for (final file in arbFiles) {
        if (file.messages.containsKey(key)) continue;
        final inTemplate = file == template;
        _add(
          findings,
          config,
          Finding(
            check: 'missing_translation',
            severity: severity,
            file: rel(file.path),
            line: 1,
            key: key,
            locale: file.locale,
            message:
                inTemplate
                    ? 'Key "$key" exists in ${p.basename(owner.path)} but not in '
                        'the template ${p.basename(file.path)}'
                    : 'Key "$key" has no ${file.locale} translation',
            detail:
                '${p.basename(owner.path)}:${ownerEntry.line}: '
                '${_preview(ownerEntry.value)}',
            identity: '${file.locale}:$key',
          ),
        );
      }
    }
  }

  if (config.check('placeholder_mismatch').enabled) {
    final severity = config.check('placeholder_mismatch').severity;
    for (final key in allKeys) {
      final reference =
          template.valueOf(key) != null
              ? template
              : others.firstWhere(
                (f) => f.valueOf(key) != null,
                orElse: () => template,
              );
      final refValue = reference.valueOf(key);
      if (refValue == null) continue;
      final refArgs = IcuMessage.parse(refValue).arguments;

      // Declared placeholders in the reference file's metadata.
      final meta = reference.metadata[key]?.value;
      final declared =
          meta is Map && meta['placeholders'] is Map
              ? (meta['placeholders'] as Map).keys.map((k) => '$k').toSet()
              : null;
      if (declared != null && !_sameSet(declared, refArgs)) {
        final entry = reference.messages[key]!;
        _add(
          findings,
          config,
          Finding(
            check: 'placeholder_mismatch',
            severity: severity,
            file: rel(reference.path),
            line: entry.line,
            column: entry.column,
            key: key,
            locale: reference.locale,
            message:
                'Placeholders in "$key" (${_fmt(refArgs)}) do not '
                'match its @$key metadata (${_fmt(declared)})',
            identity: '${reference.locale}:$key:meta',
          ),
        );
      }

      for (final file in arbFiles) {
        if (file == reference) continue;
        final value = file.valueOf(key);
        if (value == null) continue;
        final args = IcuMessage.parse(value).arguments;
        if (_sameSet(args, refArgs)) continue;
        final entry = file.messages[key]!;
        final missing = refArgs.difference(args);
        final extra = args.difference(refArgs);
        _add(
          findings,
          config,
          Finding(
            check: 'placeholder_mismatch',
            severity: severity,
            file: rel(file.path),
            line: entry.line,
            column: entry.column,
            key: key,
            locale: file.locale,
            message:
                'Placeholders in "$key" differ from '
                '${reference.locale}: '
                '${[if (missing.isNotEmpty) 'missing ${_fmt(missing)}', if (extra.isNotEmpty) 'unexpected ${_fmt(extra)}'].join(', ')}',
            detail: '${reference.locale}: $refValue\n${file.locale}: $value',
            identity: '${file.locale}:$key',
          ),
        );
      }
    }
  }

  if (config.check('untranslated').enabled) {
    final check = config.check('untranslated');
    final minLength = check.intOption('min_length', 4);
    final ignore = [for (final g in check.listOption('ignore_keys')) Glob(g)];
    for (final file in others) {
      for (final e in file.messages.values) {
        final value = e.value;
        if (value is! String) continue;
        if (template.valueOf(e.key) != value) continue;
        if (_doNotTranslate(e.key, template, file)) continue;
        final letters = value.replaceAll(RegExp(r'\{[^{}]*\}'), '');
        if (letters.trim().length < minLength || !hasLetter(letters)) continue;
        if (ignore.any((g) => g.matches(e.key))) continue;
        final guess = guessLanguage(
          letters,
          candidates: {
            template.locale,
            file.locale,
          }.map((l) => l.split(RegExp('[_-]')).first),
        );
        final hint = guess == null ? '' : ' (reads as "$guess")';
        _add(
          findings,
          config,
          Finding(
            check: 'untranslated',
            severity: check.severity,
            file: rel(file.path),
            line: e.line,
            column: e.column,
            key: e.key,
            locale: file.locale,
            message:
                '"${e.key}" is identical in ${template.locale} and '
                '${file.locale}$hint; one of them is probably untranslated',
            detail: value,
            identity: '${file.locale}:${e.key}',
          ),
        );
      }
    }
  }

  if (config.check('duplicate_value').enabled) {
    final check = config.check('duplicate_value');
    final minLength = check.intOption('min_length', 2);
    final allLocales = check.boolOption('all_locales', false);
    for (final file in allLocales ? arbFiles : [template]) {
      final groups = <String, List<ArbEntry>>{};
      for (final e in file.messages.values) {
        final value = e.value;
        if (value is! String) continue;
        final norm = value.trim();
        if (norm.length < minLength || !hasLetter(norm)) continue;
        if (_doNotTranslate(e.key, template, file)) continue;
        groups.putIfAbsent(norm, () => []).add(e);
      }
      for (final MapEntry(key: value, value: group) in groups.entries) {
        if (group.length < 2) continue;
        final first = group.first;
        _add(
          findings,
          config,
          Finding(
            check: 'duplicate_value',
            severity: check.severity,
            file: rel(file.path),
            line: first.line,
            column: first.column,
            key: first.key,
            locale: file.locale,
            related: [for (final e in group.skip(1)) e.key],
            message:
                '${group.length} keys share the value "${_clip(value)}": '
                '${group.map((e) => e.key).join(', ')}',
            detail: value,
            identity: '${file.locale}:$value',
          ),
        );
      }
    }
  }

  if (config.check('plural_forms').enabled) {
    final check = config.check('plural_forms');
    for (final file in arbFiles) {
      final language = languageOf(file.locale);
      final categories = cldrCardinalCategories[language];
      if (categories == null) continue;
      final required = categories
          .difference(optionalCategories[language] ?? const {})
          .difference(const {'other'});
      for (final e in file.messages.values) {
        final value = e.value;
        if (value is! String || !value.contains('plural')) continue;
        for (final plural in IcuMessage.parse(value).plurals) {
          // Dart's intl compiles =0, =1 and =2 into the zero, one and two
          // parameters, so they fill those categories.
          final selectors = {
            for (final sel in plural.selectors)
              switch (sel) {
                '=0' => 'zero',
                '=1' => 'one',
                '=2' => 'two',
                _ => sel,
              },
          };
          final missing = required.difference(selectors);
          final unused = selectors
              .intersection(allCategories)
              .difference(categories)
              .difference(intlExactCategories);
          if (missing.isEmpty && unused.isEmpty) continue;
          _add(
            findings,
            config,
            Finding(
              check: 'plural_forms',
              severity: missing.isEmpty ? Severity.info : check.severity,
              file: rel(file.path),
              line: e.line,
              column: e.column,
              key: e.key,
              locale: file.locale,
              message: [
                if (missing.isNotEmpty)
                  '"${e.key}" plural {${plural.argument}} lacks '
                      '${_list(missing)}, required in $language',
                if (unused.isNotEmpty)
                  '"${e.key}" plural {${plural.argument}} has '
                      '${_list(unused)}, never selected in $language',
              ].join('; '),
              detail: value,
              identity: '${file.locale}:${e.key}:${plural.argument}',
            ),
          );
        }
      }
    }
  }

  if (config.check('locale_tag').enabled) {
    final check = config.check('locale_tag');
    for (final file in arbFiles) {
      final declared = file.entries.where((e) => e.key == '@@locale');
      final fromName = ArbFile.localeFromFileName(file.path);
      if (declared.isEmpty) {
        _add(
          findings,
          config,
          Finding(
            check: 'locale_tag',
            severity: Severity.info,
            file: rel(file.path),
            line: 1,
            locale: file.locale,
            message:
                'No "@@locale"; the locale is inferred from the file '
                'name as "${file.locale}"',
            identity: '${rel(file.path)}:missing',
          ),
        );
      } else if (fromName != null &&
          _canonical(fromName) != _canonical(file.locale)) {
        final entry = declared.first;
        _add(
          findings,
          config,
          Finding(
            check: 'locale_tag',
            severity: check.severity,
            file: rel(file.path),
            line: entry.line,
            column: entry.column,
            locale: file.locale,
            message:
                '"@@locale" is "${file.locale}" but the file name says '
                '"$fromName"',
            identity: '${rel(file.path)}:mismatch',
          ),
        );
      }
    }
  }

  if (config.check('key_naming').enabled) {
    final check = config.check('key_naming');
    final style = check.options['style']?.toString() ?? 'camelCase';
    final pattern = switch (style) {
      'camelCase' => RegExp(r'^[a-z][a-zA-Z0-9]*$'),
      'snake_case' => RegExp(r'^[a-z][a-z0-9]*(_[a-z0-9]+)*$'),
      _ => RegExp(style),
    };
    for (final e in template.messages.values) {
      if (pattern.hasMatch(e.key)) continue;
      _add(
        findings,
        config,
        Finding(
          check: 'key_naming',
          severity: check.severity,
          file: rel(template.path),
          line: e.line,
          column: e.column,
          key: e.key,
          locale: template.locale,
          message: 'Key "${e.key}" is not $style',
          identity: e.key,
        ),
      );
    }
  }

  if (config.check('missing_description').enabled) {
    final check = config.check('missing_description');
    for (final e in template.messages.values) {
      final meta = template.metadata[e.key]?.value;
      final description = meta is Map ? meta['description'] : null;
      if (description is String && description.trim().isNotEmpty) continue;
      _add(
        findings,
        config,
        Finding(
          check: 'missing_description',
          severity: check.severity,
          file: rel(template.path),
          line: e.line,
          column: e.column,
          key: e.key,
          locale: template.locale,
          message:
              'Key "${e.key}" has no @${e.key} description for '
              'translators',
          identity: e.key,
        ),
      );
    }
  }

  // --- Dart-side checks ----------------------------------------------------
  if (config.check('unused_key').enabled) {
    final keep = [for (final g in config.keep) Glob(g)];
    final strict = config.usageMode == UsageMode.strict;
    final uses = strict ? scan.strictUses : scan.looseUses;
    // Every locale's keys, template first: a key that exists only in a
    // translation is just as dead when nothing reads it.
    final ordered = [
      ...template.messages.keys,
      for (final key in allKeys)
        if (!template.messages.containsKey(key)) key,
    ];
    for (final key in ordered) {
      if (uses.containsKey(key)) continue;
      if (keep.any((g) => g.matches(key))) continue;
      final owner =
          template.messages.containsKey(key)
              ? template
              : others.firstWhere((f) => f.messages.containsKey(key));
      final entry = owner.messages[key]!;
      final loose = scan.looseUses[key] ?? 0;
      _add(
        findings,
        config,
        Finding(
          check: 'unused_key',
          severity: config.check('unused_key').severity,
          file: rel(owner.path),
          line: entry.line,
          column: entry.column,
          key: key,
          locale: owner.locale,
          message: 'Key "$key" is never used in Dart code',
          detail: switch ((loose, scan.stringMentions[key])) {
            (_, final String at) =>
              '$ambiguousPrefix appears as the string '
                  "literal '$key' at $at; it may be looked up dynamically",
            (> 0, _) when strict =>
              '$ambiguousPrefix a member named "$key" '
                  'is accessed $loose time(s) through something other than '
                  'the localizations class',
            _ => _preview(entry.value),
          },
          identity: key,
        ),
      );
    }
  }

  if (config.check('hardcoded_string').enabled) {
    final check = config.check('hardcoded_string');
    final minConfidence = Confidence.parse(
      check.options['min_confidence']?.toString() ?? 'medium',
    );
    final minLength = check.intOption('min_length', 3);
    final ignorePatterns = [
      for (final r in check.listOption('ignore_patterns')) RegExp(r),
    ];

    // Literal text that already exists as a translation is the strongest
    // signal there is, and tells the developer which key to use.
    final translations = <String, String>{};
    for (final file in [template, ...others]) {
      for (final e in file.messages.values) {
        final value = e.value;
        if (value is! String || value.trim().length < minLength) continue;
        translations.putIfAbsent(normaliseForMatch(value), () => e.key);
      }
    }

    for (final lit in scan.literals) {
      if (ignorePatterns.any((r) => r.hasMatch(lit.value))) continue;
      final match = translations[normaliseForMatch(lit.value)];
      final verdict =
          match != null && hasLetter(lit.value) && !isLowercaseToken(lit.value)
              ? TextVerdict(Confidence.high, 'matches translation "$match"')
              : classifyLiteral(lit.value, minLength: minLength);
      if (verdict == null || verdict.confidence.index < minConfidence.index) {
        continue;
      }
      final finding = Finding(
        check: 'hardcoded_string',
        severity:
            verdict.confidence == Confidence.high
                ? check.severity
                : Severity.info,
        file: lit.file,
        line: lit.line,
        column: lit.column,
        key: match,
        message:
            match != null
                ? 'Hardcoded "${_clip(lit.value)}"; use the existing key "$match"'
                : 'Hardcoded text "${_clip(lit.value)}" bypasses localization '
                    '(${verdict.reason}'
                    '${verdict.language == null ? '' : ', ${verdict.language}'})',
        detail: lit.value,
        identity: '${lit.file}:${lit.value}',
      );
      if (!suppressed(finding)) _add(findings, config, finding);
    }
  }

  if (config.check('invisible_unicode').enabled) {
    for (final hit in scan.invisible) {
      final finding = Finding(
        check: 'invisible_unicode',
        severity: config.check('invisible_unicode').severity,
        file: hit.file,
        line: hit.hit.line,
        column: hit.hit.column,
        message: hit.hit.label,
        identity: '${hit.file}:${hit.hit.codepoint}:${hit.hit.line}',
      );
      if (!suppressed(finding)) _add(findings, config, finding);
    }
  }

  watch.stop();
  return Analysis(
    config: config,
    arbFiles: arbFiles,
    template: template,
    findings: findings,
    stats: Stats(
      locales: {for (final f in arbFiles) f.locale: f.messages.length},
      templateLocale: template.locale,
      keys: allKeys.length,
      dartFiles: scan.filesScanned,
      usageMode: config.usageMode,
      generator: config.generator,
      elapsed: watch.elapsed,
    ),
  );
}

/// True when either file's `@key` metadata marks the key as not meant to
/// be translated: `"x-ignore": true`, or a description saying "do not
/// translate".
bool _doNotTranslate(String key, ArbFile a, ArbFile b) {
  for (final file in [a, b]) {
    final meta = file.metadata[key]?.value;
    if (meta is! Map) continue;
    if (meta['x-ignore'] == true || meta['x-l10n-health-ignore'] == true) {
      return true;
    }
    final description = '${meta['description'] ?? ''}'.toLowerCase();
    if (description.contains('do not translate') ||
        description.contains("don't translate") ||
        description.contains('untranslatable')) {
      return true;
    }
  }
  return false;
}

String _canonical(String locale) => locale.replaceAll('-', '_').toLowerCase();

String _list(Set<String> s) => (s.toList()..sort()).join(', ');

void _add(List<Finding> findings, L10nConfig config, Finding f) {
  if (config.check(f.check).enabled) findings.add(f);
}

ArbEntry? _entryAt(ArbFile file, int offset) {
  for (final e in file.entries) {
    if (offset >= e.keyStart && offset < e.valueEnd) return e;
  }
  return null;
}

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

String _fmt(Set<String> args) =>
    args.isEmpty
        ? 'none'
        : (args.toList()..sort()).map((a) => '{$a}').join(' ');

String _clip(String s, [int max = 60]) {
  final flat = s.replaceAll('\n', r'\n');
  return flat.length <= max ? flat : '${flat.substring(0, max - 1)}…';
}

String _preview(Object? value) => value is String ? _clip(value, 80) : '';

/// Makes invisible characters visible as `<U+00A0>` markers.
String _reveal(String text) {
  final hits = findInvisible(text);
  if (hits.isEmpty) return text;
  final out = StringBuffer();
  var last = 0;
  for (final h in hits) {
    out
      ..write(text.substring(last, h.offset))
      ..write('<${h.codepoint}>');
    last = h.offset + (h.rune > 0xFFFF ? 2 : 1);
  }
  out.write(text.substring(last));
  return out.toString();
}

import 'dart:io';

import 'package:l10n_health/src/arb.dart';
import 'package:l10n_health/src/finding.dart';
import 'package:l10n_health/src/unicode.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Raised for a missing or invalid configuration. Exits with code 64.
class L10nConfigException implements Exception {
  L10nConfigException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// How a key is recognised as used in Dart code.
enum UsageMode {
  /// Only `<accessor>.key`, where the accessor is the localizations class
  /// (`S.current`, `AppLocalizations.of(context)!`, ...), a configured
  /// expression, or a variable assigned from one.
  strict,

  /// Any member access named like the key. Never reports a used key as
  /// unused, but keys with common names (`title`, `close`) always look used.
  loose,
}

/// Per-check settings.
class CheckConfig {
  CheckConfig({
    required this.enabled,
    required this.severity,
    this.options = const {},
  });

  final bool enabled;
  final Severity severity;
  final Map<String, Object?> options;

  int intOption(String name, int fallback) =>
      (options[name] as num?)?.toInt() ?? fallback;

  bool boolOption(String name, bool fallback) =>
      options[name] as bool? ?? fallback;

  List<String> listOption(String name, [List<String> fallback = const []]) {
    final raw = options[name];
    if (raw == null) return fallback;
    if (raw is! List) {
      throw L10nConfigException('checks option "$name" must be a list');
    }
    return [for (final v in raw) '$v'];
  }
}

/// Every check, with its default severity. The order is the report order.
const Map<String, Severity> defaultSeverities = {
  'arb_syntax': Severity.error,
  'duplicate_key': Severity.error,
  'placeholder_mismatch': Severity.error,
  'icu_syntax': Severity.error,
  'plural_forms': Severity.warning,
  'locale_tag': Severity.warning,
  'missing_translation': Severity.warning,
  'empty_translation': Severity.warning,
  'invisible_unicode': Severity.warning,
  'hardcoded_string': Severity.warning,
  'unused_key': Severity.warning,
  'orphan_metadata': Severity.info,
  'untranslated': Severity.info,
  'duplicate_value': Severity.info,
  'key_naming': Severity.info,
  'missing_description': Severity.info,
};

/// Style checks that are off unless configured.
const Set<String> defaultDisabled = {'key_naming', 'missing_description'};

/// Resolved configuration for one project.
class L10nConfig {
  L10nConfig({
    required this.root,
    required this.arbDir,
    required this.templateLocale,
    required this.sources,
    required this.exclude,
    required this.usageMode,
    required this.accessors,
    required this.className,
    required this.keep,
    required this.checks,
    required this.generator,
    this.configPath,
  });

  /// Absolute project root.
  final String root;

  /// Absolute directory holding the `.arb` files.
  final String arbDir;

  /// Locale whose file is the source of truth for keys.
  final String? templateLocale;

  /// Project-relative directories scanned for Dart code.
  final List<String> sources;

  /// Globs excluded from the Dart scan (generated code, mostly).
  final List<String> exclude;

  final UsageMode usageMode;

  /// Extra accessor expressions for strict usage, `*` as a wildcard.
  final List<String> accessors;

  /// Generated localizations class, e.g. `S` or `AppLocalizations`.
  final String? className;

  /// Key globs that are never reported unused and never pruned.
  final List<String> keep;

  final Map<String, CheckConfig> checks;

  /// Which setup was detected: `flutter_intl`, `gen_l10n` or `custom`.
  final String generator;

  /// Absolute path of the config file, when one was used.
  final String? configPath;

  CheckConfig check(String id) =>
      checks[id] ??
      CheckConfig(
        enabled: !defaultDisabled.contains(id),
        severity: defaultSeverities[id]!,
      );

  Set<int> get allowedInvisible => {
    for (final raw in check('invisible_unicode').listOption('allow'))
      parseCodepoint(raw),
  };

  /// A copy with command-line overrides applied.
  L10nConfig copyWith({
    List<String>? sources,
    List<String>? keep,
    Map<String, CheckConfig>? checks,
  }) => L10nConfig(
    root: root,
    arbDir: arbDir,
    templateLocale: templateLocale,
    sources: sources ?? this.sources,
    exclude: exclude,
    usageMode: usageMode,
    accessors: accessors,
    className: className,
    keep: keep ?? this.keep,
    checks: checks ?? this.checks,
    generator: generator,
    configPath: configPath,
  );

  /// Loads configuration for the project at [root]. [configPath] overrides
  /// the default `l10n_health.yaml`; a missing default file is fine, since
  /// everything can be detected.
  static L10nConfig load(String root, {String? configPath}) {
    final path = configPath ?? p.join(root, 'l10n_health.yaml');
    try {
      return _load(root, configPath: configPath);
    } on L10nConfigException {
      rethrow;
    } on YamlException catch (e) {
      throw L10nConfigException('$path: ${e.message}');
    } on FormatException catch (e) {
      throw L10nConfigException('$path: ${e.message}');
    } on TypeError {
      // A value of the wrong shape, e.g. a string where a map belongs.
      throw L10nConfigException(
        '$path: a setting has the wrong type; compare it with the README',
      );
    }
  }

  static L10nConfig _load(String root, {String? configPath}) {
    root = p.normalize(p.absolute(root));
    final explicit = configPath != null;
    final path = configPath ?? p.join(root, 'l10n_health.yaml');
    Map<Object?, Object?> yaml = const {};
    if (File(path).existsSync()) {
      final doc = loadYaml(File(path).readAsStringSync());
      if (doc != null && doc is! Map) {
        throw L10nConfigException('$path: top level must be a map');
      }
      yaml = (doc as Map?) ?? const {};
    } else if (explicit) {
      throw L10nConfigException('config file not found: $path');
    }

    final detected = _detect(root);

    String? str(String key) => yaml[key]?.toString();
    List<String>? list(String key) {
      final raw = yaml[key];
      if (raw == null) return null;
      if (raw is! List) throw L10nConfigException('"$key" must be a list');
      return [for (final v in raw) '$v'];
    }

    final arbDirRel = str('arb_dir') ?? detected.arbDir;
    if (arbDirRel == null) {
      throw L10nConfigException(
        'no .arb files found. Set arb_dir in l10n_health.yaml.',
      );
    }
    final arbDir = p.normalize(p.join(root, arbDirRel));
    if (!Directory(arbDir).existsSync()) {
      throw L10nConfigException('arb_dir does not exist: $arbDirRel');
    }

    final usage = (yaml['usage'] as Map?) ?? const {};
    final modeRaw = usage['mode']?.toString();
    final className = usage['class']?.toString() ?? detected.className;
    final mode = switch (modeRaw) {
      'strict' => UsageMode.strict,
      'loose' => UsageMode.loose,
      null => className != null ? UsageMode.strict : UsageMode.loose,
      _ =>
        throw L10nConfigException(
          'usage.mode must be strict or loose, got "$modeRaw"',
        ),
    };

    final checksYaml = (yaml['checks'] as Map?) ?? const {};
    final checks = <String, CheckConfig>{};
    for (final entry in checksYaml.entries) {
      final id = entry.key.toString();
      if (!defaultSeverities.containsKey(id)) {
        throw L10nConfigException(
          'unknown check "$id" (known: ${defaultSeverities.keys.join(', ')})',
        );
      }
      final body = entry.value;
      if (body is bool) {
        checks[id] = CheckConfig(
          enabled: body,
          severity: defaultSeverities[id]!,
        );
        continue;
      }
      final map = (body as Map?) ?? const {};
      checks[id] = CheckConfig(
        enabled: map['enabled'] as bool? ?? true,
        severity:
            map['severity'] == null
                ? defaultSeverities[id]!
                : _severity(id, map['severity']),
        options: {
          for (final o in map.entries)
            if (o.key != 'enabled' && o.key != 'severity')
              '${o.key}': _plain(o.value),
        },
      );
    }

    return L10nConfig(
      root: root,
      arbDir: arbDir,
      templateLocale: str('template_locale') ?? detected.templateLocale,
      sources: list('sources') ?? ['lib', ..._workspaceSources(root)],
      exclude: [
        ...?list('exclude'),
        ...defaultExcludes,
        if (detected.generatedDir != null) '${detected.generatedDir}/**',
      ],
      usageMode: mode,
      accessors: [
        for (final a in (usage['accessors'] as List?) ?? const []) '$a',
      ],
      className: className,
      keep: list('keep') ?? const [],
      checks: checks,
      generator: detected.generator,
      configPath: File(path).existsSync() ? path : null,
    );
  }

  static const defaultExcludes = [
    '**/*.g.dart',
    '**/*.freezed.dart',
    '**/*.gr.dart',
    '**/*.gen.dart',
    '**/*.config.dart',
    '**/*.mocks.dart',
    '**/generated/**',
    '**/.dart_tool/**',
    '**/build/**',
  ];
}

/// `lib` directories of Pub workspace members, so a monorepo root scans
/// every package that might read the keys.
List<String> _workspaceSources(String root) {
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return const [];
  final doc = loadYaml(pubspec.readAsStringSync());
  final members = doc is Map ? doc['workspace'] : null;
  if (members is! List) return const [];
  return [
    for (final m in members)
      if (Directory(p.join(root, '$m', 'lib')).existsSync()) '$m/lib',
  ];
}

Object? _plain(Object? v) => switch (v) {
  YamlList() => [for (final e in v) _plain(e)],
  YamlMap() => {for (final e in v.entries) '${e.key}': _plain(e.value)},
  _ => v,
};

/// What could be inferred from the project's existing l10n setup.
class Detected {
  Detected({
    required this.generator,
    this.arbDir,
    this.templateLocale,
    this.className,
    this.generatedDir,
  });

  final String generator;
  final String? arbDir;
  final String? templateLocale;
  final String? className;
  final String? generatedDir;
}

Detected _detect(String root) {
  // gen_l10n: flutter's built-in generator, configured by l10n.yaml.
  final l10nYaml = File(p.join(root, 'l10n.yaml'));
  if (l10nYaml.existsSync()) {
    final doc = (loadYaml(l10nYaml.readAsStringSync()) as Map?) ?? const {};
    final arbDir = doc['arb-dir']?.toString() ?? 'lib/l10n';
    final template = doc['template-arb-file']?.toString() ?? 'app_en.arb';
    final synthetic = doc['synthetic-package'] as bool? ?? false;
    return Detected(
      generator: 'gen_l10n',
      arbDir: arbDir,
      templateLocale: _templateLocale(p.join(root, arbDir, template)),
      className: doc['output-class']?.toString() ?? 'AppLocalizations',
      generatedDir: synthetic ? null : doc['output-dir']?.toString(),
    );
  }

  // flutter_intl: the Localizely IDE plugin and intl_utils, configured in
  // pubspec.yaml.
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  if (pubspec.existsSync()) {
    final doc = loadYaml(pubspec.readAsStringSync());
    final intl = doc is Map ? doc['flutter_intl'] : null;
    if (intl is Map && intl['enabled'] != false) {
      return Detected(
        generator: 'flutter_intl',
        arbDir: intl['arb_dir']?.toString() ?? 'lib/l10n',
        templateLocale: intl['main_locale']?.toString() ?? 'en',
        className: intl['class_name']?.toString() ?? 'S',
        generatedDir: intl['output_dir']?.toString() ?? 'lib/generated',
      );
    }
  }

  // Anything else: the directory holding the most .arb files wins.
  final counts = <String, int>{};
  for (final entity in Directory(root).listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.arb')) continue;
    final rel = p.relative(entity.path, from: root);
    if (rel.startsWith('build') || rel.contains('.dart_tool')) continue;
    final dir = p.dirname(rel);
    counts[dir] = (counts[dir] ?? 0) + 1;
  }
  final best = counts.entries.fold<MapEntry<String, int>?>(
    null,
    (a, b) => a == null || b.value > a.value ? b : a,
  );
  return Detected(generator: 'custom', arbDir: best?.key);
}

String? _templateLocale(String arbPath) {
  final file = File(arbPath);
  if (file.existsSync()) {
    final match = RegExp(
      r'"@@locale"\s*:\s*"([^"]+)"',
    ).firstMatch(file.readAsStringSync());
    if (match != null) return match.group(1);
  }
  return ArbFile.localeFromFileName(arbPath);
}

Severity _severity(String check, Object? raw) {
  try {
    return Severity.parse('$raw');
  } on FormatException {
    throw L10nConfigException(
      'checks.$check.severity must be error, warning or info, got "$raw"',
    );
  }
}

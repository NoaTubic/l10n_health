import 'dart:io';

import 'package:l10n_health/src/analysis.dart';
import 'package:l10n_health/src/arb.dart';
import 'package:l10n_health/src/baseline.dart';
import 'package:l10n_health/src/config.dart';
import 'package:l10n_health/src/finding.dart';
import 'package:l10n_health/src/init.dart';
import 'package:l10n_health/src/prune.dart';
import 'package:l10n_health/src/report/html_report.dart';
import 'package:l10n_health/src/report/text_reports.dart';
import 'package:l10n_health/src/sort.dart';
import 'package:path/path.dart' as p;

const _usage = '''
l10n_health: health check for ARB-based Dart and Flutter localization

Usage: l10n_health [command] [options]

Commands:
  check                  analyse and report (default)
  prune                  remove unused keys from every ARB file
                         (dry run unless --apply)
  sort                   sort the keys of every ARB file
  init                   write a starter l10n_health.yaml

Options:
  --format <fmt>         human | html | md | json | gitlab | github
  -o, --output <path>    write the report to a file
  --only <ids>           run only these checks (comma-separated)
  --fail-on <level>      error | warning | info | never  (default: error)
  --keep <globs>         keys never reported unused (comma-separated)
  --sources <dirs>       Dart directories to scan (default: lib)
  --root <dir>           project root (default: current directory)
  --config <path>        config file (default: <root>/l10n_health.yaml)
  --baseline <path>      baseline file (default: l10n_health_baseline.json)
  --update-baseline      record current findings as the baseline
  --no-baseline          ignore the baseline
  -q, --quiet            counts only
  -v, --verbose          list every finding
  --no-color             disable ANSI colour
  -h, --help             show this message

prune:
  --apply                write the changes (default is a dry run)
  --dry-run              explicit dry run
  --include-ambiguous    also remove keys that might still be used
  --key <name>           prune only this key; repeatable

sort:
  --order <order>        alpha | template  (default: alpha)
  --check                exit 1 if any file is unsorted; write nothing

Exit codes: 0 ok, 1 findings at or above --fail-on, 64 usage error.
''';

/// Runs the command line interface and returns the process exit code.
Future<int> run(List<String> argv) async {
  try {
    return await _run(argv);
  } on L10nConfigException catch (e) {
    stderr.writeln('l10n_health: $e');
    return 64;
  } on PruneVerificationException catch (e) {
    stderr.writeln('l10n_health: $e');
    return 1;
  }
}

Future<int> _run(List<String> argv) async {
  final args = _Args.parse(argv);
  if (args.help) {
    stdout.write(_usage);
    return 0;
  }
  final root = p.normalize(p.absolute(args.root ?? Directory.current.path));

  if (args.command == 'init') {
    return initConfig(root, force: args.force);
  }

  var config = L10nConfig.load(root, configPath: args.config);
  if (args.only != null) config = _restrict(config, args.only!);
  if (args.sources.isNotEmpty || args.keep.isNotEmpty) {
    config = config.copyWith(
      sources: args.sources.isEmpty ? null : args.sources,
      keep: [...config.keep, ...args.keep],
    );
  }

  if (args.command == 'sort') return _sort(config, args);
  final analysis = await analyze(config);

  if (args.command == 'prune') return _prune(analysis, args);

  final baselinePath =
      args.baseline ?? p.join(config.root, 'l10n_health_baseline.json');
  if (args.updateBaseline) {
    Baseline.write(baselinePath, analysis.findings);
    stdout.writeln(
      'l10n_health: baseline of ${analysis.findings.length} findings '
      'written to ${p.relative(baselinePath, from: config.root)}',
    );
    return 0;
  }
  final baseline =
      args.noBaseline ? Baseline.empty() : Baseline.load(baselinePath);
  final split = baseline.partition(analysis.findings);

  var linkPrefix = '';
  if (args.output != null) {
    final outDir = p.dirname(p.absolute(args.output!));
    final rel = p.relative(config.root, from: outDir);
    if (rel != '.') linkPrefix = '$rel/';
  }
  final projectName = p.basename(config.root);

  final report = switch (args.format) {
    'json' => renderJson(analysis, split.fresh, split.known),
    'gitlab' => renderGitLab(split.fresh),
    'github' => renderGitHub(split.fresh),
    'md' => renderMarkdown(
      analysis,
      split.fresh,
      split.known,
      projectName: projectName,
      linkPrefix: linkPrefix,
    ),
    'html' => renderHtml(
      analysis,
      split.fresh,
      split.known,
      projectName: projectName,
    ),
    _ => renderHuman(
      analysis,
      split.fresh,
      split.known,
      colour: args.colour && args.output == null && stdout.supportsAnsiEscapes,
      verbose: args.verbose,
      perCheckLimit: args.quiet ? 0 : 15,
    ),
  };

  if (args.output != null) {
    File(args.output!).writeAsStringSync(report);
    stdout.writeln(
      'l10n_health: ${split.fresh.length} findings, report written to '
      '${args.output}',
    );
  } else {
    stdout.write(report);
  }

  final failOn = args.failOn;
  if (failOn == null) return 0;
  return split.fresh.any((f) => f.severity.atLeast(failOn)) ? 1 : 0;
}

int _sort(L10nConfig config, _Args args) {
  final files = [
    for (final f in Directory(config.arbDir).listSync())
      if (f is File && f.path.endsWith('.arb')) ArbFile.load(f.path),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final template = files.where((f) => f.locale == config.templateLocale);
  final unsorted = <ArbFile, String>{};
  for (final file in files) {
    final sorted = sortArb(
      file,
      order: args.order,
      template: template.isEmpty ? null : template.first,
    );
    if (sorted != file.text) unsorted[file] = sorted;
  }
  for (final MapEntry(key: file, value: sorted) in unsorted.entries) {
    final rel = p.relative(file.path, from: config.root);
    if (args.check) {
      stdout.writeln('l10n_health: $rel is not sorted');
      continue;
    }
    final reparsed = ArbFile.parse(sorted, path: file.path);
    final before = [for (final e in file.entries) '${e.key}=${e.value}']
      ..sort();
    final after = [for (final e in reparsed.entries) '${e.key}=${e.value}']
      ..sort();
    if (before.join('\u0000') != after.join('\u0000')) {
      throw PruneVerificationException(
        'sorting $rel did not round-trip; nothing was written',
      );
    }
    final tmp = File('${file.path}.l10n_health.tmp')..writeAsStringSync(sorted);
    tmp.renameSync(file.path);
    stdout.writeln('l10n_health: sorted $rel');
  }
  if (unsorted.isEmpty) stdout.writeln('l10n_health: all ARB files sorted');
  return args.check && unsorted.isNotEmpty ? 1 : 0;
}

List<String> _csv(String raw) => [
  for (final s in raw.split(','))
    if (s.trim().isNotEmpty) s.trim(),
];

int _prune(Analysis analysis, _Args args) {
  final config = analysis.config;
  if (!config.check('unused_key').enabled) {
    throw L10nConfigException('prune needs the unused_key check enabled');
  }
  final broken = analysis.findings.where((f) => f.check == 'arb_syntax');
  if (broken.isNotEmpty) {
    throw L10nConfigException(
      'refusing to prune while an ARB file is invalid: '
      '${broken.map((f) => f.file).join(', ')}',
    );
  }

  final plan = planPrune(
    analysis,
    includeAmbiguous: args.includeAmbiguous,
    only: args.keys.isEmpty ? null : args.keys.toSet(),
  );

  final out = StringBuffer();
  final mode = args.apply ? 'Removing' : 'Dry run: would remove';
  if (plan.isEmpty) {
    out.writeln('l10n_health: nothing to prune.');
  } else {
    out.writeln(
      '$mode ${plan.keys.length} unused keys '
      '(usage detection: ${config.usageMode.name}).',
    );
    out.writeln();
    for (final edit in plan.edits.values) {
      final rel = p.relative(edit.file.path, from: config.root);
      final before = edit.file.messages.length;
      final removedMessages = edit.removed.where((k) => !k.startsWith('@'));
      out.writeln(
        '  $rel  ${edit.removed.length} entries '
        '($before -> ${before - removedMessages.length} messages)',
      );
    }
    out.writeln();
    final shown = args.verbose ? plan.keys : plan.keys.take(40);
    for (final key in shown) {
      out.writeln('  - $key');
    }
    if (shown.length < plan.keys.length) {
      out.writeln('  … ${plan.keys.length - shown.length} more (--verbose)');
    }
  }
  if (plan.skipped.isNotEmpty) {
    out
      ..writeln()
      ..writeln(
        'Kept ${plan.skipped.length} ambiguous keys that might still be '
        'used. Review them, then pass '
        '--include-ambiguous or --key <name>:',
      );
    for (final MapEntry(:key, :value) in plan.skipped.entries.take(
      args.verbose ? 1 << 30 : 20,
    )) {
      out.writeln('  ? $key  (${value.replaceFirst('$ambiguousPrefix ', '')})');
    }
    if (!args.verbose && plan.skipped.length > 20) {
      out.writeln('  … ${plan.skipped.length - 20} more (--verbose)');
    }
  }

  if (args.apply && !plan.isEmpty) {
    applyPrune(plan);
    out
      ..writeln()
      ..writeln('Done. Regenerate the localizations, then build:')
      ..writeln('  ${_regenerateHint(config.generator)}');
  } else if (!plan.isEmpty) {
    out
      ..writeln()
      ..writeln(
        'Nothing was written. Run `l10n_health prune --apply` to '
        'remove these keys.',
      );
  }
  stdout.write(out);
  return 0;
}

String _regenerateHint(String generator) => switch (generator) {
  'gen_l10n' => 'flutter gen-l10n',
  'flutter_intl' => 'dart run intl_utils:generate',
  _ => 're-run your localization code generator',
};

L10nConfig _restrict(L10nConfig config, Set<String> only) {
  for (final id in only) {
    if (!defaultSeverities.containsKey(id)) {
      throw L10nConfigException(
        'unknown check "$id" (known: ${defaultSeverities.keys.join(', ')})',
      );
    }
  }
  return config.copyWith(
    checks: {
      for (final id in defaultSeverities.keys)
        id: CheckConfig(
          enabled: only.contains(id),
          severity: config.check(id).severity,
          options: config.check(id).options,
        ),
    },
  );
}

class _Args {
  String command = 'check';
  String? root;
  String? config;
  String format = 'human';
  String? output;
  Set<String>? only;
  Severity? failOn = Severity.error;
  String? baseline;
  bool updateBaseline = false;
  bool noBaseline = false;
  bool verbose = false;
  bool colour = true;
  bool help = false;
  bool force = false;
  bool apply = false;
  bool includeAmbiguous = false;
  bool quiet = false;
  bool check = false;
  SortOrder order = SortOrder.alpha;
  final keys = <String>[];
  final keep = <String>[];
  final sources = <String>[];

  static _Args parse(List<String> argv) {
    final a = _Args();
    var commandSeen = false;
    for (var i = 0; i < argv.length; i++) {
      final arg = argv[i];
      String next() {
        if (i + 1 >= argv.length) {
          throw L10nConfigException('$arg expects a value');
        }
        return argv[++i];
      }

      switch (arg) {
        case 'check' || 'prune' || 'sort' || 'init' when !commandSeen:
          a.command = arg;
          commandSeen = true;
        case '--prune':
          a.command = 'prune';
          commandSeen = true;
        case '--dry-run':
          a.apply = false;
        case '--apply':
          a.apply = true;
        case '--include-ambiguous':
          a.includeAmbiguous = true;
        case '--key':
          a.keys.add(next());
        case '--keep':
          a.keep.addAll(_csv(next()));
        case '--sources':
          a.sources.addAll(_csv(next()));
        case '-q' || '--quiet':
          a.quiet = true;
        case '--check':
          a.check = true;
        case '--order':
          final value = next();
          a.order = switch (value) {
            'alpha' => SortOrder.alpha,
            'template' => SortOrder.template,
            _ =>
              throw L10nConfigException(
                '--order must be alpha or template, got "$value"',
              ),
          };
        case '--force':
          a.force = true;
        case '--root':
          a.root = next();
        case '--config':
          a.config = next();
        case '--format':
          a.format = next();
        case '--output' || '-o':
          a.output = next();
        case '--only':
          a.only = next().split(',').map((s) => s.trim()).toSet();
        case '--fail-on':
          final level = next();
          a.failOn = level == 'never' ? null : Severity.parse(level);
        case '--baseline':
          a.baseline = next();
        case '--update-baseline':
          a.updateBaseline = true;
        case '--no-baseline':
          a.noBaseline = true;
        case '-v' || '--verbose':
          a.verbose = true;
        case '--no-color' || '--no-colour':
          a.colour = false;
        case '-h' || '--help':
          a.help = true;
        default:
          throw L10nConfigException('unknown argument: $arg (see --help)');
      }
    }
    const formats = {'human', 'md', 'json', 'html', 'gitlab', 'github'};
    if (!formats.contains(a.format)) {
      throw L10nConfigException(
        'unknown --format "${a.format}" (expected: ${formats.join(', ')})',
      );
    }
    if (a.apply && a.command != 'prune') {
      throw L10nConfigException('--apply only applies to prune');
    }
    return a;
  }
}

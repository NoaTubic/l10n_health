import 'dart:convert';
import 'dart:io';

import 'package:l10n_health/l10n_health.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _project(Map<String, String> files) {
  final root = Directory.systemTemp.createTempSync('l10n_health_test_').path;
  addTearDown(() => Directory(root).deleteSync(recursive: true));
  for (final MapEntry(key: path, value: content) in files.entries) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }
  return root;
}

String _arb(Map<String, Object?> json) =>
    '${const JsonEncoder.withIndent('  ').convert(json)}\n';

Map<String, String> _base(Map<String, String> files, {String? config}) => {
  'pubspec.yaml': 'name: demo\n',
  'l10n.yaml': 'arb-dir: lib/l10n\ntemplate-arb-file: app_en.arb\n',
  if (config != null) 'l10n_health.yaml': config,
  ...files,
};

Future<List<Finding>> _run(
  Map<String, String> files,
  String check, {
  String? config,
}) async {
  final root = _project(_base(files, config: config));
  final analysis = await analyze(L10nConfig.load(root));
  return analysis.findings.where((f) => f.check == check).toList();
}

void main() {
  test('arb_syntax reports a broken file', () async {
    final hits = await _run({
      'lib/l10n/app_en.arb': _arb({'a': 'A'}),
      'lib/l10n/app_de.arb': '{\n  "a": "B",\n}\n',
    }, 'arb_syntax');
    expect(hits.single.file, endsWith('app_de.arb'));
    expect(hits.single.severity, Severity.error);
  });

  test('duplicate_key reports the second definition', () async {
    final hits = await _run({
      'lib/l10n/app_en.arb': '{\n  "a": "A",\n  "b": "B",\n  "a": "C"\n}\n',
    }, 'duplicate_key');
    expect(hits.single.key, 'a');
    expect(hits.single.line, 4);
  });

  test('orphan_metadata reports metadata without a message', () async {
    final hits = await _run({
      'lib/l10n/app_en.arb': _arb({
        'a': 'A',
        '@a': {'description': 'kept'},
        '@gone': {'description': 'left behind'},
      }),
    }, 'orphan_metadata');
    expect(hits.single.key, 'gone');
  });

  test('missing_description is opt-in and checks the template only', () async {
    final files = {
      'lib/l10n/app_en.arb': _arb({
        'a': 'A',
        '@a': {'description': 'Shown on the home page'},
        'b': 'B',
      }),
      'lib/l10n/app_de.arb': _arb({'a': 'A', 'b': 'B'}),
    };
    expect(await _run(files, 'missing_description'), isEmpty);
    final hits = await _run(
      files,
      'missing_description',
      config: 'checks:\n  missing_description: true\n',
    );
    expect(hits.map((f) => f.key), ['b']);
  });

  group('config', () {
    final files = {
      'lib/l10n/app_en.arb': _arb({
        'a': 'A',
        '@gone': {'description': 'x'},
      }),
    };

    test('a check can be switched off', () async {
      expect(
        await _run(
          files,
          'orphan_metadata',
          config: 'checks:\n  orphan_metadata: false\n',
        ),
        isEmpty,
      );
    });

    test('a check can be re-graded', () async {
      final hits = await _run(
        files,
        'unused_key',
        config: 'checks:\n  unused_key: {severity: error}\n',
      );
      expect(hits.single.severity, Severity.error);
    });

    test('exclude globs keep files out of the scan', () async {
      final hits = await _run(
        {
          'lib/l10n/app_en.arb': _arb({'a': 'A'}),
          'lib/legacy/old.dart':
              "void f() { print('Bitte wählen Sie eine Apotheke'); }",
        },
        'hardcoded_string',
        config: "exclude: ['lib/legacy/**']\n",
      );
      expect(hits, isEmpty);
    });

    test('an invalid config file is a usage error', () async {
      final root = _project(
        _base({
          'lib/l10n/app_en.arb': _arb({'a': 'A'}),
        }, config: 'checks:\n  unused_key: {severity: loud}\n'),
      );
      expect(await run(['--root', root, '-q']), 64);
    });
  });

  group('cli', () {
    late String root;
    setUp(() {
      root = _project(
        _base({
          'lib/l10n/app_en.arb': _arb({'a': 'A', 'b': 'B', 'c': 'C'}),
          'lib/l10n/app_de.arb': _arb({'a': 'A1', 'b': 'B1', 'c': 'C1'}),
          'lib/main.dart':
              'void f(dynamic c) => print(AppLocalizations.of(c)!.a);\n'
              "const k = 'c';\n",
        }),
      );
    });

    Future<int> cli(List<String> args) => run(['--root', root, ...args]);
    String arb(String locale) =>
        File(p.join(root, 'lib/l10n/app_$locale.arb')).readAsStringSync();

    test('prune holds back ambiguous keys until asked', () async {
      expect(await cli(['prune', '--apply']), 0);
      expect(arb('en'), isNot(contains('"b"')));
      expect(arb('en'), contains('"c"'));
      expect(await cli(['prune', '--apply', '--include-ambiguous']), 0);
      expect(arb('en'), isNot(contains('"c"')));
      expect(arb('de'), isNot(contains('"c"')));
    });

    test('prune --key removes only the named key', () async {
      expect(await cli(['prune', '--apply', '--key', 'c']), 0);
      expect(arb('en'), isNot(contains('"c"')));
      expect(arb('en'), contains('"b"'));
    });

    test(
      'prune refuses to touch anything while an ARB file is invalid',
      () async {
        final de = File(p.join(root, 'lib/l10n/app_de.arb'))
          ..writeAsStringSync('{"a": "A1",}');
        final en = arb('en');
        expect(await cli(['prune', '--apply']), isNot(0));
        expect(arb('en'), en);
        expect(de.readAsStringSync(), '{"a": "A1",}');
      },
    );

    test('sort --order template follows the template', () async {
      File(
        p.join(root, 'lib/l10n/app_en.arb'),
      ).writeAsStringSync(_arb({'c': 'C', 'a': 'A', 'b': 'B'}));
      expect(await cli(['sort', '--order', 'template']), 0);
      final de = ArbFile.load(p.join(root, 'lib/l10n/app_de.arb'));
      expect(de.entries.map((e) => e.key), ['c', 'a', 'b']);
      expect(await cli(['sort', '--order', 'sideways']), 64);
    });

    test('markdown report lists findings by check', () async {
      final out = p.join(root, 'r.md');
      await cli(['--format', 'md', '-o', out, '--fail-on', 'never']);
      final md = File(out).readAsStringSync();
      expect(md, startsWith('#'));
      expect(md, contains('unused_key'));
    });

    test('init writes a config once', () async {
      expect(await cli(['init']), 0);
      final config = File(p.join(root, 'l10n_health.yaml'));
      expect(config.readAsStringSync(), contains('arb_dir: lib/l10n'));
      expect(await cli(['init']), 1);
      expect(await cli(['init', '--force']), 0);
      // The generated file loads cleanly.
      expect(await cli(['-q', '--fail-on', 'never']), 0);
    });
  });
}

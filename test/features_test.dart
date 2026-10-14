import 'dart:convert';
import 'dart:io';

import 'package:l10n_health/l10n_health.dart';
import 'package:l10n_health/src/sort.dart';
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

Future<List<Finding>> _run(
  Map<String, String> files,
  String check, {
  String? config,
}) async {
  final root = _project({
    'pubspec.yaml': 'name: demo\n',
    'l10n.yaml': 'arb-dir: lib/l10n\ntemplate-arb-file: app_en.arb\n',
    if (config != null) 'l10n_health.yaml': config,
    ...files,
  });
  final analysis = await analyze(L10nConfig.load(root));
  return analysis.findings.where((f) => f.check == check).toList();
}

void main() {
  group('plural_forms', () {
    test('reports categories a language needs', () async {
      final hits = await _run({
        'lib/l10n/app_en.arb': _arb({
          'n': '{count, plural, one{# item} other{# items}}',
        }),
        'lib/l10n/app_hr.arb': _arb({
          'n': '{count, plural, one{# stavka} other{# stavki}}',
        }),
      }, 'plural_forms');
      expect(hits.single.locale, 'hr');
      expect(hits.single.message, contains('lacks few'));
    });

    test('counts =1 as one and reports categories never selected', () async {
      final hits = await _run({
        'lib/l10n/app_en.arb': _arb({
          'n': '{count, plural, =1{One} few{Few} other{Many}}',
        }),
      }, 'plural_forms');
      expect(hits.single.message, contains('has few, never selected'));
      expect(hits.single.severity, Severity.info);
    });
  });

  test('locale_tag catches a mislabelled file', () async {
    final hits = await _run({
      'lib/l10n/app_en.arb': _arb({'@@locale': 'en', 'a': 'A'}),
      'lib/l10n/app_de.arb': _arb({'@@locale': 'fr', 'a': 'B'}),
    }, 'locale_tag');
    expect(hits.single.message, contains('"fr"'));
  });

  test('style checks are opt-in', () async {
    final files = {
      'lib/l10n/app_en.arb': _arb({'good_key': 'A', 'BadKey': 'B'}),
    };
    expect(await _run(files, 'key_naming'), isEmpty);
    final hits = await _run(
      files,
      'key_naming',
      config: 'checks:\n  key_naming:\n    style: snake_case\n',
    );
    expect(hits.single.key, 'BadKey');
  });

  test('"do not translate" metadata silences untranslated', () async {
    final hits = await _run({
      'lib/l10n/app_en.arb': _arb({
        'brand': 'Clickapo Plus',
        '@brand': {'description': 'Brand name, DO NOT TRANSLATE'},
        'copied': 'Copied text here',
      }),
      'lib/l10n/app_de.arb': _arb({
        'brand': 'Clickapo Plus',
        'copied': 'Copied text here',
      }),
    }, 'untranslated');
    expect(hits.map((f) => f.key), ['copied']);
  });

  test('a type parameter named like the class is not an accessor', () async {
    final hits = await _run({
      'lib/l10n/app_en.arb': _arb({'title': 'Title', 'data': 'Data'}),
      'lib/main.dart': '''
class Box<AppLocalizations> {
  Box(this.data);
  final AppLocalizations data;
}
class Thing { final String title = ''; }
void f(Thing t, dynamic context) {
  print(t.title);
  print(AppLocalizations.of(context)!.data);
}
''',
    }, 'unused_key');
    expect(hits.map((f) => f.key), ['title']);
  });

  test('locals are aliases only in their own file', () async {
    final hits = await _run({
      'lib/l10n/app_en.arb': _arb({'a': 'A', 'b': 'B'}),
      'lib/one.dart': '''
void f(dynamic context) {
  final s = AppLocalizations.of(context)!;
  print(s.a);
}
''',
      'lib/two.dart': 'void g(dynamic s) => print(s.b);',
    }, 'unused_key');
    expect(hits.map((f) => f.key), ['b']);
  });

  test('pub workspace members are scanned', () async {
    final root = _project({
      'pubspec.yaml': 'name: root\nworkspace:\n  - packages/feature\n',
      'l10n.yaml': 'arb-dir: lib/l10n\ntemplate-arb-file: app_en.arb\n',
      'lib/l10n/app_en.arb': _arb({'a': 'A'}),
      'packages/feature/lib/f.dart':
          'void f(dynamic c) => print(AppLocalizations.of(c)!.a);',
    });
    final analysis = await analyze(L10nConfig.load(root));
    expect(analysis.unusedKeys, isEmpty);
  });

  group('sortArb', () {
    test('sorts, keeps metadata with its key and @@ entries first', () {
      final arb = ArbFile.parse(
        '{\n  "@@locale": "en",\n  "b": "B",\n  "@b": {"description": "x"},'
        '\n  "a": "A"\n}\n',
        path: 'app_en.arb',
      );
      expect(
        sortArb(arb),
        '{\n  "@@locale": "en",\n  "a": "A",\n  "b": "B",\n'
        '  "@b": {"description": "x"}\n}\n',
      );
    });

    test('follows the template order when asked', () {
      final template = ArbFile.parse(
        '{"z": "1", "a": "2"}',
        path: 'app_en.arb',
      );
      final arb = ArbFile.parse(
        '{\n    "a": "x",\n    "extra": "y",\n    "z": "w"\n}',
        path: 'app_de.arb',
      );
      expect(
        sortArb(arb, order: SortOrder.template, template: template),
        '{\n    "z": "w",\n    "a": "x",\n    "extra": "y"\n}',
      );
    });
  });

  group('cli', () {
    late String root;
    setUp(() {
      root = _project({
        'pubspec.yaml': 'name: demo\n',
        'l10n.yaml': 'arb-dir: lib/l10n\ntemplate-arb-file: app_en.arb\n',
        'lib/l10n/app_en.arb': _arb({'b': 'B', 'a': 'A', 'dyn_x': 'X'}),
        'lib/main.dart':
            'void f(dynamic c) => print(AppLocalizations.of(c)!.a);',
      });
    });

    Future<int> cli(List<String> args) => run(['--root', root, ...args]);

    test('sort --check, then sort', () async {
      expect(await cli(['sort', '--check']), 1);
      expect(await cli(['sort']), 0);
      expect(await cli(['sort', '--check']), 0);
      final arb = ArbFile.load(p.join(root, 'lib/l10n/app_en.arb'));
      expect(arb.entries.map((e) => e.key), ['a', 'b', 'dyn_x']);
    });

    test('--keep and --only', () async {
      final out = p.join(root, 'r.json');
      await cli([
        '--only', 'unused_key', '--keep', 'dyn_*', //
        '--format', 'json', '-o', out, '--fail-on', 'never',
      ]);
      final report = jsonDecode(File(out).readAsStringSync()) as Map;
      final keys = [for (final f in report['findings'] as List) f['key']];
      expect(keys, ['b']);
    });

    test('gitlab and github formats', () async {
      final gl = p.join(root, 'gl.json');
      await cli(['--format', 'gitlab', '-o', gl, '--fail-on', 'never']);
      final issues = jsonDecode(File(gl).readAsStringSync()) as List;
      expect(issues.first['location']['path'], 'lib/l10n/app_en.arb');

      final gh = p.join(root, 'gh.txt');
      await cli(['--format', 'github', '-o', gh, '--fail-on', 'never']);
      expect(
        File(gh).readAsStringSync(),
        contains('::warning file=lib/l10n/app_en.arb,line='),
      );
    });
  });
}

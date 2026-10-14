import 'dart:convert';
import 'dart:io';

import 'package:l10n_health/l10n_health.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Writes a throwaway project and returns its root.
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

const _flutterIntlPubspec = '''
name: demo
flutter_intl:
  enabled: true
  main_locale: de
''';

Map<String, String> _flutterIntlProject({String? dart, String? extraDart}) => {
  'pubspec.yaml': _flutterIntlPubspec,
  'lib/l10n/intl_de.arb': _arb({
    '@@locale': 'de',
    'title': 'Startseite',
    'greeting': 'Hallo {name}',
    '@greeting': {
      'placeholders': {'name': {}},
    },
    'unused_one': 'Nie benutzt',
    'only_de': 'Nur Deutsch',
    'copied': 'Kopiert und vergessen',
    'same_a': 'Schließen',
    'same_b': 'Schließen',
    'broken': '{count, plural, =1{eins}}',
    'hidden': 'Hallo\u200BWelt',
    'empty': '',
  }),
  'lib/l10n/intl_en.arb': _arb({
    '@@locale': 'en',
    'title': 'Home',
    'greeting': 'Hello {username}',
    'unused_one': 'Never used',
    'copied': 'Kopiert und vergessen',
    'same_a': 'Close',
    'same_b': 'Close',
    'broken': '{count, plural, =1{one} other{many}}',
    'hidden': 'Hello world',
    'empty': 'Empty',
    'only_en': 'English only',
  }),
  'lib/generated/l10n.dart': 'class S { static S get current => S(); }',
  'lib/main.dart':
      dart ??
      '''
import 'generated/l10n.dart';

void main() {
  print(S.current.title);
  final s = S.current;
  s.greeting('x');
  final a = '\${S.current.only_de}. ' '\${S.current.only_en}';
  final b = '\${S.current.copied} \${S.current.same_a} \${S.current.same_b}';
  final c = '\${S.current.broken} \${S.current.hidden} \${S.current.empty}';
  show('Bitte wählen Sie eine Apotheke');
  show('Startseite');
  log('Das ist nur ein Log');
  final t = 'user_id';
}
''',
  if (extraDart != null) 'lib/extra.dart': extraDart,
};

List<Finding> _of(Analysis a, String check) =>
    a.findings.where((f) => f.check == check).toList();

void main() {
  group('flutter_intl project', () {
    late Analysis analysis;

    setUp(() async {
      final root = _project(_flutterIntlProject());
      analysis = await analyze(L10nConfig.load(root));
    });

    test('detects the setup', () async {
      expect(analysis.stats.generator, 'flutter_intl');
      expect(analysis.stats.templateLocale, 'de');
      expect(analysis.stats.usageMode, UsageMode.strict);
      expect(analysis.stats.dartFiles, 1, reason: 'generated code excluded');
    });

    test(
      'unused keys, including through an alias and adjacent strings',
      () async {
        expect(_of(analysis, 'unused_key').map((f) => f.key), ['unused_one']);
      },
    );

    test('missing translations in both directions', () async {
      final missing = {
        for (final f in _of(analysis, 'missing_translation'))
          '${f.locale}:${f.key}',
      };
      expect(missing, {'en:only_de', 'de:only_en'});
    });

    test('placeholder mismatch', () async {
      final f = _of(analysis, 'placeholder_mismatch').single;
      expect(f.key, 'greeting');
      expect(f.locale, 'en');
      expect(f.message, contains('{name}'));
      expect(f.message, contains('{username}'));
    });

    test('ICU syntax', () async {
      final f = _of(analysis, 'icu_syntax').single;
      expect(f.key, 'broken');
      expect(f.locale, 'de');
    });

    test('untranslated, duplicate, empty and invisible', () async {
      expect(_of(analysis, 'untranslated').single.key, 'copied');
      expect(_of(analysis, 'duplicate_value').single.related, ['same_b']);
      expect(_of(analysis, 'empty_translation').single.key, 'empty');
      final invisible = _of(analysis, 'invisible_unicode').single;
      expect(invisible.key, 'hidden');
      expect(invisible.message, contains('U+200B'));
      expect(invisible.detail, 'Hallo<U+200B>Welt');
    });

    test('hardcoded strings, with translation matches', () async {
      final hits = _of(analysis, 'hardcoded_string');
      expect(hits.map((f) => f.detail), [
        'Bitte wählen Sie eine Apotheke',
        'Startseite',
      ]);
      expect(hits.last.key, 'title');
      expect(hits.last.message, contains('use the existing key "title"'));
    });
  });

  test('extension getters count as accessors', () async {
    final root = _project(
      _flutterIntlProject(
        extraDart: '''
import 'generated/l10n.dart';
extension L10nX on Object { S get l10n => S.current; }
void f(Object context) => print(context.l10n.unused_one);
''',
      ),
    );
    final a = await analyze(L10nConfig.load(root));
    expect(_of(a, 'unused_key'), isEmpty);
  });

  test('loose mode counts any member access', () async {
    final root = _project({
      ..._flutterIntlProject(extraDart: 'void f(dynamic x) => x.unused_one;'),
      'l10n_health.yaml': 'usage:\n  mode: loose\n',
    });
    final a = await analyze(L10nConfig.load(root));
    expect(a.stats.usageMode, UsageMode.loose);
    expect(_of(a, 'unused_key'), isEmpty);
  });

  test('suppression comments', () async {
    final root = _project(
      _flutterIntlProject(
        dart: '''
void main() {
  // l10n_health: ignore hardcoded_string - shown only in debug builds
  show('Bitte wählen Sie eine Apotheke');
  show('Noch ein deutscher Satz'); // l10n_health: ignore
}
''',
      ),
    );
    final a = await analyze(L10nConfig.load(root));
    expect(_of(a, 'hardcoded_string'), isEmpty);
  });

  test('keep globs protect dynamic keys', () async {
    final root = _project({
      ..._flutterIntlProject(),
      'l10n_health.yaml': "keep: ['unused_*']\n",
    });
    expect(_of(await analyze(L10nConfig.load(root)), 'unused_key'), isEmpty);
  });

  test('gen_l10n project via l10n.yaml', () async {
    final root = _project({
      'pubspec.yaml': 'name: demo\n',
      'l10n.yaml': 'arb-dir: lib/i18n\ntemplate-arb-file: app_en.arb\n',
      'lib/i18n/app_en.arb': _arb({'hello': 'Hello', 'bye': 'Bye'}),
      'lib/i18n/app_hr.arb': _arb({'hello': 'Bok', 'bye': 'Bok bok'}),
      'lib/main.dart': '''
void f(dynamic context) {
  print(AppLocalizations.of(context)!.hello);
}
''',
    });
    final a = await analyze(L10nConfig.load(root));
    expect(a.stats.generator, 'gen_l10n');
    expect(a.stats.templateLocale, 'en');
    expect(_of(a, 'unused_key').map((f) => f.key), ['bye']);
  });

  group('prune', () {
    test('plans, verifies and applies', () async {
      final root = _project(_flutterIntlProject());
      final analysis = await analyze(L10nConfig.load(root));
      final plan = planPrune(analysis);
      expect(plan.keys, ['unused_one']);
      applyPrune(plan);
      for (final locale in ['de', 'en']) {
        final arb = ArbFile.load(p.join(root, 'lib/l10n/intl_$locale.arb'));
        expect(arb.messages.containsKey('unused_one'), isFalse);
        expect(arb.messages.containsKey('title'), isTrue);
      }
      expect(_of(await analyze(L10nConfig.load(root)), 'unused_key'), isEmpty);
    });

    test('skips keys that appear as string literals', () async {
      final root = _project(
        _flutterIntlProject(extraDart: "const k = 'unused_one';"),
      );
      final plan = planPrune(await analyze(L10nConfig.load(root)));
      expect(plan.keys, isEmpty);
      expect(plan.skipped.keys, ['unused_one']);
    });
  });

  group('cli', () {
    late String root;
    setUp(() => root = _project(_flutterIntlProject()));

    Future<int> cli(List<String> args) => run(['--root', root, ...args]);

    test('exit code follows --fail-on', () async {
      expect(await cli(['--format', 'json', '-o', p.join(root, 'r.json')]), 1);
      expect(
        await cli([
          '--fail-on',
          'never',
          '--format',
          'json',
          '-o',
          p.join(root, 'r.json'),
        ]),
        0,
      );
    });

    test('baseline silences known findings', () async {
      expect(await cli(['--update-baseline']), 0);
      expect(await cli(['--format', 'json', '-o', p.join(root, 'r.json')]), 0);
      final report = jsonDecode(
        File(p.join(root, 'r.json')).readAsStringSync(),
      );
      expect((report as Map)['findings'], isEmpty);
    });

    test('prune is a dry run unless --apply', () async {
      final arb = File(p.join(root, 'lib/l10n/intl_de.arb'));
      final before = arb.readAsStringSync();
      expect(await cli(['prune']), 0);
      expect(await cli(['--prune', '--dry-run']), 0);
      expect(arb.readAsStringSync(), before);
      expect(await cli(['prune', '--apply']), 0);
      expect(arb.readAsStringSync(), isNot(contains('unused_one')));
    });

    test('html report is self-contained', () async {
      final out = p.join(root, 'r.html');
      await cli(['--format', 'html', '-o', out, '--fail-on', 'never']);
      final html = File(out).readAsStringSync();
      expect(html, startsWith('<!doctype html>'));
      expect(html, isNot(contains('src="http')));
      expect(html, contains('"check":"unused_key"'));
    });

    test('usage errors exit 64', () async {
      expect(await cli(['--format', 'pdf']), 64);
      expect(await cli(['--only', 'nope']), 64);
    });
  });
}

import 'package:l10n_health/l10n_health.dart';
import 'package:l10n_health/src/prune.dart';
import 'package:l10n_health/src/unicode.dart';
import 'package:test/test.dart';

ArbFile _arb(String text) => ArbFile.parse(text, path: 'app_en.arb');

void main() {
  group('ArbFile', () {
    test('records entries with lines and columns', () {
      final arb = _arb(
        '{\n  "@@locale": "de",\n  "hello": "Hallo",\n'
        '  "@hello": {"description": "greeting"}\n}\n',
      );
      expect(arb.locale, 'de');
      expect(arb.messages.keys, ['hello']);
      expect(arb.messages['hello']!.line, 3);
      expect(arb.messages['hello']!.column, 3);
      expect(arb.metadata.keys, ['hello']);
    });

    test('keeps duplicate keys that jsonDecode would hide', () {
      final arb = _arb('{"a": "1", "a": "2"}');
      expect(arb.entries.map((e) => e.key), ['a', 'a']);
      expect(arb.valueOf('a'), '2');
    });

    test('reports invalid JSON with a position', () {
      expect(
        () => _arb('{\n  "a": "1",\n  "b" "2"\n}'),
        throwsA(isA<ArbFormatException>().having((e) => e.line, 'line', 3)),
      );
    });

    test('falls back to the file name for the locale', () {
      expect(ArbFile.localeFromFileName('lib/l10n/intl_de.arb'), 'de');
      expect(ArbFile.localeFromFileName('app_en_US.arb'), 'en_US');
      expect(ArbFile.localeFromFileName('fr.arb'), 'fr');
      expect(ArbFile.localeFromFileName('app_en.arb'), 'en');
      expect(ArbFile.localeFromFileName('app_zh_Hant_TW.arb'), 'zh_Hant_TW');
      expect(ArbFile.localeFromFileName('strings_es_419.arb'), 'es_419');
    });

    test('tolerates a byte-order mark', () {
      expect(_arb('\uFEFF{"a": "1"}').valueOf('a'), '1');
    });
  });

  group('IcuMessage', () {
    test('collects simple and nested arguments', () {
      final m = IcuMessage.parse(
        '{count, plural, =0{No items for {name}} other{{count} items}}',
      );
      expect(m.error, isNull);
      expect(m.arguments, {'count', 'name'});
    });

    test('accepts formatted arguments', () {
      final m = IcuMessage.parse('Total: {price, number, currency}');
      expect(m.error, isNull);
      expect(m.arguments, {'price'});
    });

    test('treats apostrophes as text', () {
      expect(IcuMessage.parse("Sie's {name}").arguments, {'name'});
    });

    test('flags unbalanced braces', () {
      expect(IcuMessage.parse('Hello {name').error, isNotNull);
      expect(IcuMessage.parse('Hello name}').error, isNotNull);
    });

    test('requires an other branch', () {
      expect(
        IcuMessage.parse('{g, select, male{He} female{She}}').error,
        contains('other'),
      );
      expect(
        IcuMessage.parse('{g, select, male{He} other{They}}').error,
        isNull,
      );
    });

    test('rejects text where an argument name belongs', () {
      expect(IcuMessage.parse('Date {dd.MM.yyyy}').error, isNotNull);
    });
  });

  group('findInvisible', () {
    test('finds zero-width and look-alike spaces with positions', () {
      final hits = findInvisible('ab\u200Bc\nd\u00A0e');
      expect(hits.map((h) => h.codepoint), ['U+200B', 'U+00A0']);
      expect(hits.first.line, 1);
      expect(hits.first.column, 3);
      expect(hits.last.line, 2);
    });

    test('finds tag characters outside the BMP', () {
      final hits = findInvisible('x\u{E0041}y');
      expect(hits.single.name, 'TAG CHARACTER');
    });

    test('ignores visible typography', () {
      expect(findInvisible('“Grüße” – é … 😀 č ć ž š đ'), isEmpty);
    });

    test('honours the allow list', () {
      expect(findInvisible('a\u00A0b', allow: {0x00A0}), isEmpty);
    });

    test('parses codepoint notations', () {
      expect(parseCodepoint('U+00A0'), 0xA0);
      expect(parseCodepoint('0x200b'), 0x200B);
      expect(parseCodepoint('FEFF'), 0xFEFF);
    });
  });

  group('removeEntries', () {
    const text = '{\n  "a": "1",\n  "b": "2",\n  "c": "3"\n}\n';

    String remove(Set<String> keys) {
      final arb = _arb(text);
      final indices = {
        for (var i = 0; i < arb.entries.length; i++)
          if (keys.contains(arb.entries[i].key)) i,
      };
      return removeEntries(arb, indices);
    }

    test('removes a middle entry', () {
      expect(remove({'b'}), '{\n  "a": "1",\n  "c": "3"\n}\n');
    });

    test('removes the last entry without leaving a trailing comma', () {
      expect(remove({'c'}), '{\n  "a": "1",\n  "b": "2"\n}\n');
    });

    test('removes several trailing entries', () {
      expect(remove({'b', 'c'}), '{\n  "a": "1"\n}\n');
    });

    test('removes the first entry', () {
      expect(remove({'a'}), '{\n  "b": "2",\n  "c": "3"\n}\n');
    });

    test('removes everything and stays valid JSON', () {
      final out = remove({'a', 'b', 'c'});
      expect(_arb(out).entries, isEmpty);
    });

    test('keeps nested metadata intact', () {
      const withMeta =
          '{\n  "a": "{n} x",\n  "@a": {\n    "placeholders": '
          '{"n": {}}\n  },\n  "b": "2"\n}\n';
      final arb = _arb(withMeta);
      expect(
        removeEntries(arb, {2}),
        '{\n  "a": "{n} x",\n  "@a": {\n    '
        '"placeholders": {"n": {}}\n  }\n}\n',
      );
      expect(removeEntries(arb, {0, 1}), '{\n  "b": "2"\n}\n');
    });
  });
}

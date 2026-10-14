import 'package:l10n_health/src/text_heuristics.dart';
import 'package:test/test.dart';

Confidence? _c(String s) => classifyLiteral(s)?.confidence;

void main() {
  group('classifyLiteral', () {
    test('flags prose', () {
      expect(_c('Bitte wählen Sie eine Apotheke'), Confidence.high);
      expect(_c('Please select a pharmacy'), Confidence.high);
      expect(_c('Molimo odaberite ljekarnu'), Confidence.high);
      expect(_c('Geöffnet'), Confidence.high);
      expect(_c('Order Summary'), Confidence.medium);
    });

    test('treats a lone capitalised ASCII word as low confidence', () {
      expect(_c('Save'), Confidence.low);
    });

    test('ignores identifiers, keys, paths and formats', () {
      for (final s in [
        'user_id',
        'camelCaseKey',
        'CONSTANT_VALUE',
        'assets/images/logo.png',
        '/home/settings',
        'https://example.com/a b',
        'name@example.com',
        'Product card/price',
        'Input fields/Input field/typing-text',
        'EEEE, dd. MMMM y',
        'HH:mm',
        '{} {} Android {} SDK {}',
        '<b>bold</b> text here',
        '12345',
        'ab',
      ]) {
        expect(_c(s), isNull, reason: s);
      }
    });
  });

  group('guessLanguage', () {
    test('picks the language with most function words', () {
      expect(guessLanguage('Bitte geben Sie Ihre Adresse ein'), 'de');
      expect(guessLanguage('Please enter your address and the city'), 'en');
    });

    test('returns null without enough signal', () {
      expect(guessLanguage('Coupon'), isNull);
    });
  });

  test('normaliseForMatch lines up placeholders', () {
    expect(
      normaliseForMatch('{count}  Artikel'),
      normaliseForMatch('{} artikel'),
    );
  });
}

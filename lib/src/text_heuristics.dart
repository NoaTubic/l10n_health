/// Heuristics for telling human-language text from identifiers, and for
/// guessing which language a short string is in.
library;

/// Common function words. Short UI strings rarely contain enough content
/// words for statistical detection, but they nearly always contain one of
/// these.
const Map<String, Set<String>> stopwords = {
  'de': {
    'der', 'die', 'das', 'und', 'ist', 'nicht', 'sie', 'ein', 'eine', //
    'einen', 'zu', 'mit', 'für', 'auf', 'ihre', 'ihr', 'ihren', 'bitte',
    'wird', 'werden', 'oder', 'auch', 'noch', 'kein', 'keine', 'im', 'den',
    'dem', 'des', 'von', 'bei', 'jetzt', 'hier', 'wurde', 'können',
    'sind', 'haben', 'mehr', 'zum', 'zur', 'über', 'nach', 'wir', 'uns',
    'es', 'ich', 'aus', 'wie', 'wenn', 'diese', 'dieser', 'alle',
  },
  'en': {
    'the', 'and', 'is', 'are', 'you', 'your', 'please', 'to', 'of', //
    'for', 'with', 'this', 'that', 'not', 'was', 'have', 'be', 'an',
    'in', 'on', 'it', 'we', 'our', 'can', 'will', 'has', 'no', 'or',
    'from', 'by', 'at', 'all', 'more', 'here', 'now', 'been', 'were',
    'there', 'which', 'when', 'what', 'how', 'my', 'do', 'does',
  },
  'hr': {
    'je', 'i', 'u', 'na', 'za', 'se', 'da', 'ne', 'su', 'sa', 'od', //
    'molimo', 'vaš', 'vaša', 'vaše', 'nije', 'ili', 'kao', 'to', 'koji',
    'koja', 'koje', 'biti', 'bit', 'će', 'ste', 'smo', 'sve', 'još',
    'već', 'iz', 'do', 'po', 'pri', 'kod', 'vam', 'vas', 'nema',
  },
  'fr': {
    'le', 'la', 'les', 'et', 'est', 'vous', 'pour', 'avec', 'une', //
    'des', 'pas', 'votre', 'vos', 'du', 'au', 'aux', 'dans', 'sur',
    'que', 'qui', 'ne', 'ce', 'cette', 'il', 'elle', 'nous', 'sont',
  },
  'es': {
    'el', 'la', 'los', 'las', 'y', 'es', 'para', 'con', 'una', 'por', //
    'que', 'no', 'su', 'sus', 'del', 'al', 'en', 'se', 'lo', 'usted',
    'este', 'esta', 'son', 'está', 'más',
  },
  'it': {
    'il', 'lo', 'la', 'gli', 'le', 'e', 'è', 'per', 'con', 'una', 'non', //
    'che', 'di', 'del', 'della', 'si', 'sono', 'tuo', 'tua', 'suo',
    'questo', 'questa', 'più', 'anche',
  },
};

final _wordPattern = RegExp(r"[\p{L}']+", unicode: true);
final _letter = RegExp(r'\p{L}', unicode: true);
final _nonAsciiLetter = RegExp(r'[^\x00-\x7F]', unicode: true);

/// Lowercase words in [text].
List<String> words(String text) => [
  for (final m in _wordPattern.allMatches(text.toLowerCase())) m.group(0)!,
];

bool hasLetter(String text) => _letter.hasMatch(text);

/// Guesses the language of [text] from function words. Returns null when
/// there is not enough signal (fewer than [minHits] hits, or a tie).
String? guessLanguage(
  String text, {
  Iterable<String>? candidates,
  int minHits = 2,
}) {
  final ws = words(text);
  if (ws.length < 2) return null;
  String? best;
  var bestScore = 0;
  var tie = false;
  for (final lang in candidates ?? stopwords.keys) {
    final set = stopwords[lang];
    if (set == null) continue;
    final score = ws.where(set.contains).length;
    if (score > bestScore) {
      best = lang;
      bestScore = score;
      tie = false;
    } else if (score == bestScore && score > 0) {
      tie = true;
    }
  }
  if (tie || bestScore < minHits) return null;
  return best;
}

/// How strongly a string literal looks like hardcoded UI text.
enum Confidence {
  low,
  medium,
  high;

  static Confidence parse(String raw) => switch (raw) {
    'low' => low,
    'medium' => medium,
    'high' => high,
    _ => throw FormatException('unknown confidence: $raw'),
  };
}

/// Verdict on a single string literal.
class TextVerdict {
  TextVerdict(this.confidence, this.reason, {this.language});
  final Confidence confidence;
  final String reason;
  final String? language;
}

final _url = RegExp(r'^[a-z][a-z0-9+.-]*://|^(mailto|tel|package|dart):');
final _path = RegExp(r'^(\.{0,2}/|assets/|images/|lib/|[A-Za-z]:\\)');
final _fileName = RegExp(r'^[\w\-./]+\.[a-z0-9]{1,5}$');
final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[a-z]{2,}$');
final _codeish = RegExp(r'^[A-Za-z0-9_.\-/:#@$%&*+=|\\<>\[\](){}^~]*$');
final _capitalisedWord = RegExp(r'^\p{Lu}\p{Ll}+[.!?:]?$', unicode: true);
final _sentenceEnd = RegExp(r'[.!?:]$');
final _slashPath = RegExp(r'^[^/\s][^/]*(/[^/\s][^/]*)+$');
final _dateFormat = RegExp(r"^[GyYMLdDEeHhmsSaKkZzQuv.,:/\-' ]+$");
final _repeatedLetter = RegExp(r'([A-Za-z])\1');
final _lowerToken = RegExp(r'^[a-z0-9_.\-]+$');

/// True for single lowercase tokens such as `email` or `apotheke`, which
/// are almost always identifiers even when a translation happens to match.
bool isLowercaseToken(String text) => _lowerToken.hasMatch(text.trim());

/// Classifies a literal's text. Returns null when it is clearly not prose:
/// identifiers, keys, URLs, paths, formats, numbers.
TextVerdict? classifyLiteral(String raw, {int minLength = 3}) {
  final text = raw.replaceAll('{}', ' ').trim();
  if (text.length < minLength || !hasLetter(text)) return null;
  if (_url.hasMatch(text) || _email.hasMatch(text)) return null;
  // HTML, XML, JSON and SQL fragments are not UI copy.
  if (text.startsWith('<') || text.startsWith('{') || text.startsWith('[')) {
    return null;
  }

  if (_dateFormat.hasMatch(text) && _repeatedLetter.hasMatch(text)) {
    return null; // 'EEEE, dd. MMMM y', 'HH:mm'
  }

  // Slash-separated names: design tokens ('Product card/price'), asset
  // folders, route segments.
  if (_slashPath.hasMatch(text) && !_sentenceEnd.hasMatch(text)) return null;

  final placeholders = '{}'.allMatches(raw).length;

  final hasSpace = text.contains(RegExp(r'\s'));
  final nonAscii = _nonAsciiLetter.hasMatch(text);

  if (!hasSpace) {
    if (_path.hasMatch(text) || _fileName.hasMatch(text)) return null;
    if (_capitalisedWord.hasMatch(text)) {
      return nonAscii
          ? TextVerdict(Confidence.high, 'word with non-ASCII letters')
          : TextVerdict(Confidence.low, 'single capitalised word');
    }
    if (nonAscii && !_codeish.hasMatch(text)) {
      return TextVerdict(Confidence.medium, 'contains non-ASCII letters');
    }
    return null;
  }

  final ws = words(text);
  final letterWords = ws.where((w) => w.length > 1).length;
  // Mostly interpolation: '{} {} Android {} SDK {}' is a format, not copy.
  if (placeholders > 0 && letterWords <= placeholders) return null;
  if (letterWords < 2) {
    return nonAscii
        ? TextVerdict(Confidence.medium, 'contains non-ASCII letters')
        : null;
  }
  final language = guessLanguage(text, minHits: 1);
  if (nonAscii) {
    return TextVerdict(
      Confidence.high,
      'prose with non-ASCII letters',
      language: language,
    );
  }
  if (language != null) {
    return TextVerdict(Confidence.high, 'prose', language: language);
  }
  final startsUpper = RegExp(r'^\p{Lu}', unicode: true).hasMatch(text);
  if (startsUpper || _sentenceEnd.hasMatch(text)) {
    return TextVerdict(Confidence.medium, 'sentence-like text');
  }
  return TextVerdict(Confidence.low, 'several words');
}

/// Normalises a translation or literal for matching: placeholders become
/// `{}`, whitespace collapses, case folds.
String normaliseForMatch(String text) =>
    text
        .replaceAll(RegExp(r'\{[^{}]*\}'), '{}')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();

/// Characters that are invisible or look like an ordinary space, and that
/// silently break search, diffs, parsing and string comparison.
///
/// Visible typography (curly quotes, dashes, accented letters, emoji) is
/// deliberately not listed.
const Map<int, String> invisibleCharacters = {
  0x00A0: 'NO-BREAK SPACE',
  0x00AD: 'SOFT HYPHEN',
  0x180E: 'MONGOLIAN VOWEL SEPARATOR',
  0x2000: 'EN QUAD',
  0x2001: 'EM QUAD',
  0x2002: 'EN SPACE',
  0x2003: 'EM SPACE',
  0x2004: 'THREE-PER-EM SPACE',
  0x2005: 'FOUR-PER-EM SPACE',
  0x2006: 'SIX-PER-EM SPACE',
  0x2007: 'FIGURE SPACE',
  0x2008: 'PUNCTUATION SPACE',
  0x2009: 'THIN SPACE',
  0x200A: 'HAIR SPACE',
  0x200B: 'ZERO WIDTH SPACE',
  0x200C: 'ZERO WIDTH NON-JOINER',
  0x200D: 'ZERO WIDTH JOINER',
  0x200E: 'LEFT-TO-RIGHT MARK',
  0x200F: 'RIGHT-TO-LEFT MARK',
  0x202A: 'LEFT-TO-RIGHT EMBEDDING',
  0x202B: 'RIGHT-TO-LEFT EMBEDDING',
  0x202C: 'POP DIRECTIONAL FORMATTING',
  0x202D: 'LEFT-TO-RIGHT OVERRIDE',
  0x202E: 'RIGHT-TO-LEFT OVERRIDE',
  0x202F: 'NARROW NO-BREAK SPACE',
  0x205F: 'MEDIUM MATHEMATICAL SPACE',
  0x2060: 'WORD JOINER',
  0x2061: 'FUNCTION APPLICATION',
  0x2062: 'INVISIBLE TIMES',
  0x2063: 'INVISIBLE SEPARATOR',
  0x2064: 'INVISIBLE PLUS',
  0x2066: 'LEFT-TO-RIGHT ISOLATE',
  0x2067: 'RIGHT-TO-LEFT ISOLATE',
  0x2068: 'FIRST STRONG ISOLATE',
  0x2069: 'POP DIRECTIONAL ISOLATE',
  0x3000: 'IDEOGRAPHIC SPACE',
  0xFEFF: 'ZERO WIDTH NO-BREAK SPACE (BOM)',
};

/// Unicode tag characters, U+E0000 to U+E007F, which can smuggle hidden
/// ASCII text inside an otherwise ordinary string.
bool isTagCharacter(int rune) => rune >= 0xE0000 && rune <= 0xE007F;

/// One invisible character found in a piece of text.
class InvisibleHit {
  InvisibleHit(this.rune, this.offset, this.line, this.column);

  final int rune;

  /// UTF-16 offset in the scanned text.
  final int offset;
  final int line;
  final int column;

  String get codepoint =>
      'U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  String get name =>
      invisibleCharacters[rune] ??
      (isTagCharacter(rune) ? 'TAG CHARACTER' : 'UNKNOWN');

  String get label => '$codepoint $name';
}

/// Finds every invisible character in [text], skipping codepoints listed in
/// [allow]. Lines and columns are 1-based; columns count UTF-16 units.
List<InvisibleHit> findInvisible(String text, {Set<int> allow = const {}}) {
  final hits = <InvisibleHit>[];
  var line = 1;
  var lineStart = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit == 0x0A) {
      line++;
      lineStart = i + 1;
      continue;
    }
    // Fast path: everything below U+00A0 is visible or ordinary whitespace.
    if (unit < 0xA0) continue;
    var rune = unit;
    if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length) {
      final low = text.codeUnitAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        rune = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
      }
    }
    final flagged =
        invisibleCharacters.containsKey(rune) || isTagCharacter(rune);
    if (flagged && !allow.contains(rune)) {
      hits.add(InvisibleHit(rune, i, line, i - lineStart + 1));
    }
    if (rune > 0xFFFF) i++;
  }
  return hits;
}

/// Parses `U+00A0`, `0xA0` or `00A0` into a codepoint.
int parseCodepoint(String raw) {
  final cleaned = raw.trim().toUpperCase().replaceFirst(
    RegExp(r'^(U\+|0X)'),
    '',
  );
  return int.parse(cleaned, radix: 16);
}

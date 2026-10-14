import 'dart:convert';
import 'dart:io';

/// One top-level member of an ARB file, with its source position.
class ArbEntry {
  ArbEntry({
    required this.key,
    required this.value,
    required this.line,
    required this.column,
    required this.keyStart,
    required this.valueEnd,
  });

  final String key;

  /// The decoded JSON value: a `String` for messages, a `Map` for `@key`
  /// metadata, anything else for malformed files.
  final Object? value;

  /// 1-based line of the key's opening quote.
  final int line;
  final int column;

  /// Offset of the key's opening quote in the file text.
  final int keyStart;

  /// Offset just past the end of the value.
  final int valueEnd;

  /// True for `@@locale`, `@key` and other metadata members.
  bool get isMeta => key.startsWith('@');
}

/// A parsed `.arb` file.
///
/// Parsed by hand rather than with `jsonDecode` for three reasons: findings
/// need line numbers, duplicate keys must be detected (a JSON decoder keeps
/// the last one silently), and pruning must edit the original text without
/// reformatting the rest of the file.
class ArbFile {
  ArbFile._({
    required this.path,
    required this.text,
    required this.entries,
    required this.locale,
  });

  /// Absolute path.
  final String path;
  final String text;

  /// Every top-level member in file order, duplicates included.
  final List<ArbEntry> entries;
  final String locale;

  /// Message entries keyed by name. For duplicated keys the last one wins,
  /// matching what the code generators do.
  late final Map<String, ArbEntry> messages = {
    for (final e in entries)
      if (!e.isMeta) e.key: e,
  };

  /// `@key` metadata keyed by the message name it describes.
  late final Map<String, ArbEntry> metadata = {
    for (final e in entries)
      if (e.key.startsWith('@') && !e.key.startsWith('@@'))
        e.key.substring(1): e,
  };

  /// String value of a message, or null when absent or not a string.
  String? valueOf(String key) {
    final v = messages[key]?.value;
    return v is String ? v : null;
  }

  static ArbFile load(String path, {String? fallbackLocale}) {
    final text = File(path).readAsStringSync();
    return parse(text, path: path, fallbackLocale: fallbackLocale);
  }

  static ArbFile parse(
    String text, {
    required String path,
    String? fallbackLocale,
  }) {
    final entries = _JsonObjectScanner(text, path).scan();
    String? locale;
    for (final e in entries) {
      if (e.key == '@@locale' && e.value is String) locale = e.value as String;
    }
    return ArbFile._(
      path: path,
      text: text,
      entries: entries,
      locale: locale ?? fallbackLocale ?? localeFromFileName(path) ?? 'und',
    );
  }

  /// Best-effort locale from names like `intl_de.arb`, `app_en_US.arb`,
  /// `app_zh_Hant.arb` or `de.arb`. Region subtags must be uppercase and
  /// scripts title-case, as gen_l10n requires; otherwise `app_en` would
  /// read as language "app", region "en".
  static String? localeFromFileName(String path) {
    final name = path.split(RegExp(r'[\\/]')).last.replaceAll('.arb', '');
    final match = RegExp(
      r'(?:^|_)([a-z]{2,3}(?:[_-](?:[A-Z][a-z]{3}|[A-Z]{2}|\d{3}))*)$',
    ).firstMatch(name);
    return match?.group(1);
  }
}

/// Raised when an ARB file is not valid JSON.
class ArbFormatException implements Exception {
  ArbFormatException(this.path, this.line, this.column, this.message);

  final String path;
  final int line;
  final int column;
  final String message;

  @override
  String toString() => '$path:$line:$column: $message';
}

/// Scans the top-level object of a JSON document, recording where each
/// member starts and ends. Nested values are decoded with `jsonDecode`
/// once their extent is known.
class _JsonObjectScanner {
  _JsonObjectScanner(this.text, this.path);

  final String text;
  final String path;
  int _i = 0;

  List<ArbEntry> scan() {
    final entries = <ArbEntry>[];
    // A UTF-8 BOM decodes to U+FEFF; tolerate it here and report it as an
    // invisible character elsewhere.
    if (text.startsWith('\uFEFF')) _i = 1;
    _ws();
    _expect('{');
    _ws();
    if (_peek == '}') return entries;
    while (true) {
      _ws();
      final keyStart = _i;
      final key = jsonDecode(text.substring(keyStart, _skipString())) as String;
      _ws();
      _expect(':');
      _ws();
      final valueStart = _i;
      _skipValue();
      final valueEnd = _i;
      final (line, column) = _position(keyStart);
      entries.add(
        ArbEntry(
          key: key,
          value: jsonDecode(text.substring(valueStart, valueEnd)),
          line: line,
          column: column,
          keyStart: keyStart,
          valueEnd: valueEnd,
        ),
      );
      _ws();
      if (_peek == ',') {
        _i++;
        continue;
      }
      _expect('}');
      return entries;
    }
  }

  String get _peek => _i < text.length ? text[_i] : '';

  void _ws() {
    while (_i < text.length && ' \t\r\n'.contains(text[_i])) {
      _i++;
    }
  }

  void _expect(String c) {
    if (_peek != c) _fail('expected "$c"');
    _i++;
  }

  /// Advances past a string starting at the current offset and returns the
  /// offset just after its closing quote.
  int _skipString() {
    if (_peek != '"') _fail('expected a string');
    _i++;
    while (_i < text.length) {
      final c = text[_i];
      if (c == '\\') {
        _i += 2;
        continue;
      }
      _i++;
      if (c == '"') return _i;
    }
    _fail('unterminated string');
  }

  void _skipValue() {
    final c = _peek;
    if (c == '"') {
      _skipString();
      return;
    }
    if (c == '{' || c == '[') {
      final close = c == '{' ? '}' : ']';
      _i++;
      _ws();
      if (_peek == close) {
        _i++;
        return;
      }
      while (true) {
        _ws();
        if (c == '{') {
          _skipString();
          _ws();
          _expect(':');
          _ws();
        }
        _skipValue();
        _ws();
        if (_peek == ',') {
          _i++;
          continue;
        }
        _expect(close);
        return;
      }
    }
    final literal = RegExp(
      r'-?\d+(\.\d+)?([eE][+-]?\d+)?|true|false|null',
    ).matchAsPrefix(text, _i);
    if (literal == null) _fail('unexpected character');
    _i = literal.end;
  }

  late final List<int> _lineStarts = [
    0,
    for (var k = 0; k < text.length; k++)
      if (text.codeUnitAt(k) == 0x0A) k + 1,
  ];

  (int, int) _position(int offset) {
    var lo = 0;
    var hi = _lineStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_lineStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return (lo + 1, offset - _lineStarts[lo] + 1);
  }

  Never _fail(String message) {
    final (line, column) = _position(_i.clamp(0, text.length));
    throw ArbFormatException(path, line, column, message);
  }
}

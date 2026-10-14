/// The parts of an ICU MessageFormat string that matter for consistency
/// across locales.
class IcuMessage {
  IcuMessage._(this.arguments, this.plurals, this.error);

  /// Every argument name, including arguments nested inside plural and
  /// select branches.
  final Set<String> arguments;

  /// Every cardinal `plural` in the message: its argument and the
  /// selectors it handles (`one`, `few`, `=0`, ...).
  final List<({String argument, Set<String> selectors})> plurals;

  /// Description of the first syntax error, or null when well-formed.
  final String? error;

  /// Parses [source]. Never throws; syntax problems land in [error].
  ///
  /// Apostrophes are treated as plain text. ICU uses them for quoting, but
  /// the Flutter generators only honour that when escaping is enabled, and
  /// treating every apostrophe in "Sie's" or "l'app" as a quote would
  /// misparse far more messages than it would fix.
  static IcuMessage parse(String source) {
    final parser = _Parser(source);
    try {
      parser.message(topLevel: true);
      return IcuMessage._(parser.arguments, parser.plurals, null);
    } on _IcuError catch (e) {
      return IcuMessage._(parser.arguments, parser.plurals, e.message);
    }
  }
}

class _IcuError implements Exception {
  _IcuError(this.message);
  final String message;
}

const _branchingTypes = {'plural', 'select', 'selectordinal'};

class _Parser {
  _Parser(this.s);

  final String s;
  int i = 0;
  final arguments = <String>{};
  final plurals = <({String argument, Set<String> selectors})>[];

  String get peek => i < s.length ? s[i] : '';

  /// Text and arguments until the end of input, or until the `}` closing a
  /// branch when nested.
  void message({required bool topLevel}) {
    while (i < s.length) {
      final c = s[i];
      if (c == '{') {
        i++;
        argument();
      } else if (c == '}') {
        if (topLevel) {
          throw _IcuError('unmatched "}" at position ${i + 1}');
        }
        return;
      } else {
        i++;
      }
    }
    if (!topLevel) throw _IcuError('unclosed "{"');
  }

  void argument() {
    ws();
    final name = identifier();
    if (name.isEmpty) {
      throw _IcuError('expected an argument name at position ${i + 1}');
    }
    arguments.add(name);
    ws();
    if (peek == '}') {
      i++;
      return;
    }
    expect(',');
    ws();
    final type = identifier();
    ws();
    if (peek == '}') {
      i++;
      return;
    }
    expect(',');
    if (_branchingTypes.contains(type)) {
      final selectors = branches(type);
      if (type == 'plural') {
        plurals.add((argument: name, selectors: selectors));
      }
    } else {
      skipStyle();
    }
  }

  Set<String> branches(String type) {
    final selectors = <String>{};
    var hasOther = false;
    while (true) {
      ws();
      if (peek == '}') {
        i++;
        if (selectors.isEmpty) throw _IcuError('$type without branches');
        // ICU requires `other`; generators reject or mis-handle messages
        // without it.
        if (!hasOther) throw _IcuError('$type has no "other" branch');
        return selectors;
      }
      if (peek.isEmpty) throw _IcuError('unclosed $type');
      final selector = selectorToken();
      if (selector.isEmpty) {
        throw _IcuError('expected a $type selector at position ${i + 1}');
      }
      ws();
      if (selector.startsWith('offset:')) continue;
      if (selector == 'other') hasOther = true;
      expect('{');
      message(topLevel: false);
      expect('}');
      selectors.add(selector);
    }
  }

  /// Skips a simple argument style such as `currency` or `yMMMd`, up to and
  /// including the closing brace.
  void skipStyle() {
    var depth = 0;
    while (i < s.length) {
      final c = s[i++];
      if (c == '{') depth++;
      if (c == '}') {
        if (depth == 0) return;
        depth--;
      }
    }
    throw _IcuError('unclosed argument style');
  }

  String identifier() {
    final start = i;
    while (i < s.length && RegExp(r'[A-Za-z0-9_]').hasMatch(s[i])) {
      i++;
    }
    return s.substring(start, i);
  }

  String selectorToken() {
    final start = i;
    while (i < s.length && !' \t\r\n{}'.contains(s[i])) {
      i++;
    }
    return s.substring(start, i);
  }

  void ws() {
    while (i < s.length && ' \t\r\n'.contains(s[i])) {
      i++;
    }
  }

  void expect(String c) {
    if (peek != c) {
      throw _IcuError(
        'expected "$c" at position ${i + 1}'
        '${peek.isEmpty ? ' (end of message)' : ', found "$peek"'}',
      );
    }
    i++;
  }
}

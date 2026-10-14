/// Severity of a single [Finding].
enum Severity {
  error,
  warning,
  info;

  static Severity parse(String raw) => switch (raw.toLowerCase()) {
    'error' => Severity.error,
    'warning' || 'warn' => Severity.warning,
    'info' => Severity.info,
    _ => throw FormatException('unknown severity: $raw'),
  };

  String get label => name.toUpperCase();

  /// True when this severity is at least as serious as [other].
  bool atLeast(Severity other) => index <= other.index;
}

/// One problem in the translation layer, anchored to a file and line.
class Finding {
  Finding({
    required this.check,
    required this.severity,
    required this.file,
    required this.line,
    required this.message,
    required this.identity,
    this.column = 1,
    this.key,
    this.locale,
    this.detail,
    this.related = const [],
  });

  /// Id of the check that produced this finding, e.g. `unused_key`.
  final String check;
  final Severity severity;

  /// Project-relative path.
  final String file;
  final int line;
  final int column;
  final String message;

  /// The ARB key concerned, when there is one.
  final String? key;

  /// The locale concerned, when there is one.
  final String? locale;

  /// Extra context: the offending literal, the translated value, a hint.
  final String? detail;

  /// Other keys involved, e.g. the rest of a duplicate-value group.
  final List<String> related;

  /// What makes this finding the same finding across runs. Deliberately
  /// excludes line numbers, so a baseline survives reformatting and edits
  /// elsewhere in the file.
  final String identity;

  /// Stable hash of [check] and [identity], used by the baseline.
  String get fingerprint => fnv1a('$check\u0000$identity');

  Map<String, Object?> toJson() => {
    'check': check,
    'severity': severity.name,
    'file': file,
    'line': line,
    'column': column,
    'message': message,
    if (key != null) 'key': key,
    if (locale != null) 'locale': locale,
    if (detail != null) 'detail': detail,
    if (related.isNotEmpty) 'related': related,
    'fingerprint': fingerprint,
  };

  @override
  String toString() => '$file:$line:$column $check';
}

/// FNV-1a 64-bit, rendered as 16 hex chars. Stable across runs and
/// platforms, which is all a baseline needs; this is not a security hash.
String fnv1a(String input) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = BigInt.parse('ffffffffffffffff', radix: 16);
  for (final unit in input.codeUnits) {
    hash = (hash ^ BigInt.from(unit)) * prime & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

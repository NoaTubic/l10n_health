import 'package:l10n_health/src/arb.dart';

/// How `sort` orders message keys.
enum SortOrder {
  /// Alphabetical, case-insensitive.
  alpha,

  /// The template file's order; keys the template lacks go last,
  /// alphabetically.
  template,
}

/// Returns [file]'s text with its entries reordered: `@@` file metadata
/// first, then each message followed by its `@key` metadata, then orphaned
/// metadata. Each entry's own text is kept byte for byte, so values and
/// nested metadata are never re-encoded.
String sortArb(
  ArbFile file, {
  SortOrder order = SortOrder.alpha,
  ArbFile? template,
}) {
  final entries = file.entries;
  if (entries.isEmpty) return file.text;

  final text = file.text;
  final newline = text.contains('\r\n') ? '\r\n' : '\n';
  final first = entries.first.keyStart;
  final lineStart = text.lastIndexOf('\n', first) + 1;
  final indentText = text.substring(lineStart, first);
  final indent =
      indentText.trim().isEmpty && indentText.isNotEmpty ? indentText : '  ';

  String slice(ArbEntry e) => text.substring(e.keyStart, e.valueEnd);

  final header = [
    for (final e in entries)
      if (e.key.startsWith('@@')) e,
  ];
  final messages = [
    for (final e in entries)
      if (!e.isMeta) e,
  ];
  final meta = <String, List<ArbEntry>>{};
  for (final e in entries) {
    if (e.isMeta && !e.key.startsWith('@@')) {
      meta.putIfAbsent(e.key.substring(1), () => []).add(e);
    }
  }

  final rank = <String, int>{};
  if (order == SortOrder.template && template != null) {
    var i = 0;
    for (final e in template.entries) {
      if (!e.isMeta) rank.putIfAbsent(e.key, () => i++);
    }
  }
  int compare(ArbEntry a, ArbEntry b) {
    final ra = rank[a.key];
    final rb = rank[b.key];
    if (ra != null && rb != null) return ra.compareTo(rb);
    if (ra != null) return -1;
    if (rb != null) return 1;
    final byLower = a.key.toLowerCase().compareTo(b.key.toLowerCase());
    return byLower != 0 ? byLower : a.key.compareTo(b.key);
  }

  final sorted = [...messages]..sort(compare);
  final out = <String>[
    for (final e in header) slice(e),
    for (final e in sorted) ...[
      slice(e),
      for (final m in meta.remove(e.key) ?? const <ArbEntry>[]) slice(m),
    ],
  ];
  // Metadata for keys that no longer exist: kept, at the end.
  final orphans = meta.keys.toList()..sort();
  for (final key in orphans) {
    for (final m in meta[key]!) {
      out.add(slice(m));
    }
  }

  final trailing = text.endsWith('\n') ? newline : '';
  return '{$newline$indent${out.join(',$newline$indent')}$newline}$trailing';
}

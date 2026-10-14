import 'dart:io';

import 'package:l10n_health/src/analysis.dart';
import 'package:l10n_health/src/arb.dart';
import 'package:path/path.dart' as p;

/// What a prune would do, or did.
class PrunePlan {
  PrunePlan({required this.keys, required this.skipped, required this.edits});

  /// Keys removed from every locale.
  final List<String> keys;

  /// Unused keys left alone, with the reason.
  final Map<String, String> skipped;

  /// New file contents keyed by absolute path, for files that change.
  final Map<String, FileEdit> edits;

  bool get isEmpty => keys.isEmpty;
}

class FileEdit {
  FileEdit(this.file, this.newText, this.removed);
  final ArbFile file;
  final String newText;

  /// Member names removed from this file, `@key` metadata included.
  final List<String> removed;
}

/// Raised when an edit would produce an ARB file that does not round-trip.
/// Nothing is written when this happens.
class PruneVerificationException implements Exception {
  PruneVerificationException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Plans removal of the keys `unused_key` reported.
///
/// Ambiguous keys are skipped unless [includeAmbiguous] is set: those whose
/// name is accessed through something other than the localizations class,
/// and those that appear as a string literal and so might be looked up
/// dynamically. Such a key is probably unused, but "probably" is not good
/// enough for a delete. Keys named in [only] count as reviewed and are
/// removed even when ambiguous.
PrunePlan planPrune(
  Analysis analysis, {
  bool includeAmbiguous = false,
  Set<String>? only,
}) {
  final unused = analysis.findings.where((f) => f.check == 'unused_key');
  final keys = <String>[];
  final skipped = <String, String>{};
  for (final f in unused) {
    final key = f.key!;
    if (only != null && !only.contains(key)) continue;
    // Naming a key in [only] is the explicit confirmation an ambiguous key
    // needs.
    final ambiguous = f.detail?.startsWith(ambiguousPrefix) ?? false;
    if (ambiguous && !includeAmbiguous && only == null) {
      skipped[key] = f.detail!;
      continue;
    }
    keys.add(key);
  }

  final remove = {...keys, for (final k in keys) '@$k'};
  final edits = <String, FileEdit>{};
  for (final file in analysis.arbFiles) {
    final indices = [
      for (var i = 0; i < file.entries.length; i++)
        if (remove.contains(file.entries[i].key)) i,
    ];
    if (indices.isEmpty) continue;
    final newText = removeEntries(file, indices.toSet());
    _verify(file, newText, remove);
    edits[file.path] = FileEdit(file, newText, [
      for (final i in indices) file.entries[i].key,
    ]);
  }
  return PrunePlan(keys: keys, skipped: skipped, edits: edits);
}

/// Writes a plan to disk. Each file is written to a temporary sibling first
/// and renamed into place, so an interrupted run never leaves a truncated
/// ARB file behind.
void applyPrune(PrunePlan plan) {
  for (final edit in plan.edits.values) {
    final tmp = File('${edit.file.path}.l10n_health.tmp');
    tmp.writeAsStringSync(edit.newText);
    tmp.renameSync(edit.file.path);
  }
}

/// Removes the members at [indices] from [file]'s text, leaving every other
/// byte, including formatting and comments-in-strings, untouched.
///
/// Works from the last member backwards so earlier offsets stay valid. A
/// member that is not the last surviving one is cut from its key to the
/// next member's key, taking its trailing comma and line break with it. The
/// last surviving member is cut from the end of the previous value, taking
/// the comma before it instead, so no trailing comma is left behind.
String removeEntries(ArbFile file, Set<int> indices) {
  final entries = file.entries;
  var text = file.text;
  var lastAlive = entries.length - 1;
  for (var i = entries.length - 1; i >= 0; i--) {
    if (!indices.contains(i)) continue;
    final e = entries[i];
    if (i == lastAlive) {
      final start = i == 0 ? e.keyStart : entries[i - 1].valueEnd;
      text = text.replaceRange(start, e.valueEnd, '');
      lastAlive = i - 1;
    } else {
      text = text.replaceRange(e.keyStart, entries[i + 1].keyStart, '');
    }
  }
  return text;
}

void _verify(ArbFile original, String newText, Set<String> removed) {
  final ArbFile reparsed;
  try {
    reparsed = ArbFile.parse(newText, path: original.path);
  } on ArbFormatException catch (e) {
    throw PruneVerificationException(
      'pruning ${p.basename(original.path)} would produce invalid JSON '
      '($e); nothing was written',
    );
  }
  final expected = [
    for (final e in original.entries)
      if (!removed.contains(e.key)) e.key,
  ];
  final actual = [for (final e in reparsed.entries) e.key];
  final same =
      expected.length == actual.length &&
      Iterable<int>.generate(
        expected.length,
      ).every((i) => expected[i] == actual[i]);
  if (!same) {
    throw PruneVerificationException(
      'pruning ${p.basename(original.path)} did not round-trip; '
      'nothing was written',
    );
  }
}

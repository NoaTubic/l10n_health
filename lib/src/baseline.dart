import 'dart:convert';
import 'dart:io';

import 'package:l10n_health/src/finding.dart';

/// A ratchet for adopting the tool on an existing project: findings recorded
/// in the baseline are reported as known and never fail the run; anything
/// new does.
class Baseline {
  Baseline._(this._counts);

  factory Baseline.empty() => Baseline._({});

  /// Loads [path], or an empty baseline when the file does not exist.
  factory Baseline.load(String path) {
    final file = File(path);
    if (!file.existsSync()) return Baseline.empty();
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final entries = (json['findings'] as List?) ?? const [];
    final counts = <String, int>{};
    for (final raw in entries.cast<Map<String, Object?>>()) {
      final fp = raw['fingerprint'] as String;
      counts[fp] = (counts[fp] ?? 0) + 1;
    }
    return Baseline._(counts);
  }

  final Map<String, int> _counts;

  bool get isEmpty => _counts.isEmpty;

  /// Splits [findings] into those not in the baseline and those that are.
  ({List<Finding> fresh, List<Finding> known}) partition(
    List<Finding> findings,
  ) {
    final remaining = Map.of(_counts);
    final fresh = <Finding>[];
    final known = <Finding>[];
    for (final f in findings) {
      final left = remaining[f.fingerprint] ?? 0;
      if (left > 0) {
        remaining[f.fingerprint] = left - 1;
        known.add(f);
      } else {
        fresh.add(f);
      }
    }
    return (fresh: fresh, known: known);
  }

  /// Writes [findings] as the new baseline. Entries are sorted so the file
  /// diffs cleanly in review.
  static void write(String path, List<Finding> findings) {
    final entries = [
      for (final f in findings)
        {
          'check': f.check,
          'fingerprint': f.fingerprint,
          'file': f.file,
          if (f.key != null) 'key': f.key,
        },
    ]..sort((a, b) {
      final byCheck = '${a['check']}'.compareTo('${b['check']}');
      if (byCheck != 0) return byCheck;
      final byFile = '${a['file']}'.compareTo('${b['file']}');
      if (byFile != 0) return byFile;
      return '${a['fingerprint']}'.compareTo('${b['fingerprint']}');
    });
    final json = const JsonEncoder.withIndent(
      '  ',
    ).convert({'version': 1, 'findings': entries});
    File(path).writeAsStringSync('$json\n');
  }
}

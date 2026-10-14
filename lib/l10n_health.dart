/// Health checks for the translation layer of Dart and Flutter apps.
///
/// Reads the project's `.arb` files and Dart sources, and reports unused
/// and missing keys, placeholder mismatches, malformed ICU messages,
/// duplicate and untranslated values, hardcoded UI strings and invisible
/// Unicode. Works with Flutter's `gen_l10n`, with `flutter_intl` /
/// `intl_utils`, and with any other ARB-based setup.
///
/// Most users want the command line interface:
///
/// ```sh
/// dart pub global activate l10n_health
/// l10n_health                          # check
/// l10n_health --format html -o l10n.html
/// l10n_health prune                    # dry run
/// l10n_health prune --apply
/// ```
///
/// This library is the programmatic entry point, for embedding the checks
/// in another tool.
library;

export 'src/analysis.dart' show Analysis, Stats, analyze;
export 'src/arb.dart' show ArbEntry, ArbFile, ArbFormatException;
export 'src/baseline.dart' show Baseline;
export 'src/cli.dart' show run;
export 'src/config.dart'
    show CheckConfig, L10nConfig, L10nConfigException, UsageMode;
export 'src/finding.dart' show Finding, Severity;
export 'src/icu.dart' show IcuMessage;
export 'src/prune.dart'
    show PrunePlan, PruneVerificationException, applyPrune, planPrune;
export 'src/report/html_report.dart' show renderHtml;
export 'src/report/text_reports.dart'
    show renderHuman, renderJson, renderMarkdown;
export 'src/text_heuristics.dart' show Confidence, classifyLiteral;
export 'src/unicode.dart' show InvisibleHit, findInvisible;

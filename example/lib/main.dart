// A Flutter app would import its generated localizations; this example
// only needs to parse, so the class is declared inline.
class AppLocalizations {
  static AppLocalizations of(Object context) => AppLocalizations();
  String get appTitle => '';
  String greeting(String name) => '';
  String itemCount(int count) => '';
  String get close => '';
}

extension L10n on Object {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

void build(Object context) {
  final l10n = AppLocalizations.of(context);
  label(l10n.appTitle);
  label(context.l10n.greeting('Ana'));
  label(AppLocalizations.of(context).itemCount(3));

  // Bypasses localization: German users see English.
  label('Please select a pharmacy');
  // Already translated as "close".
  label('Close');
}

void label(String text) {}

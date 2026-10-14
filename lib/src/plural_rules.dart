/// Cardinal plural categories per language, from the Unicode CLDR plural
/// rules. Languages not listed are not checked.
///
/// `many` for French, Spanish, Italian, Portuguese and Catalan only covers
/// numbers like 1 000 000, where `other` reads correctly, so it is treated
/// as optional for them; see [optionalCategories].
final Map<String, Set<String>> cldrCardinalCategories = {
  // other only
  for (final l in [
    'ja', 'zh', 'ko', 'th', 'vi', 'id', 'ms', 'my', 'lo', 'km', 'jv', 'su', //
    'yo', 'ig', 'bo', 'dz', 'to', 'yue',
  ])
    l: {'other'},
  // one, other
  for (final l in [
    'en', 'de', 'nl', 'sv', 'da', 'nb', 'no', 'nn', 'fi', 'et', 'el', 'hu', //
    'tr', 'bg', 'sq', 'af', 'az', 'eu', 'gl', 'ka', 'kk', 'ky', 'mn', 'ne',
    'sw', 'ta', 'te', 'ur', 'uz', 'ml', 'mr', 'kn', 'gu', 'hi', 'bn', 'fa',
    'am', 'zu', 'hy', 'is', 'mk', 'si', 'pa', 'or', 'as', 'ps', 'tk', 'fy',
    'lb', 'fil', 'tl',
  ])
    l: {'one', 'other'},
  // one, many, other
  for (final l in ['fr', 'es', 'it', 'pt', 'ca']) l: {'one', 'many', 'other'},
  // one, few, other
  for (final l in ['hr', 'sr', 'bs', 'ro', 'mo']) l: {'one', 'few', 'other'},
  // one, few, many, other
  for (final l in ['ru', 'uk', 'be', 'pl', 'lt', 'cs', 'sk'])
    l: {'one', 'few', 'many', 'other'},
  'sl': {'one', 'two', 'few', 'other'},
  'lv': {'zero', 'one', 'other'},
  'he': {'one', 'two', 'other'},
  'iw': {'one', 'two', 'other'},
  'ga': {'one', 'two', 'few', 'many', 'other'},
  'mt': {'one', 'two', 'few', 'many', 'other'},
  'ar': {'zero', 'one', 'two', 'few', 'many', 'other'},
  'cy': {'zero', 'one', 'two', 'few', 'many', 'other'},
};

/// Categories a language has but that are not worth requiring.
final Map<String, Set<String>> optionalCategories = {
  for (final l in ['fr', 'es', 'it', 'pt', 'ca']) l: {'many'},
};

/// `zero`, `one` and `two` are honoured by Dart's `intl` for exact counts
/// in every language, so they are never unused.
const intlExactCategories = {'zero', 'one', 'two'};

const allCategories = {'zero', 'one', 'two', 'few', 'many', 'other'};

/// Language subtag of a locale such as `pt_BR` or `zh-Hant`.
String languageOf(String locale) => locale.split(RegExp('[_-]')).first;

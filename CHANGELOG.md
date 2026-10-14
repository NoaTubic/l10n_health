# Changelog

## 0.1.1

- README: replaced the comparison with other packages by a short
  performance note.

## 0.1.0

First release.

- Sixteen checks: `arb_syntax`, `duplicate_key`, `placeholder_mismatch`,
  `icu_syntax`, `plural_forms` (CLDR), `locale_tag`, `missing_translation`,
  `empty_translation`, `invisible_unicode`, `hardcoded_string`,
  `unused_key`, `orphan_metadata`, `untranslated`, `duplicate_value`, and
  the opt-in `key_naming` and `missing_description`.
- Parallel scan across all cores; parse-only, so no `pub get` or resolved
  analysis is needed.
- `sort` command (alphabetical or template order, `--check` for CI).
- GitLab Code Quality and GitHub Actions annotation formats.
- `--keep`, `--sources`, `--quiet`; Pub workspace members scanned
  automatically.
- Auto-detects `gen_l10n` (`l10n.yaml`) and `flutter_intl` (`pubspec.yaml`);
  falls back to the directory holding the most `.arb` files.
- Strict usage detection through the localizations class, with aliases,
  getters and extensions found automatically; loose mode as a fallback.
- `prune` removes unused keys from every locale: dry run by default,
  text-level edits that keep formatting, round-trip verification before
  writing, atomic writes, ambiguous keys held back for review.
- Terminal, Markdown, JSON and self-contained HTML reports.
- Ratchet baseline, `--fail-on` threshold, inline suppressions.
- Works with `analyzer` 8 through 14, so it installs next to
  `build_runner`, `freezed` and `json_serializable` on current and older
  setups.

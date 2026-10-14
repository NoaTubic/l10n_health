import 'dart:convert';

import 'package:l10n_health/src/analysis.dart';
import 'package:l10n_health/src/finding.dart';
import 'package:l10n_health/src/report/summary.dart';

/// A single self-contained HTML file: no CDN, no web fonts, no network. It
/// is usually opened straight from disk or downloaded from a CI artifact.
String renderHtml(
  Analysis analysis,
  List<Finding> fresh,
  List<Finding> known, {
  required String projectName,
}) {
  final missing = <String, int>{};
  for (final f in fresh.where((f) => f.check == 'missing_translation')) {
    missing[f.locale!] = (missing[f.locale!] ?? 0) + 1;
  }
  final payload = jsonEncode({
    'project': projectName,
    'generated': DateTime.now().toIso8601String(),
    'stats': analysis.stats.toJson(),
    'missing': missing,
    'baselined': known.length,
    'checks': {
      for (final e in checkInfo.entries)
        e.key: {'title': e.value.$1, 'why': e.value.$2},
    },
    'findings': [for (final f in fresh) f.toJson()],
  }).replaceAll('</', r'<\/');

  return '<!doctype html>\n<html lang="en">\n<head>\n'
      '<meta charset="utf-8">\n'
      '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
      '<title>L10n Health Report</title>\n'
      '$_style</head>\n<body>\n$_markup'
      '<script id="data" type="application/json">$payload</script>\n'
      '$_script</body>\n</html>\n';
}

const _style = r'''<style>
:root {
  --ink: #1d2433; --muted: #5b6475; --faint: #8a93a3;
  --line: #e2e6ee; --ground: #f6f7fa; --surface: #ffffff;
  --brand: #3b5bdb; --brand-soft: #e8edff;
  --error: #c92a2a; --error-bg: #fff0f0;
  --warn: #a35a00; --warn-bg: #fff6e0;
  --info: #1864ab; --info-bg: #e7f3ff;
  --ok: #2b8a3e; --code: #f1f3f7;
  --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica,
    Arial, sans-serif;
  --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ink: #e6e9ef; --muted: #a3abba; --faint: #7d8696;
    --line: #2c3340; --ground: #13161c; --surface: #1b1f27;
    --brand: #8ea6ff; --brand-soft: #232b45;
    --error: #ff8787; --error-bg: #3a1f22;
    --warn: #ffc65c; --warn-bg: #3a2f17;
    --info: #74c0fc; --info-bg: #182a3d;
    --ok: #8ce99a; --code: #232832;
    color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --ink: #e6e9ef; --muted: #a3abba; --faint: #7d8696;
  --line: #2c3340; --ground: #13161c; --surface: #1b1f27;
  --brand: #8ea6ff; --brand-soft: #232b45;
  --error: #ff8787; --error-bg: #3a1f22;
  --warn: #ffc65c; --warn-bg: #3a2f17;
  --info: #74c0fc; --info-bg: #182a3d;
  --ok: #8ce99a; --code: #232832;
  color-scheme: dark;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--ground); color: var(--ink);
  font: 14px/1.5 var(--sans); }
main { max-width: 1120px; margin: 0 auto; padding: 32px 16px 64px; }
header { display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: baseline;
  justify-content: space-between; margin-bottom: 24px; }
h1 { font-size: 22px; margin: 0; letter-spacing: -0.01em; }
h1 span { color: var(--muted); font-weight: 500; }
.meta { color: var(--muted); font-size: 13px; }
button.theme { background: none; border: 1px solid var(--line);
  color: var(--muted); border-radius: 6px; padding: 4px 10px; cursor: pointer;
  font: inherit; font-size: 12px; }
.grid { display: grid; gap: 12px;
  grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); }
.card { background: var(--surface); border: 1px solid var(--line);
  border-radius: 10px; padding: 14px 16px; }
.tile .n { font-size: 26px; font-weight: 650; font-variant-numeric: tabular-nums; }
.tile .l { color: var(--muted); font-size: 12px; text-transform: uppercase;
  letter-spacing: .04em; }
.tile.error .n { color: var(--error); }
.tile.warning .n { color: var(--warn); }
.tile.info .n { color: var(--info); }
section { margin-top: 28px; }
h2 { font-size: 15px; margin: 0 0 10px; }
.locales { display: grid; gap: 10px; }
.loc { display: grid; grid-template-columns: 80px 1fr 150px; gap: 12px;
  align-items: center; }
.loc code { font-family: var(--mono); }
.bar { height: 8px; background: var(--code); border-radius: 4px;
  overflow: hidden; }
.bar i { display: block; height: 100%; background: var(--ok); }
.loc .v { color: var(--muted); font-size: 12px; text-align: right;
  font-variant-numeric: tabular-nums; }
.checks { display: grid; gap: 8px;
  grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); }
.check { text-align: left; cursor: pointer; font: inherit; color: inherit;
  display: flex; justify-content: space-between; gap: 8px; align-items: center; }
.check:hover, .check.on { border-color: var(--brand); }
.check.on { background: var(--brand-soft); }
.check .c { font-weight: 650; font-variant-numeric: tabular-nums; }
.dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block;
  margin-right: 8px; flex: none; }
.dot.error { background: var(--error); } .dot.warning { background: var(--warn); }
.dot.info { background: var(--info); }
.toolbar { display: flex; flex-wrap: wrap; gap: 8px; margin: 12px 0; }
.toolbar input, .toolbar select { font: inherit; padding: 7px 10px;
  border: 1px solid var(--line); border-radius: 8px; background: var(--surface);
  color: var(--ink); }
.toolbar input { flex: 1 1 240px; min-width: 0; }
.group { margin-top: 18px; }
.group h3 { font-size: 14px; margin: 0 0 2px; }
.group p.why { margin: 0 0 8px; color: var(--muted); font-size: 13px; }
.rows { background: var(--surface); border: 1px solid var(--line);
  border-radius: 10px; overflow: hidden; }
.row { padding: 9px 14px; border-top: 1px solid var(--line);
  display: grid; grid-template-columns: 64px 1fr; gap: 10px; }
.row:first-child { border-top: 0; }
.sev { font-size: 11px; font-weight: 650; text-transform: uppercase;
  padding: 1px 6px; border-radius: 4px; height: fit-content; text-align: center; }
.sev.error { color: var(--error); background: var(--error-bg); }
.sev.warning { color: var(--warn); background: var(--warn-bg); }
.sev.info { color: var(--info); background: var(--info-bg); }
.msg { overflow-wrap: anywhere; }
.loc-line { font-family: var(--mono); font-size: 12px; color: var(--faint); }
.detail { font-family: var(--mono); font-size: 12px; background: var(--code);
  border-radius: 6px; padding: 6px 8px; margin-top: 6px; white-space: pre-wrap;
  overflow-wrap: anywhere; }
.more { padding: 10px 14px; border-top: 1px solid var(--line); }
.more button { font: inherit; color: var(--brand); background: none;
  border: 0; cursor: pointer; padding: 0; }
.empty { color: var(--muted); padding: 24px; text-align: center; }
footer { margin-top: 40px; color: var(--faint); font-size: 12px; }
@media (max-width: 560px) {
  .loc { grid-template-columns: 56px 1fr; }
  .loc .v { grid-column: 2; text-align: left; }
  .row { grid-template-columns: 1fr; gap: 4px; }
  .sev { width: fit-content; }
}
</style>
''';

const _markup = '''<main>
<header>
  <div>
    <h1>L10n health <span id="project"></span></h1>
    <div class="meta" id="meta"></div>
  </div>
  <button class="theme" id="theme" type="button">Theme</button>
</header>
<div class="grid" id="tiles"></div>
<section><h2>Locale coverage</h2><div class="card locales" id="locales"></div></section>
<section><h2>Checks</h2><div class="checks" id="checks"></div></section>
<section>
  <h2>Findings</h2>
  <div class="toolbar">
    <input id="q" type="search" placeholder="Filter by key, file or text" aria-label="Filter findings">
    <select id="sev" aria-label="Severity">
      <option value="">All severities</option>
      <option value="error">Errors</option>
      <option value="warning">Warnings</option>
      <option value="info">Info</option>
    </select>
    <select id="locale" aria-label="Locale"><option value="">All locales</option></select>
  </div>
  <div id="list"></div>
</section>
<footer id="footer"></footer>
</main>
''';

const _script = r'''<script>
(() => {
  const data = JSON.parse(document.getElementById('data').textContent);
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? '').replace(/[&<>"]/g,
    (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
  const st = data.stats;
  const order = Object.keys(data.checks);
  const state = { check: '', q: '', sev: '', locale: '', open: new Set() };
  const PAGE = 100;

  $('project').textContent = '· ' + data.project;
  $('meta').textContent = `${st.generator} · template ${st.templateLocale} · ` +
    `${st.keys} keys · ${st.dartFiles} Dart files · ${st.usageMode} usage · ` +
    new Date(data.generated).toLocaleString();

  const count = (pred) => data.findings.filter(pred).length;
  const tiles = [
    ['error', 'Errors', count((f) => f.severity === 'error')],
    ['warning', 'Warnings', count((f) => f.severity === 'warning')],
    ['info', 'Info', count((f) => f.severity === 'info')],
    ['', 'Unused keys', count((f) => f.check === 'unused_key')],
    ['', 'Hardcoded strings', count((f) => f.check === 'hardcoded_string')],
  ];
  $('tiles').innerHTML = tiles.map(([cls, label, n]) =>
    `<div class="card tile ${cls}"><div class="n">${n}</div>` +
    `<div class="l">${label}</div></div>`).join('');

  const total = st.keys || 1;
  $('locales').innerHTML = Object.entries(st.locales).map(([loc, n]) => {
    const miss = data.missing[loc] || 0;
    const pct = Math.round(((total - miss) / total) * 1000) / 10;
    const tag = loc === st.templateLocale ? ' (template)' : '';
    return `<div class="loc"><code>${esc(loc)}</code>` +
      `<div class="bar"><i style="width:${pct}%"></i></div>` +
      `<div class="v">${n} keys · ${miss} missing${esc(tag)}</div></div>`;
  }).join('');

  const locales = Object.keys(st.locales);
  $('locale').innerHTML += locales.map((l) =>
    `<option value="${esc(l)}">${esc(l)}</option>`).join('');

  const worst = (list) => list.some((f) => f.severity === 'error') ? 'error'
    : list.some((f) => f.severity === 'warning') ? 'warning' : 'info';

  function renderChecks() {
    const groups = order.map((id) => [id, data.findings.filter((f) => f.check === id)])
      .filter(([, l]) => l.length);
    $('checks').innerHTML = groups.length ? groups.map(([id, l]) =>
      `<button type="button" class="card check ${state.check === id ? 'on' : ''}" data-check="${id}">` +
      `<span><span class="dot ${worst(l)}"></span>${esc(data.checks[id].title)}</span>` +
      `<span class="c">${l.length}</span></button>`).join('')
      : '<div class="card empty">No findings. The translation layer is healthy.</div>';
    for (const b of document.querySelectorAll('[data-check]')) {
      b.onclick = () => {
        state.check = state.check === b.dataset.check ? '' : b.dataset.check;
        renderChecks(); renderList();
      };
    }
  }

  function matches(f) {
    if (state.check && f.check !== state.check) return false;
    if (state.sev && f.severity !== state.sev) return false;
    if (state.locale && f.locale !== state.locale) return false;
    if (!state.q) return true;
    const hay = [f.message, f.file, f.key, f.detail, f.locale].join(' ').toLowerCase();
    return hay.includes(state.q);
  }

  function row(f) {
    const detail = f.detail && f.detail !== f.message
      ? `<div class="detail">${esc(f.detail)}</div>` : '';
    return `<div class="row"><span class="sev ${f.severity}">${f.severity}</span>` +
      `<div><div class="msg">${esc(f.message)}</div>` +
      `<div class="loc-line">${esc(f.file)}:${f.line}:${f.column}</div>${detail}</div></div>`;
  }

  function renderList() {
    const list = data.findings.filter(matches);
    if (!list.length) { $('list').innerHTML = '<div class="card empty">Nothing matches.</div>'; return; }
    const html = [];
    for (const id of order) {
      const g = list.filter((f) => f.check === id);
      if (!g.length) continue;
      const open = state.open.has(id);
      const shown = open ? g : g.slice(0, PAGE);
      html.push(`<div class="group"><h3>${esc(data.checks[id].title)} · ${g.length}</h3>` +
        `<p class="why">${esc(data.checks[id].why)}</p><div class="rows">` +
        shown.map(row).join('') +
        (g.length > shown.length
          ? `<div class="more"><button type="button" data-more="${id}">Show all ${g.length}</button></div>` : '') +
        '</div></div>');
    }
    $('list').innerHTML = html.join('');
    for (const b of document.querySelectorAll('[data-more]')) {
      b.onclick = () => { state.open.add(b.dataset.more); renderList(); };
    }
  }

  $('q').oninput = (e) => { state.q = e.target.value.trim().toLowerCase(); renderList(); };
  $('sev').onchange = (e) => { state.sev = e.target.value; renderList(); };
  $('locale').onchange = (e) => { state.locale = e.target.value; renderList(); };

  const root = document.documentElement;
  let theme = null;
  try { theme = localStorage.getItem('l10n_health_theme'); } catch (_) {}
  if (theme) root.dataset.theme = theme;
  $('theme').onclick = () => {
    const dark = root.dataset.theme
      ? root.dataset.theme === 'dark'
      : matchMedia('(prefers-color-scheme: dark)').matches;
    root.dataset.theme = dark ? 'light' : 'dark';
    try { localStorage.setItem('l10n_health_theme', root.dataset.theme); } catch (_) {}
  };

  $('footer').textContent = `Generated by l10n_health in ${st.elapsedMs} ms` +
    (data.baselined ? ` · ${data.baselined} findings hidden by baseline` : '');

  renderChecks(); renderList();
})();
</script>
''';

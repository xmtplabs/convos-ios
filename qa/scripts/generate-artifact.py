#!/usr/bin/env python3
"""generate-artifact.py -- render a QA run into a self-contained HTML artifact.

Reads everything CXDB recorded for a run (tests, criteria, screenshots, log
entries, events, bugs, accessibility findings, perf measurements) plus the
per-layer log files captured by capture-logs.sh, analyzes the logs for
errors, and writes a single-page HTML report to:

    qa/artifacts/run-<run_id>/index.html

The page follows the convos-assistants design framework (DESIGN.md tokens:
monochrome + orange accent, system type, light/dark via prefers-color-scheme)
and is fully offline: inline CSS/JS, screenshots referenced relatively, so
the run-<run_id>/ directory can be zipped and shared as-is.

Layout: screenshot carousel up top, run summary (with log analysis and watch
items) below it, then three tabs: Tests, Logs, Findings.

Usage:
    generate-artifact.py <run_id>             # write the artifact
    generate-artifact.py <run_id> --analyze   # print log analysis only (no HTML)
    generate-artifact.py --latest             # most recent run in CXDB
"""

import argparse
import html
import json
import re
import sqlite3
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DB_PATH = REPO_ROOT / "qa" / "cxdb" / "qa.sqlite"

MAX_EMBED_LINES = 2500   # per layer; longer logs embed head + tail
EMBED_HEAD = 300
MAX_EVENTS = 300
MAX_SAMPLE_ERRORS = 5    # representative error lines per layer in the summary

LAYER_LABELS = {
    "app": "iOS App",
    "backend": "Backend",
    "herald": "Herald",
    "worker": "Assistants Worker",
    "convos_db": "Postgres",
    "postgres": "Postgres",
    "minio": "MinIO",
}

PINO_LEVELS = {10: "debug", 20: "debug", 30: "info", 40: "warning", 50: "error", 60: "error"}


def esc(value):
    return html.escape(str(value if value is not None else ""), quote=True)


def classify_line(layer, line):
    """Best-effort log level for a single line of a given layer's log."""
    stripped = line.strip()
    if not stripped:
        return "info"
    if layer == "app":
        m = re.match(r"^\[[^\]]+\] \[(\w+)\]", stripped)
        if m:
            lvl = m.group(1).lower()
            return lvl if lvl in ("error", "warning") else "info"
        return "info"
    if stripped.startswith("{"):
        try:
            obj = json.loads(stripped)
            lvl = obj.get("level")
            if isinstance(lvl, int):
                return PINO_LEVELS.get(lvl, "info")
            if isinstance(lvl, str):
                lvl = lvl.lower()
                if lvl in ("error", "fatal"):
                    return "error"
                if lvl in ("warn", "warning"):
                    return "warning"
                return "info"
        except (json.JSONDecodeError, AttributeError):
            pass
    if layer in ("convos_db", "postgres"):
        if re.search(r"\b(ERROR|FATAL|PANIC):", stripped):
            return "error"
        if "WARNING:" in stripped:
            return "warning"
        return "info"
    # Pino pretty output and generic fallback
    if re.search(r"\b(ERROR|FATAL)\b", stripped) or re.search(r"\berror\b", stripped[:160]):
        return "error"
    if re.search(r"\bWARN(ING)?\b", stripped, re.IGNORECASE):
        return "warning"
    return "info"


def analyze_log_file(path):
    layer = path.stem
    lines = []
    try:
        text = path.read_text(errors="replace")
    except OSError as exc:
        print(f"warning: could not read {path}: {exc}", file=sys.stderr)
        return None
    raw = text.splitlines()
    errors = warnings = 0
    samples = []
    seen = set()
    for idx, line in enumerate(raw, 1):
        lvl = classify_line(layer, line)
        if lvl == "error":
            errors += 1
            key = re.sub(r"\d+", "#", line.strip())[:160]
            if key not in seen and len(samples) < MAX_SAMPLE_ERRORS * 4:
                seen.add(key)
                samples.append((idx, line.strip()))
        elif lvl == "warning":
            warnings += 1
        lines.append((line, lvl))
    return {
        "layer": layer,
        "label": LAYER_LABELS.get(layer, layer.replace("-", " ").title()),
        "path": path,
        "total": len(raw),
        "errors": errors,
        "warnings": warnings,
        "samples": samples[:MAX_SAMPLE_ERRORS],
        "lines": lines,
    }


def analyze_logs(log_dir):
    if not log_dir.is_dir():
        return []
    results = []
    for path in sorted(log_dir.glob("*.log")):
        result = analyze_log_file(path)
        if result is not None:
            results.append(result)
    # App first, then stack services, then the rest alphabetically
    order = {"app": 0, "backend": 1, "herald": 2, "worker": 3, "convos_db": 4, "postgres": 4, "minio": 5}
    results.sort(key=lambda r: (order.get(r["layer"], 9), r["layer"]))
    return results


def fmt_duration(ms):
    if ms is None:
        return "-"
    seconds = int(ms / 1000)
    if seconds < 60:
        return f"{seconds}s"
    minutes, secs = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m {secs:02d}s"
    hours, mins = divmod(minutes, 60)
    return f"{hours}h {mins:02d}m"


def run_duration(run):
    from datetime import datetime
    try:
        start = datetime.fromisoformat(run["started_at"].replace("Z", "+00:00"))
        end = datetime.fromisoformat(run["finished_at"].replace("Z", "+00:00"))
        return fmt_duration((end - start).total_seconds() * 1000)
    except (TypeError, ValueError, AttributeError):
        return "-"


def status_pill(status):
    cls = {
        "pass": "ok", "passed": "ok",
        "fail": "bad", "failed": "bad", "error": "bad",
        "skip": "dim", "aborted": "dim",
    }.get(status, "warn")
    return f'<span class="pill pill-{cls}">{esc(status)}</span>'


def load_run_data(conn, run_id):
    conn.row_factory = sqlite3.Row
    run = conn.execute("SELECT * FROM test_runs WHERE id=?", (run_id,)).fetchone()
    if run is None:
        sys.exit(f"error: no run '{run_id}' in {DB_PATH}")
    data = {"run": dict(run)}
    data["tests"] = [dict(r) for r in conn.execute(
        "SELECT * FROM test_results WHERE run_id=? ORDER BY started_at, test_id", (run_id,))]
    data["criteria"] = {}
    for row in conn.execute(
            "SELECT cr.* FROM criteria_results cr JOIN test_results tr ON cr.test_result_id=tr.id "
            "WHERE tr.run_id=?", (run_id,)):
        data["criteria"].setdefault(row["test_result_id"], []).append(dict(row))
    data["screenshots"] = [dict(r) for r in conn.execute(
        "SELECT * FROM screenshots WHERE run_id=? ORDER BY id", (run_id,))]
    data["log_entries"] = [dict(r) for r in conn.execute(
        "SELECT * FROM log_entries WHERE run_id=? ORDER BY id", (run_id,))]
    data["events"] = [dict(r) for r in conn.execute(
        "SELECT * FROM app_events WHERE run_id=? ORDER BY timestamp", (run_id,))]
    data["bugs"] = [dict(r) for r in conn.execute(
        "SELECT * FROM bug_findings WHERE run_id=? ORDER BY CASE severity "
        "WHEN 'critical' THEN 0 WHEN 'major' THEN 1 ELSE 2 END", (run_id,))]
    data["a11y"] = [dict(r) for r in conn.execute(
        "SELECT * FROM accessibility_findings WHERE run_id=?", (run_id,))]
    data["perf"] = [dict(r) for r in conn.execute(
        "SELECT * FROM perf_measurements WHERE run_id=?", (run_id,))]
    data["state"] = {r["key"]: r["value"] for r in conn.execute(
        "SELECT key, value FROM run_state WHERE run_id=?", (run_id,))}
    return data


def order_screenshots(data, artifact_dir):
    """Carousel order: group frames by test (in execution order), then capture order."""
    test_order = {}
    for i, t in enumerate(data["tests"]):
        test_order.setdefault(t["test_id"], i)
    shots = []
    for s in data["screenshots"]:
        rel = s["path"]
        if not (artifact_dir / rel).is_file():
            continue
        shots.append(s)
    shots.sort(key=lambda s: (test_order.get(s["test_id"], 999), s["id"]))
    return shots


def known_test_ids():
    ids = set()
    for p in (REPO_ROOT / "qa" / "tests" / "structured").glob("*.yaml"):
        m = re.match(r"^(\d+[a-z]?)-", p.name)
        if m:
            ids.add(m.group(1))
    return ids


def run_scope_title(data):
    """Human title for what the run covered: a test name, 'Full Suite', etc."""
    tests = data["tests"]
    if not tests:
        return "QA Run"
    names = []
    seen = set()
    for t in tests:
        if t["test_id"] not in seen:
            seen.add(t["test_id"])
            names.append(t["test_name"] or f"Test {t['test_id']}")
    if len(names) == 1:
        return names[0]
    if len(names) == 2:
        return f"{names[0]} + {names[1]}"
    known = known_test_ids()
    if known and len(seen & known) >= len(known) * 0.8:
        return "Full Suite"
    ids = sorted(seen)
    shown = ", ".join(ids[:6]) + ("…" if len(ids) > 6 else "")
    return f"{len(seen)} Tests ({shown})"


def narrative_html(text):
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text or "") if p.strip()]
    return "".join(f"<p>{esc(p)}</p>" for p in paragraphs)


# ---------------------------------------------------------------------------
# HTML sections
# ---------------------------------------------------------------------------

BRAND_MARK = (
    '<svg class="brand-mark" viewBox="0 0 28 36" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">'
    '<path d="M27.7736 13.8868C27.7736 21.5563 21.5563 27.7736 13.8868 27.7736C6.21733 27.7736 0 '
    '21.5563 0 13.8868C0 6.21733 6.21733 0 13.8868 0C21.5563 0 27.7736 6.21733 27.7736 13.8868Z"/>'
    '<path d="M13.8868 27.7736L18.0699 35.0189H9.70373L13.8868 27.7736Z"/></svg>'
)


def render_hero(data):
    run = data["run"]
    tests = data["tests"]
    passed = sum(1 for t in tests if t["status"] == "pass")
    total = len(tests)
    date = (run.get("started_at") or "")[:10]
    dek = f"{passed} of {total} tests passed in {run_duration(run)}."
    bugs = len(data["bugs"])
    if bugs:
        dek += f" {bugs} bug{'s' if bugs != 1 else ''} filed."
    byline = " · ".join(x for x in [f"run {run['id']}", run.get("device_type"), run.get("build_commit"), date] if x)
    return f"""
  <header class="hero">
    <div class="eyebrow-row">
      <p class="eyebrow">{BRAND_MARK}<span>QA Run</span></p>
      <p class="byline">{esc(byline)}</p>
    </div>
    <h1 class="title">{esc(run_scope_title(data))} {status_pill(run['status'])}</h1>
    <p class="dek">{esc(dek)}</p>
  </header>
  <hr class="divider">"""


def render_carousel(shots):
    if not shots:
        return """
  <section class="panel">
    <p class="empty">No screenshots were captured for this run. Runners record frames via qa/scripts/snap.sh.</p>
  </section>"""
    thumbs = []
    for i, s in enumerate(shots):
        thumbs.append(
            f'<button class="thumb" data-i="{i}" onclick="carGo({i})">'
            f'<img src="{esc(s["path"])}" loading="lazy" alt=""></button>'
        )
    payload = [{
        "src": s["path"],
        "test": s["test_id"] or "",
        "step": s["step_id"] or "",
        "caption": s["caption"] or "",
        "at": (s["taken_at"] or "")[11:19],
    } for s in shots]
    shots_json = json.dumps(payload).replace("</", "<\\/")
    return f"""
  <section class="carousel" aria-label="Run screenshots">
    <div class="carousel-main">
      <button class="car-nav" id="car-prev" onclick="carStep(-1)" aria-label="Previous frame">&#8249;</button>
      <img id="car-img" src="{esc(shots[0]['path'])}" alt="" onclick="carStep(1)">
      <button class="car-nav" id="car-next" onclick="carStep(1)" aria-label="Next frame">&#8250;</button>
    </div>
    <div class="car-meta">
      <span id="car-caption"></span>
      <span id="car-counter" class="car-counter"></span>
    </div>
    <div class="car-strip" id="car-strip">{''.join(thumbs)}</div>
  </section>
  <script>const SHOTS = {shots_json};</script>"""


def render_summary(data, layers):
    run = data["run"]
    tests = data["tests"]
    counts = {"pass": 0, "fail": 0, "error": 0, "skip": 0}
    for t in tests:
        if t["status"] in counts:
            counts[t["status"]] += 1
    crit_total = sum(len(v) for v in data["criteria"].values())
    crit_pass = sum(1 for v in data["criteria"].values() for c in v if c["status"] == "pass")
    app_errors = sum(1 for e in data["log_entries"] if e.get("is_app_error"))
    xmtp_errors = sum(1 for e in data["log_entries"] if e.get("is_xmtp_error"))

    tiles = [
        (str(counts["pass"]), "tests passed", "ok" if counts["pass"] else ""),
        (str(counts["fail"] + counts["error"]), "tests failed", "bad" if (counts["fail"] + counts["error"]) else "ok"),
        (f"{crit_pass}/{crit_total}", "criteria met", ""),
        (str(len(data["bugs"])), "bugs found", "bad" if data["bugs"] else "ok"),
        (str(app_errors), "app errors", "bad" if app_errors else "ok"),
        (str(xmtp_errors), "XMTP errors", "warn" if xmtp_errors else "ok"),
        (run_duration(run), "duration", ""),
        (str(sum(l["errors"] for l in layers)), "log errors",
         "bad" if any(l["errors"] for l in layers) else "ok"),
    ]
    tiles_html = "".join(
        f'<div class="tile"><p class="tile-value {("tile-" + tone) if tone else ""}">{esc(v)}</p>'
        f'<p class="tile-label">{esc(label)}</p></div>'
        for v, label, tone in tiles)

    # Watch items: failed tests, serious bugs, noisy layers
    watch = []
    for t in tests:
        if t["status"] in ("fail", "error"):
            reason = t.get("error_message") or t.get("notes") or "see Tests tab"
            watch.append(f"<strong>Test {esc(t['test_id'])} {esc(t['status'])}ed</strong> — {esc(reason)}")
    for b in data["bugs"]:
        if b["severity"] in ("critical", "major"):
            watch.append(f"<strong>[{esc(b['severity'])}] {esc(b['title'])}</strong>")
    for l in layers:
        if l["errors"]:
            sample = esc(l["samples"][0][1][:140]) if l["samples"] else ""
            watch.append(
                f"<strong>{esc(l['label'])}</strong> logged {l['errors']} error line"
                f"{'s' if l['errors'] != 1 else ''} — e.g. <code>{sample}</code>")
    watch_html = ("<ul class='watch'>" + "".join(f"<li>{w}</li>" for w in watch) + "</ul>") if watch \
        else "<p class='empty'>Nothing flagged — no failed tests, no serious bugs, no error lines in any captured layer.</p>"

    narrative = data["state"].get("analysis_md", "")
    narrative_block = (
        f'<div class="callout"><p class="callout-label">Analysis</p>{narrative_html(narrative)}</div>'
    ) if narrative else ""

    if layers:
        rows = "".join(
            f"<tr><td>{esc(l['label'])}</td><td>{l['total']:,}</td>"
            f"<td class=\"{'cell-bad' if l['errors'] else ''}\">{l['errors']}</td>"
            f"<td class=\"{'cell-warn' if l['warnings'] else ''}\">{l['warnings']}</td></tr>"
            for l in layers)
        layer_table = f"""
      <h3>Captured log layers</h3>
      <table class="stats-table">
        <thead><tr><th>Layer</th><th>Lines</th><th>Errors</th><th>Warnings</th></tr></thead>
        <tbody>{rows}</tbody>
      </table>"""
    else:
        layer_table = ("<p class='empty'>No log files were captured for this run "
                       "(qa/scripts/capture-logs.sh was not used).</p>")

    return f"""
  <section class="panel">
    <h2>Summary</h2>
    <div class="tiles">{tiles_html}</div>
    {narrative_block}
    <h3>Watch items</h3>
    {watch_html}
    {layer_table}
  </section>"""


def render_tests_tab(data, shots):
    if not data["tests"]:
        return "<p class='empty'>No tests recorded for this run.</p>"
    first_shot_index = {}
    for i, s in enumerate(shots):
        first_shot_index.setdefault(s["test_id"], i)
    cards = []
    for t in data["tests"]:
        crit = data["criteria"].get(t["id"], [])
        crit_rows = []
        for c in crit:
            mark = {"pass": "&#10003;", "fail": "&#10007;"}.get(c["status"], "&#8211;")
            cls = {"pass": "crit-pass", "fail": "crit-fail"}.get(c["status"], "crit-skip")
            evidence = f'<span class="crit-evidence">{esc(c["evidence"])}</span>' if c.get("evidence") else ""
            crit_rows.append(
                f'<li class="{cls}"><span class="crit-mark">{mark}</span>'
                f'<span><strong>{esc(c["criteria_key"])}</strong> — {esc(c["description"])} {evidence}</span></li>')
        crit_html = f"<ul class='criteria'>{''.join(crit_rows)}</ul>" if crit_rows \
            else "<p class='empty'>No criteria recorded.</p>"
        err = f'<p class="test-error">{esc(t["error_message"])}</p>' if t.get("error_message") else ""
        notes = f'<p class="test-notes">{esc(t["notes"])}</p>' if t.get("notes") else ""
        jump = ""
        if t["test_id"] in first_shot_index:
            jump = (f'<button class="chip" onclick="carGo({first_shot_index[t["test_id"]]});'
                    f'window.scrollTo({{top:0,behavior:\'smooth\'}})">View frames</button>')
        cards.append(f"""
      <div class="card">
        <div class="card-head">
          <p class="card-title">{esc(t['test_id'])} — {esc(t['test_name'] or '')}</p>
          <div class="card-head-right">{jump}{status_pill(t['status'])}
            <span class="card-duration">{fmt_duration(t.get('duration_ms'))}</span></div>
        </div>
        {err}{notes}{crit_html}
      </div>""")
    return "".join(cards)


def render_logs_tab(layers):
    if not layers:
        return ("<p class='empty'>No log files captured. Run qa/scripts/capture-logs.sh start "
                "at the beginning of the run and dump at the end.</p>")
    chips = []
    panes = []
    for i, l in enumerate(layers):
        active = " active" if i == 0 else ""
        badge = f'<span class="chip-badge">{l["errors"]}</span>' if l["errors"] else ""
        chips.append(
            f'<button class="chip layer-chip{active}" data-layer="{esc(l["layer"])}" '
            f'onclick="showLayer(\'{esc(l["layer"])}\')">{esc(l["label"])}{badge}</button>')
        lines = l["lines"]
        truncated_note = ""
        if len(lines) > MAX_EMBED_LINES:
            omitted = len(lines) - EMBED_HEAD - (MAX_EMBED_LINES - EMBED_HEAD)
            head = lines[:EMBED_HEAD]
            tail = lines[-(MAX_EMBED_LINES - EMBED_HEAD):]
            truncated_note = (
                f'<div class="ll lvl-meta">... {omitted:,} lines omitted '
                f'(full log: logs/{esc(l["layer"])}.log) ...</div>')
            rendered = head + [None] + tail
        else:
            rendered = lines
        body = []
        for item in rendered:
            if item is None:
                body.append(truncated_note)
                continue
            text, lvl = item
            body.append(f'<div class="ll lvl-{lvl}">{esc(text) or "&nbsp;"}</div>')
        stats = (f'{l["total"]:,} lines · <span class="cell-bad">{l["errors"]} errors</span> · '
                 f'<span class="cell-warn">{l["warnings"]} warnings</span>')
        panes.append(f"""
      <div class="log-pane{active}" data-layer="{esc(l['layer'])}" data-filter="all">
        <div class="log-toolbar">
          <span class="log-stats">{stats}</span>
          <span class="log-filters">
            <button class="chip filter-chip active" data-f="all" onclick="setFilter(this,'all')">All</button>
            <button class="chip filter-chip" data-f="error" onclick="setFilter(this,'error')">Errors</button>
            <button class="chip filter-chip" data-f="warning" onclick="setFilter(this,'warning')">Warnings</button>
          </span>
        </div>
        <div class="log-body">{''.join(body)}</div>
      </div>""")
    return f'<div class="layer-chips">{"".join(chips)}</div>{"".join(panes)}'


def render_findings_tab(data):
    out = []
    if data["bugs"]:
        rows = []
        for b in data["bugs"]:
            sev = esc(b["severity"] or "minor")
            desc = f'<p class="card-body">{esc(b["description"])}</p>' if b.get("description") else ""
            link = (f'<a href="{esc(b["filed_issue_url"])}">{esc(b["filed_issue_url"])}</a>'
                    if b.get("filed_issue_url") else "")
            rows.append(f"""
        <div class="card">
          <div class="card-head">
            <p class="card-title"><span class="badge badge-{sev}">{sev}</span> {esc(b['title'])}</p>
            <span class="card-duration">test {esc(b['test_id'] or '-')}</span>
          </div>
          {desc}{link}
        </div>""")
        out.append(f"<h3>Bugs ({len(data['bugs'])})</h3>{''.join(rows)}")
    if data["a11y"]:
        items = "".join(
            f"<li><strong>{esc(a['element_purpose'])}</strong> — {esc(a['recommendation'])}</li>"
            for a in data["a11y"])
        out.append(f"<h3>Accessibility ({len(data['a11y'])})</h3><ul class='watch'>{items}</ul>")
    if data["perf"]:
        rows = "".join(
            f"<tr><td>{esc(p['metric_name'])}</td><td>{p['value_ms']}ms</td><td>{p['target_ms']}ms</td>"
            f"<td>{'<span class=cell-ok>pass</span>' if p['passed'] else '<span class=cell-bad>fail</span>'}</td>"
            f"<td>{esc(p['test_id'] or '')}</td></tr>"
            for p in data["perf"])
        out.append(f"""
      <h3>Performance ({len(data['perf'])})</h3>
      <table class="stats-table">
        <thead><tr><th>Metric</th><th>Value</th><th>Target</th><th>Status</th><th>Test</th></tr></thead>
        <tbody>{rows}</tbody>
      </table>""")
    if data["events"]:
        shown = data["events"][:MAX_EVENTS]
        rows = "".join(
            f"<tr><td>{esc((e['timestamp'] or '')[11:19])}</td><td>{esc(e['event_name'])}</td>"
            f"<td>{esc(e['test_id'] or '')}</td><td class='event-data'>{esc(e['event_data'] or '')}</td></tr>"
            for e in shown)
        note = (f"<p class='empty'>Showing first {MAX_EVENTS} of {len(data['events'])} events.</p>"
                if len(data["events"]) > MAX_EVENTS else "")
        out.append(f"""
      <h3>App events ({len(data['events'])})</h3>
      <table class="stats-table">
        <thead><tr><th>Time</th><th>Event</th><th>Test</th><th>Data</th></tr></thead>
        <tbody>{rows}</tbody>
      </table>{note}""")
    if not out:
        return "<p class='empty'>No bugs, accessibility findings, performance measurements, or events recorded.</p>"
    return "".join(out)


CSS = """
    :root {
      --color-primary:    #000000;
      --color-inverted:   #FFFFFF;
      --color-secondary:  #666666;
      --color-tertiary:   #B2B2B2;
      --color-surface:    #FFFFFF;
      --color-muted:      #F5F5F5;
      --color-edge:       #EBEBEB;
      --color-accent:     #FC4F37;
      --color-success:    #16A34A;
      --color-caution:    #E30C00;
      --rounded-sm: 8px; --rounded-md: 12px; --rounded-lg: 16px; --rounded-full: 9999px;
      --space-xs: 4px; --space-sm: 8px; --space-md: 16px; --space-lg: 24px; --space-xl: 32px; --space-xxl: 48px;
      --font-system: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
      --font-mono: ui-monospace, 'SF Mono', Menlo, Consolas, 'Roboto Mono', monospace;
      --column-max: 860px;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --color-primary: #FFFFFF; --color-inverted: #000000; --color-secondary: #999999;
        --color-tertiary: #4D4D4D; --color-surface: #262626; --color-muted: #333333; --color-edge: #333333;
      }
    }
    *, *::before, *::after { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; }
    body {
      background: var(--color-muted); color: var(--color-primary);
      font-family: var(--font-system); font-size: 1rem; line-height: 1.5;
      -webkit-font-smoothing: antialiased; -webkit-text-size-adjust: 100%;
    }
    .page { max-width: var(--column-max); margin: 0 auto; padding: var(--space-xl) var(--space-lg) var(--space-xxl);
      display: flex; flex-direction: column; gap: var(--space-md); }
    .eyebrow-row { display: flex; align-items: center; justify-content: space-between; gap: var(--space-sm); }
    .eyebrow { margin: 0; display: inline-flex; align-items: center; gap: var(--space-sm);
      font-size: 0.75rem; font-weight: 600; line-height: 1; letter-spacing: 0.04em;
      text-transform: uppercase; color: var(--color-secondary); }
    .brand-mark { width: 14px; height: 18px; flex-shrink: 0; color: var(--color-accent); }
    .brand-mark path { fill: currentColor; }
    .byline { margin: 0; font-size: 0.75rem; font-weight: 500; line-height: 1;
      letter-spacing: 0.02em; color: var(--color-tertiary); }
    .hero { display: flex; flex-direction: column; gap: var(--space-sm); }
    .title { margin: var(--space-sm) 0 0; font-size: 2rem; font-weight: 700; line-height: 1.1;
      letter-spacing: -0.025em; display: flex; align-items: center; gap: var(--space-md); flex-wrap: wrap; }
    .dek { margin: 0; font-size: 1.05rem; color: var(--color-secondary); }
    .divider { width: 100%; border: 0; border-top: 1px solid var(--color-edge); margin: var(--space-md) 0; }
    h2 { margin: 0; font-size: 1.4rem; font-weight: 600; letter-spacing: -0.01em; }
    h3 { margin: var(--space-md) 0 var(--space-sm); font-size: 1.05rem; font-weight: 600; }
    .empty { color: var(--color-secondary); font-size: 0.9rem; margin: var(--space-sm) 0; }

    .pill { display: inline-flex; align-items: center; padding: 3px 12px; border-radius: var(--rounded-full);
      font-size: 0.72rem; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; line-height: 1.4; }
    .pill-ok { background: var(--color-success); color: #FFFFFF; }
    .pill-bad { background: var(--color-caution); color: #FFFFFF; }
    .pill-warn { background: var(--color-accent); color: #FFFFFF; }
    .pill-dim { background: var(--color-tertiary); color: var(--color-inverted); }

    .panel { background: var(--color-surface); border: 1px solid var(--color-edge);
      border-radius: var(--rounded-lg); padding: var(--space-lg); }

    /* Carousel */
    .carousel { background: var(--color-surface); border: 1px solid var(--color-edge);
      border-radius: var(--rounded-lg); padding: var(--space-md);
      display: flex; flex-direction: column; gap: var(--space-sm); }
    .carousel-main { display: flex; align-items: center; justify-content: center; gap: var(--space-sm); }
    #car-img { max-height: 560px; max-width: 100%; border-radius: var(--rounded-md);
      border: 1px solid var(--color-edge); cursor: pointer; background: var(--color-muted); }
    .car-nav { flex-shrink: 0; width: 40px; height: 40px; border-radius: var(--rounded-full);
      border: 1px solid var(--color-edge); background: var(--color-surface); color: var(--color-primary);
      font-size: 1.4rem; line-height: 1; cursor: pointer; transition: border-color 0.15s ease; }
    .car-nav:hover { border-color: var(--color-primary); }
    .car-nav:disabled { opacity: 0.3; cursor: default; }
    .car-meta { display: flex; justify-content: space-between; align-items: baseline;
      gap: var(--space-md); font-size: 0.85rem; color: var(--color-secondary); padding: 0 var(--space-sm); }
    .car-counter { color: var(--color-tertiary); font-variant-numeric: tabular-nums; flex-shrink: 0; }
    .car-strip { display: flex; gap: var(--space-xs); overflow-x: auto; padding: var(--space-xs) 2px; }
    .thumb { flex-shrink: 0; padding: 0; border: 2px solid transparent; border-radius: var(--rounded-sm);
      background: none; cursor: pointer; }
    .thumb img { display: block; height: 72px; width: auto; border-radius: 6px; }
    .thumb.active { border-color: var(--color-accent); }

    /* Summary stat table: one hairline-bordered container, cells divided by
       1px edge lines (grid gap over an edge-colored background). */
    .tiles { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1px;
      background: var(--color-edge); border: 1px solid var(--color-edge);
      border-radius: var(--rounded-md); overflow: hidden; margin-top: var(--space-md); }
    @media (max-width: 620px) { .tiles { grid-template-columns: repeat(2, 1fr); } }
    .tile { background: var(--color-surface); padding: var(--space-md) var(--space-md) 14px;
      display: flex; flex-direction: column; gap: 2px; }
    .tile-value { margin: 0; font-size: 1.55rem; font-weight: 700; letter-spacing: -0.02em;
      line-height: 1.15; font-variant-numeric: tabular-nums; }
    .tile-ok { color: var(--color-success); }
    .tile-bad { color: var(--color-caution); }
    .tile-warn { color: var(--color-accent); }
    .tile-label { margin: 0; font-size: 0.7rem; font-weight: 500; letter-spacing: 0.05em;
      text-transform: uppercase; color: var(--color-secondary); white-space: nowrap;
      overflow: hidden; text-overflow: ellipsis; }
    .callout { border-left: 2px solid var(--color-accent); padding: var(--space-sm) var(--space-md);
      margin-top: var(--space-md); color: var(--color-secondary); }
    .callout p { margin: 0 0 var(--space-sm); }
    .callout p:last-child { margin-bottom: 0; }
    .callout-label { font-size: 0.72rem; font-weight: 600; letter-spacing: 0.04em;
      text-transform: uppercase; color: var(--color-primary); }
    .watch { margin: 0; padding-left: var(--space-lg); }
    .watch li + li { margin-top: var(--space-xs); }
    .watch code { font-family: var(--font-mono); font-size: 0.8rem; background: var(--color-muted);
      padding: 1px 5px; border-radius: var(--rounded-sm); }
    .stats-table { width: 100%; border-collapse: collapse; font-size: 0.875rem; }
    .stats-table th, .stats-table td { text-align: left; padding: var(--space-sm) var(--space-md);
      border-bottom: 1px solid var(--color-edge); }
    .stats-table th { font-weight: 600; color: var(--color-secondary); }
    .cell-bad { color: var(--color-caution); font-weight: 600; }
    .cell-warn { color: var(--color-accent); font-weight: 600; }
    .cell-ok { color: var(--color-success); font-weight: 600; }
    .event-data { font-family: var(--font-mono); font-size: 0.75rem; color: var(--color-secondary);
      word-break: break-all; }

    /* Tabs */
    .tabs { display: flex; gap: var(--space-sm); border-bottom: 1px solid var(--color-edge);
      margin-top: var(--space-md); }
    .tab { padding: var(--space-sm) var(--space-md); border: 0; background: none; cursor: pointer;
      font-family: inherit; font-size: 0.95rem; font-weight: 500; color: var(--color-secondary);
      border-bottom: 2px solid transparent; margin-bottom: -1px; }
    .tab.active { color: var(--color-primary); font-weight: 600; border-bottom-color: var(--color-accent); }
    .tab-panel { display: none; }
    .tab-panel.active { display: block; }

    /* Test cards */
    .card { background: var(--color-surface); border: 1px solid var(--color-edge);
      border-radius: var(--rounded-lg); padding: var(--space-md) var(--space-lg); margin-top: var(--space-sm); }
    .card-head { display: flex; align-items: center; justify-content: space-between;
      gap: var(--space-md); flex-wrap: wrap; }
    .card-head-right { display: flex; align-items: center; gap: var(--space-sm); }
    .card-title { margin: 0; font-size: 1.02rem; font-weight: 600; display: flex;
      align-items: center; gap: var(--space-sm); flex-wrap: wrap; }
    .card-duration { font-size: 0.8rem; color: var(--color-tertiary); font-variant-numeric: tabular-nums; }
    .card-body { margin: var(--space-xs) 0 0; font-size: 0.92rem; }
    .test-error { margin: var(--space-sm) 0 0; font-size: 0.85rem; color: var(--color-caution); }
    .test-notes { margin: var(--space-sm) 0 0; font-size: 0.85rem; color: var(--color-secondary); }
    .criteria { list-style: none; margin: var(--space-sm) 0 0; padding: 0; }
    .criteria li { display: flex; gap: var(--space-sm); padding: var(--space-xs) 0;
      font-size: 0.875rem; align-items: baseline; }
    .crit-mark { flex-shrink: 0; width: 16px; text-align: center; font-weight: 700; }
    .crit-pass .crit-mark { color: var(--color-success); }
    .crit-fail .crit-mark { color: var(--color-caution); }
    .crit-fail { color: var(--color-caution); }
    .crit-skip .crit-mark { color: var(--color-tertiary); }
    .crit-evidence { color: var(--color-secondary); }
    .badge { display: inline-flex; padding: 2px 10px; border-radius: var(--rounded-full);
      font-size: 0.68rem; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase;
      background: var(--color-primary); color: var(--color-inverted); }
    .badge-critical { background: var(--color-caution); color: #FFFFFF; }
    .badge-major { background: var(--color-accent); color: #FFFFFF; }

    /* Chips */
    .chip { display: inline-flex; align-items: center; gap: 6px; padding: 5px 12px;
      border: 1px solid var(--color-edge); border-radius: var(--rounded-full);
      background: var(--color-surface); color: var(--color-primary); font-family: inherit;
      font-size: 0.82rem; font-weight: 500; line-height: 1.2; cursor: pointer;
      transition: border-color 0.15s ease; }
    .chip:hover { border-color: var(--color-primary); }
    .chip.active { background: var(--color-primary); color: var(--color-inverted);
      border-color: var(--color-primary); }
    .chip-badge { background: var(--color-caution); color: #FFFFFF; border-radius: var(--rounded-full);
      font-size: 0.68rem; font-weight: 700; padding: 1px 7px; }
    .chip.active .chip-badge { background: var(--color-caution); }
    .layer-chips { display: flex; flex-wrap: wrap; gap: var(--space-sm); margin-top: var(--space-md); }

    /* Log viewer */
    .log-pane { display: none; margin-top: var(--space-md); }
    .log-pane.active { display: block; }
    .log-toolbar { display: flex; justify-content: space-between; align-items: center;
      gap: var(--space-md); flex-wrap: wrap; margin-bottom: var(--space-sm); }
    .log-stats { font-size: 0.82rem; color: var(--color-secondary); }
    .log-filters { display: flex; gap: var(--space-xs); }
    .log-body { background: var(--color-surface); border: 1px solid var(--color-edge);
      border-radius: var(--rounded-md); padding: var(--space-md); max-height: 540px;
      overflow: auto; font-family: var(--font-mono); font-size: 0.72rem; line-height: 1.45; }
    .ll { white-space: pre-wrap; word-break: break-all; }
    .lvl-error { color: var(--color-caution); }
    .lvl-warning { color: var(--color-accent); }
    .lvl-meta { color: var(--color-tertiary); font-style: italic; padding: var(--space-xs) 0; }
    .log-pane[data-filter="error"] .ll:not(.lvl-error):not(.lvl-meta) { display: none; }
    .log-pane[data-filter="warning"] .ll:not(.lvl-warning):not(.lvl-meta) { display: none; }

    .footer { margin-top: var(--space-lg); font-size: 0.78rem; color: var(--color-tertiary); }
"""

JS = """
    let carIndex = 0;
    function carRender() {
      if (typeof SHOTS === 'undefined' || !SHOTS.length) return;
      const s = SHOTS[carIndex];
      document.getElementById('car-img').src = s.src;
      let cap = '';
      if (s.test) cap += 'Test ' + s.test;
      if (s.step) cap += (cap ? ' · ' : '') + s.step;
      if (s.caption) cap += (cap ? ' — ' : '') + s.caption;
      if (s.at) cap += (cap ? ' · ' : '') + s.at;
      document.getElementById('car-caption').textContent = cap;
      document.getElementById('car-counter').textContent = (carIndex + 1) + ' / ' + SHOTS.length;
      document.getElementById('car-prev').disabled = carIndex === 0;
      document.getElementById('car-next').disabled = carIndex === SHOTS.length - 1;
      document.querySelectorAll('.thumb').forEach((t, i) => t.classList.toggle('active', i === carIndex));
      const active = document.querySelector('.thumb.active');
      if (active) active.scrollIntoView({ block: 'nearest', inline: 'nearest' });
      [carIndex - 1, carIndex + 1].forEach(i => {
        if (i >= 0 && i < SHOTS.length) { const img = new Image(); img.src = SHOTS[i].src; }
      });
    }
    function carGo(i) { carIndex = Math.max(0, Math.min(i, SHOTS.length - 1)); carRender(); }
    function carStep(d) { carGo(carIndex + d); }
    document.addEventListener('keydown', e => {
      if (typeof SHOTS === 'undefined' || !SHOTS.length) return;
      if (e.key === 'ArrowLeft') { carStep(-1); e.preventDefault(); }
      if (e.key === 'ArrowRight') { carStep(1); e.preventDefault(); }
    });

    function showTab(name) {
      document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === name));
      document.querySelectorAll('.tab-panel').forEach(p => p.classList.toggle('active', p.dataset.tab === name));
    }
    function showLayer(layer) {
      document.querySelectorAll('.layer-chip').forEach(c => c.classList.toggle('active', c.dataset.layer === layer));
      document.querySelectorAll('.log-pane').forEach(p => p.classList.toggle('active', p.dataset.layer === layer));
    }
    function setFilter(btn, f) {
      const pane = btn.closest('.log-pane');
      pane.dataset.filter = f;
      pane.querySelectorAll('.filter-chip').forEach(c => c.classList.toggle('active', c.dataset.f === f));
    }
    if (typeof SHOTS !== 'undefined' && SHOTS.length) carRender();
"""


def render_page(data, layers, shots):
    run = data["run"]
    title = f"{run_scope_title(data)} — QA Run {run['id']}"
    desc = f"Convos iOS QA run {run['id']} — {run['status']}"
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{esc(title)}</title>
  <meta name="description" content="{esc(desc)}">
  <meta property="og:type" content="article">
  <meta property="og:site_name" content="Convos">
  <meta property="og:title" content="{esc(title)}">
  <meta property="og:description" content="{esc(desc)}">
  <style>{CSS}</style>
</head>
<body>
  <div class="page">
{render_hero(data)}
{render_carousel(shots)}
{render_summary(data, layers)}
  <nav class="tabs">
    <button class="tab active" data-tab="tests" onclick="showTab('tests')">Tests</button>
    <button class="tab" data-tab="logs" onclick="showTab('logs')">Logs</button>
    <button class="tab" data-tab="findings" onclick="showTab('findings')">Findings</button>
  </nav>
  <div class="tab-panel active" data-tab="tests">{render_tests_tab(data, shots)}</div>
  <div class="tab-panel" data-tab="logs">{render_logs_tab(layers)}</div>
  <div class="tab-panel" data-tab="findings">{render_findings_tab(data)}</div>
  <p class="footer">Generated by qa/scripts/generate-artifact.py · run {esc(run['id'])} ·
    simulator {esc(run.get('simulator_udid') or '-')}</p>
  </div>
  <script>{JS}</script>
</body>
</html>
"""


def print_analysis(layers):
    if not layers:
        print("no captured log files (qa/artifacts/run-<id>/logs/ is empty)")
        return
    for l in layers:
        print(f"== {l['label']} ({l['layer']}.log): {l['total']:,} lines, "
              f"{l['errors']} errors, {l['warnings']} warnings")
        for lineno, sample in l["samples"]:
            print(f"   L{lineno}: {sample[:200]}")


def main():
    parser = argparse.ArgumentParser(description="Generate the HTML artifact for a QA run.")
    parser.add_argument("run_id", nargs="?", help="CXDB run id (12-char hex)")
    parser.add_argument("--latest", action="store_true", help="use the most recent run")
    parser.add_argument("--analyze", action="store_true", help="print log analysis only, no HTML")
    parser.add_argument("--db", default=str(DB_PATH), help="path to qa.sqlite")
    args = parser.parse_args()

    db = Path(args.db)
    if not db.is_file():
        sys.exit(f"error: no CXDB at {db}")
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)

    run_id = args.run_id
    if args.latest or not run_id:
        row = conn.execute("SELECT id FROM test_runs ORDER BY started_at DESC LIMIT 1").fetchone()
        if row is None:
            sys.exit("error: CXDB has no runs")
        run_id = row[0]

    artifact_dir = REPO_ROOT / "qa" / "artifacts" / f"run-{run_id}"
    layers = analyze_logs(artifact_dir / "logs")

    if args.analyze:
        print_analysis(layers)
        return

    data = load_run_data(conn, run_id)
    shots = order_screenshots(data, artifact_dir)
    artifact_dir.mkdir(parents=True, exist_ok=True)
    out = artifact_dir / "index.html"
    out.write_text(render_page(data, layers, shots))
    print(f"artifact: {out}")
    print(f"  screenshots: {len(shots)}  log layers: {len(layers)}  "
          f"tests: {len(data['tests'])}  bugs: {len(data['bugs'])}")


if __name__ == "__main__":
    main()

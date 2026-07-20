#!/usr/bin/env python3
"""Generated ViewModel -> dependency map for convos-ios.

Question this answers: what does each ViewModel depend on, and which ones
carry too many collaborators?
Action it drives: read before touching a surface; split ViewModels whose
collaborator count is an outlier.
Scope: the iOS counterpart of android/docs/architecture.md section 15 —
one chart, nothing more. Narrative architecture knowledge lives in the
hand-curated ADRs and identity-system-overview.

Outputs are deterministic (no timestamps) so CI can regenerate and fail on
drift:

    python3 Scripts/generate_vm_map_ios.py --root . \
        --out docs/vm-map.md --json docs/vm-map.json --html docs/vm-map.html

What counts as a dependency (iOS resolves collaborators via session
factories, so three sources are merged): stored properties
(`let x: any FooProtocol`), `init` parameters, and factory call-sites
(`session.messagesRepository(for:)`) including in `ViewModel+Extension`
files. Names are normalized (FooWriterProtocol/FooWriting/AnyFoo ->
FooWriter/Foo) so a protocol and its concrete type render as one node.
Extend CATEGORIES if a new dependency kind appears (mirror any change in
convos-client android/scripts/generate_vm_map.py).
"""

import argparse
import json
import re
from pathlib import Path

# ---------------------------------------------------------------- categories
# Fixed slot order = the CVD-validated palette order. Do not re-order.
CATEGORIES = [
    {"key": "repo",   "label": "Repositories",     "light": "#2a78d6", "dark": "#3987e5", "rx": r"Repository$"},
    {"key": "svc",    "label": "Services",          "light": "#008300", "dark": "#008300", "rx": r"Service$"},
    {"key": "mgr",    "label": "Managers",          "light": "#e87ba4", "dark": "#d55181", "rx": r"Manager$"},
    {"key": "store",  "label": "Stores & caches",   "light": "#eda100", "dark": "#c98500", "rx": r"(Store|Storage|Cache)$"},
    {"key": "nav",    "label": "Coordinators",      "light": "#1baf7a", "dark": "#199e70", "rx": r"(Coordinator|Router|Navigator)$"},
    {"key": "writer", "label": "Writers",           "light": "#eb6834", "dark": "#d95926", "rx": r"Writer$"},
    {"key": "other",  "label": "Child VMs & other", "light": "#4a3aa7", "dark": "#9085e9", "rx": None},
]

SKIP_TYPES = {
    "String", "Bool", "Int", "Double", "Float", "Data", "Date", "UUID", "URL",
    "UIImage", "Conversation", "ConversationMember", "Profile", "AnyMessage",
    "CoreActions",  # no-op action hooks, present on nearly every VM
    "AnyCancellable", "Task", "Timer", "NSObject",
}
SKIP_SUFFIXES = ("Id", "ID", "Mode", "Source", "State", "Style", "Kind", "Key")

CLASS_RE = re.compile(r"^(?:@\w+(?:\(.*?\))?\s+)*(?:final\s+|public\s+|open\s+)*class\s+(\w+ViewModel)\b", re.M)
PROP_RE = re.compile(
    r"^\s+(?:@\w+(?:\(.*?\))?\s+)*(?:private|fileprivate|internal|public)?\s*"
    r"(?:private\(set\)\s+)?(?:let|var)\s+\w+:\s*\(?\s*(?:any\s+)?(\w+)"
)
INIT_RE = re.compile(r"^\s+(?:public\s+|internal\s+|convenience\s+|required\s+)*init\s*\(", re.M)
PARAM_RE = re.compile(r"\w+\s*:\s*\(?\s*(?:any\s+)?(\w+)")
FACTORY_RE = re.compile(r"\b(?:session|messagingService)\.(\w+)\(")


def categorize(name):
    for cat in CATEGORIES:
        if cat["rx"] and re.search(cat["rx"], name):
            return cat["key"]
    if name.endswith("ViewModel"):
        return "other"
    return "other"


def wanted(name):
    if name in SKIP_TYPES or name.endswith(SKIP_SUFFIXES):
        return False
    if any(c["rx"] and re.search(c["rx"], name) for c in CATEGORIES):
        return True
    return bool(re.search(
        r"(Protocol|Providing|Provider|Resolver|Resolving|Checker|Launcher|Processor|Delegate|ViewModel)$",
        name,
    ))


# ---------------------------------------------------------------- extraction
def class_body(text, decl_end):
    i = text.index("{", decl_end)
    depth = 0
    for j in range(i, len(text)):
        c = text[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[i + 1 : j]
    return text[i + 1 :]


def top_level_lines(body):
    depth = 0
    for line in body.split("\n"):
        stripped = line.strip()
        if depth == 0:
            yield stripped
        depth += line.count("{") - line.count("}")
        if depth < 0:
            depth = 0


def paren_block(text, start):
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1 : i]
    return ""


def split_params(block):
    depth, buf, out = 0, [], []
    for c in block:
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == "," and depth == 0:
            out.append("".join(buf))
            buf = []
        else:
            buf.append(c)
    if buf:
        out.append("".join(buf))
    return out


def canon(d):
    d = re.sub(r"Protocol$", "", d)
    d = re.sub(r"Servicing$", "Service", d)
    d = re.sub(r"Writing$", "Writer", d)
    if d.startswith("Any") and len(d) > 3 and d[3].isupper():
        d = d[3:]
    return d


def scan_viewmodels(app_dir):
    graph = {}
    for f in sorted(app_dir.rglob("*ViewModel*.swift")):
        if "+" in f.name or "Tests" in f.name:
            continue
        text = f.read_text(encoding="utf-8")
        for m in CLASS_RE.finditer(text):
            vm = m.group(1)
            body = class_body(text, m.end())
            deps = set()
            for stripped in top_level_lines(body):
                pm = PROP_RE.match("    " + stripped)
                if pm and wanted(pm.group(1)):
                    deps.add(pm.group(1))
            for im in INIT_RE.finditer(body):
                block = paren_block(body, body.index("(", im.start()))
                for param in split_params(block):
                    tm = PARAM_RE.search(param.split("=", 1)[0])
                    if tm and wanted(tm.group(1)):
                        deps.add(tm.group(1))
            for fm in FACTORY_RE.finditer(body):
                name = fm.group(1)[0].upper() + fm.group(1)[1:]
                if categorize(name) != "other" or name.endswith("ViewModel"):
                    if any(c["rx"] and re.search(c["rx"], name) for c in CATEGORIES):
                        deps.add(name)
            graph[vm] = sorted(deps)
    # extension files can add factory-resolved collaborators
    for f in sorted(app_dir.rglob("*ViewModel+*.swift")):
        m = re.match(r"(\w+ViewModel)\+", f.name)
        if not m or m.group(1) not in graph:
            continue
        text = f.read_text(encoding="utf-8")
        extra = set(graph[m.group(1)])
        for fm in FACTORY_RE.finditer(text):
            name = fm.group(1)[0].upper() + fm.group(1)[1:]
            if any(c["rx"] and re.search(c["rx"], name) for c in CATEGORIES):
                extra.add(name)
        graph[m.group(1)] = sorted(extra)
    for vm, deps in graph.items():
        graph[vm] = sorted({canon(d) for d in deps})
    return dict(sorted(graph.items()))



def mermaid_id(name):
    return re.sub(r"\W", "_", name)


def build_markdown(graph):
    L = []
    a = L.append
    a("# Convos iOS — ViewModel → Dependency Map")
    a("")
    a("> Generated by `Scripts/generate_vm_map_ios.py` — do not edit by hand; CI")
    a("> regenerates and fails on drift. Interactive version: `docs/vm-map.html`.")
    a("> Scope: iOS counterpart of android architecture.md §15 — one chart, no more.")
    a("")
    a("**Question this answers:** what does each ViewModel depend on, and which")
    a("ones carry too many collaborators? **Action it drives:** read before")
    a("touching a surface; split outliers.")
    a("")
    edges = sum(len(v) for v in graph.values())
    max_deps = max((len(v) for v in graph.values()), default=0)
    a(f"ViewModels: **{len(graph)}** · dependency edges: **{edges}** · max collaborators: **{max_deps}**")
    a("")
    a("```mermaid")
    a("graph LR")
    by_cat = {}
    for deps in graph.values():
        for d in deps:
            by_cat.setdefault(categorize(d), set()).add(d)
    for cat in CATEGORIES:
        deps = sorted(by_cat.get(cat["key"], []))
        if not deps:
            continue
        a(f'  subgraph {mermaid_id(cat["label"])}["{cat["label"]}"]')
        for d in deps:
            a(f'    {mermaid_id(d)}["{d}"]')
        a("  end")
    a('  subgraph VMs["ViewModels"]')
    for vm in graph:
        a(f'    {mermaid_id(vm)}["{vm}"]')
    a("  end")
    for vm, deps in graph.items():
        for d in deps:
            a(f"  {mermaid_id(vm)} --> {mermaid_id(d)}")
    a("```")
    a("")
    a("## Inventory")
    a("")
    a("| ViewModel | Deps | Depends on |")
    a("|---|---|---|")
    for vm in sorted(graph, key=lambda v: (-len(graph[v]), v)):
        deps = graph[vm]
        a(f"| {vm} | {len(deps)} | {', '.join(deps) if deps else '—'} |")
    a("")
    return "\n".join(L)

HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
  .viz-root { color-scheme: light;
    --surface-1:#fcfcfb; --page:#f9f9f7; --ink-1:#0b0b0b; --ink-2:#52514e;
    --ink-muted:#898781; --hairline:#e1e0d9; --ring:rgba(11,11,11,0.10); }
  @media (prefers-color-scheme: dark) {
    :root:where(:not([data-theme="light"])) .viz-root { color-scheme: dark;
      --surface-1:#1a1a19; --page:#0d0d0d; --ink-1:#ffffff; --ink-2:#c3c2b7;
      --ink-muted:#898781; --hairline:#2c2c2a; --ring:rgba(255,255,255,0.10); } }
  :root[data-theme="dark"] .viz-root { color-scheme: dark;
    --surface-1:#1a1a19; --page:#0d0d0d; --ink-1:#ffffff; --ink-2:#c3c2b7;
    --ink-muted:#898781; --hairline:#2c2c2a; --ring:rgba(255,255,255,0.10); }
  * { box-sizing: border-box; }
  body { margin:0; font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
  .viz-root { background:var(--page); color:var(--ink-1); min-height:100vh; padding:24px; }
  header, .tiles, .controls, .board, .tablewrap, footer { max-width:1200px; margin:0 auto; }
  h1 { font-size:20px; margin:0 0 4px; }
  .sub { color:var(--ink-2); font-size:13px; margin:0; }
  .scope { color:var(--ink-muted); font-size:12px; margin:4px 0 0; }
  .tiles { display:flex; gap:12px; flex-wrap:wrap; margin:16px auto; }
  .tile { background:var(--surface-1); border:1px solid var(--ring); border-radius:10px; padding:10px 16px; min-width:110px; }
  .tile .v { font-size:24px; font-weight:650; }
  .tile .k { font-size:12px; color:var(--ink-2); }
  .controls { margin-bottom:12px; display:flex; gap:10px; align-items:center; flex-wrap:wrap; }
  .controls input[type=search] { padding:7px 12px; border:1px solid var(--hairline); border-radius:8px; background:var(--surface-1); color:var(--ink-1); font-size:13px; width:240px; }
  .btn { padding:7px 12px; border:1px solid var(--hairline); border-radius:8px; background:var(--surface-1); color:var(--ink-1); font-size:13px; cursor:pointer; }
  .btn[aria-pressed="true"] { border-color:var(--ink-2); font-weight:600; }
  .legend { display:flex; gap:14px; flex-wrap:wrap; font-size:12px; color:var(--ink-2); margin-left:auto; }
  .legend span { display:inline-flex; align-items:center; gap:5px; }
  .dot { width:10px; height:10px; border-radius:3px; display:inline-block; }
  .board { background:var(--surface-1); border:1px solid var(--ring); border-radius:12px; padding:16px; position:relative; }
  .cols { display:flex; position:relative; }
  .col { width:330px; z-index:2; }
  .col h2 { font-size:12px; text-transform:uppercase; letter-spacing:.06em; color:var(--ink-muted); margin:6px 0; }
  .gap { flex:1; min-width:120px; }
  svg.wires { position:absolute; inset:0; width:100%; height:100%; z-index:1; pointer-events:none; }
  .node { display:flex; align-items:center; gap:7px; font-size:12.5px; padding:3px 8px; border-radius:6px; cursor:pointer; border:1px solid transparent; color:var(--ink-1); }
  .node:hover { border-color:var(--hairline); }
  .node.sel { border-color:var(--ink-2); font-weight:600; }
  .node.dim { opacity:.25; }
  .node .cnt { margin-left:auto; color:var(--ink-muted); font-size:11px; font-variant-numeric:tabular-nums; }
  .cat-label { font-size:11px; color:var(--ink-2); margin:8px 0 2px; display:flex; align-items:center; gap:5px; font-weight:600; }
  path.wire { fill:none; stroke-width:1.3; opacity:.28; }
  path.wire.hot { opacity:.95; stroke-width:2; }
  path.wire.cold { opacity:.04; }
  .tablewrap { margin-top:16px; background:var(--surface-1); border:1px solid var(--ring); border-radius:12px; padding:16px; overflow-x:auto; }
  table { border-collapse:collapse; font-size:12.5px; width:100%; }
  th, td { text-align:left; padding:5px 10px; border-bottom:1px solid var(--hairline); vertical-align:top; }
  th { color:var(--ink-muted); font-size:11px; text-transform:uppercase; letter-spacing:.05em; }
  .hidden { display:none; }
  footer { color:var(--ink-muted); font-size:12px; margin-top:14px; }
</style>
</head>
<body>
<div class="viz-root">
  <header>
    <h1>__TITLE__</h1>
    <p class="sub">__SUBTITLE__</p>
    <p class="scope"><b>Question this answers:</b> what does each ViewModel depend on, and which ones carry too much? <b>Action it drives:</b> read before touching a surface; split VMs whose collaborator count is an outlier. __SCOPE_NOTE__</p>
  </header>
  <div class="tiles" id="tiles"></div>
  <div class="controls">
    <input type="search" id="q" placeholder="Filter ViewModels…" aria-label="Filter ViewModels">
    <button class="btn" id="tableBtn" aria-pressed="false">Table view</button>
    <button class="btn" id="themeBtn">Dark / light</button>
    <div class="legend" id="legend"></div>
  </div>
  <div class="board" id="board">
    <div class="cols">
      <div class="col" id="vmCol"><h2>ViewModels (by dependency count)</h2></div>
      <div class="gap"></div>
      <div class="col" id="depCol"><h2>Dependencies (by kind)</h2></div>
      <svg class="wires" id="wires"></svg>
    </div>
  </div>
  <div class="tablewrap hidden" id="tablewrap">
    <table><thead><tr><th>ViewModel</th><th>Depends on</th></tr></thead><tbody id="tbody"></tbody></table>
  </div>
  <footer>Generated by __SCRIPT__ — do not edit by hand; CI regenerates and fails on drift. Regenerate after adding or rewiring a ViewModel.</footer>
</div>
<script>
const CATS = __CATS__;
const DATA = __DATA__;

const root = document.querySelector(".viz-root");
function applyCatColors() {
  const dark = document.documentElement.getAttribute("data-theme") === "dark" ||
    (!document.documentElement.getAttribute("data-theme") && matchMedia("(prefers-color-scheme: dark)").matches);
  CATS.forEach(c => root.style.setProperty("--cat-" + c.key, dark ? c.dark : c.light));
}
applyCatColors();

const vms = Object.keys(DATA.viewModels).sort((a, b) =>
  DATA.viewModels[b].length - DATA.viewModels[a].length || a.localeCompare(b));
const deps = [...new Set(vms.flatMap(v => DATA.viewModels[v]))];
const depByCat = {};
deps.forEach(d => { const c = DATA.depCat[d] || "other"; (depByCat[c] = depByCat[c] || []).push(d); });
Object.values(depByCat).forEach(a => a.sort());
const edges = vms.flatMap(v => DATA.viewModels[v].map(d => [v, d]));

const maxDeps = Math.max(...vms.map(v => DATA.viewModels[v].length), 0);
const tiles = [["ViewModels", vms.length], ["Dependency edges", edges.length], ["Max collaborators", maxDeps]];
document.getElementById("tiles").innerHTML = tiles.map(([k, v]) =>
  `<div class="tile"><div class="v">${v}</div><div class="k">${k}</div></div>`).join("");
document.getElementById("legend").innerHTML = CATS.filter(c => depByCat[c.key]).map(c =>
  `<span><span class="dot" style="background:var(--cat-${c.key})"></span>${c.label}</span>`).join("");

const vmCol = document.getElementById("vmCol"), depCol = document.getElementById("depCol");
vms.forEach(v => {
  const el = document.createElement("div");
  el.className = "node"; el.dataset.id = v; el.dataset.side = "vm";
  el.innerHTML = `<span>${v.replace(/ViewModel$/, "")}<span style="color:var(--ink-muted)">VM</span></span><span class="cnt">${DATA.viewModels[v].length}</span>`;
  vmCol.appendChild(el);
});
CATS.forEach(c => {
  if (!depByCat[c.key]) return;
  const h = document.createElement("div");
  h.className = "cat-label";
  h.innerHTML = `<span class="dot" style="background:var(--cat-${c.key})"></span>${c.label}`;
  depCol.appendChild(h);
  depByCat[c.key].forEach(d => {
    const el = document.createElement("div");
    el.className = "node"; el.dataset.id = d; el.dataset.side = "dep";
    const users = edges.filter(e => e[1] === d).length;
    el.innerHTML = `<span class="dot" style="background:var(--cat-${c.key})"></span><span>${d}</span><span class="cnt">${users}</span>`;
    depCol.appendChild(el);
  });
});

const board = document.getElementById("board"), svg = document.getElementById("wires");
function colorOf(dep) {
  return getComputedStyle(root).getPropertyValue("--cat-" + (DATA.depCat[dep] || "other")).trim();
}
function draw() {
  const cRect = board.querySelector(".cols").getBoundingClientRect();
  svg.innerHTML = "";
  edges.forEach(([v, d]) => {
    const a = vmCol.querySelector(`[data-id="${v}"]`), b = depCol.querySelector(`[data-id="${CSS.escape(d)}"]`);
    if (!a || !b || a.classList.contains("hidden")) return;
    const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
    const x1 = ra.right - cRect.left, y1 = ra.top + ra.height / 2 - cRect.top;
    const x2 = rb.left - cRect.left, y2 = rb.top + rb.height / 2 - cRect.top;
    const mx = (x1 + x2) / 2;
    const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
    p.setAttribute("d", `M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`);
    p.setAttribute("class", "wire");
    p.setAttribute("stroke", colorOf(d));
    p.dataset.v = v; p.dataset.d = d;
    svg.appendChild(p);
  });
  svg.setAttribute("viewBox", `0 0 ${cRect.width} ${cRect.height}`);
}

let pinned = null;
function highlight(id) {
  const nodes = [...document.querySelectorAll(".node")];
  const wires = [...svg.querySelectorAll("path")];
  if (!id) {
    nodes.forEach(n => n.classList.remove("dim", "sel"));
    wires.forEach(w => w.classList.remove("hot", "cold"));
    return;
  }
  const linked = new Set([id]);
  edges.forEach(([v, d]) => { if (v === id) linked.add(d); if (d === id) linked.add(v); });
  nodes.forEach(n => {
    n.classList.toggle("dim", !linked.has(n.dataset.id));
    n.classList.toggle("sel", n.dataset.id === id);
  });
  wires.forEach(w => {
    const hot = w.dataset.v === id || w.dataset.d === id;
    w.classList.toggle("hot", hot); w.classList.toggle("cold", !hot);
  });
}
document.addEventListener("click", e => {
  const n = e.target.closest(".node");
  if (!n) { pinned = null; highlight(null); return; }
  pinned = pinned === n.dataset.id ? null : n.dataset.id;
  highlight(pinned);
});
document.addEventListener("mouseover", e => {
  if (pinned) return;
  const n = e.target.closest(".node");
  highlight(n ? n.dataset.id : null);
});
document.getElementById("q").addEventListener("input", e => {
  const q = e.target.value.toLowerCase();
  vmCol.querySelectorAll(".node").forEach(n => {
    n.classList.toggle("hidden", q && !n.dataset.id.toLowerCase().includes(q));
  });
  draw(); if (pinned) highlight(pinned);
});
const tbody = document.getElementById("tbody");
vms.forEach(v => {
  const tr = document.createElement("tr");
  tr.innerHTML = `<td>${v}</td><td>${DATA.viewModels[v].join(", ") || "—"}</td>`;
  tbody.appendChild(tr);
});
document.getElementById("tableBtn").addEventListener("click", e => {
  const w = document.getElementById("tablewrap");
  const on = w.classList.toggle("hidden") === false;
  document.getElementById("board").classList.toggle("hidden", on);
  e.currentTarget.setAttribute("aria-pressed", on);
  e.currentTarget.textContent = on ? "Graph view" : "Table view";
  if (!on) { draw(); if (pinned) highlight(pinned); }
});
document.getElementById("themeBtn").addEventListener("click", () => {
  const r = document.documentElement;
  const cur = r.getAttribute("data-theme");
  const dark = matchMedia("(prefers-color-scheme: dark)").matches;
  r.setAttribute("data-theme", (cur ? cur === "dark" : dark) ? "light" : "dark");
  applyCatColors(); draw(); if (pinned) highlight(pinned);
});

addEventListener("resize", () => { draw(); if (pinned) highlight(pinned); });
draw();
</script>
</body>
</html>
"""

def build_html(graph, title, subtitle, scope_note, script_name):
    dep_cat = {}
    for deps in graph.values():
        for d in deps:
            dep_cat[d] = categorize(d)
    payload = {"viewModels": graph, "depCat": dep_cat}
    cats = [{k: c[k] for k in ("key", "label", "light", "dark")} for c in CATEGORIES]
    return (
        HTML_TEMPLATE
        .replace("__TITLE__", title)
        .replace("__SUBTITLE__", subtitle)
        .replace("__SCOPE_NOTE__", scope_note)
        .replace("__SCRIPT__", script_name)
        .replace("__CATS__", json.dumps(cats))
        .replace("__DATA__", json.dumps(payload))
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".", help="convos-ios repo root")
    ap.add_argument("--out", default=None, help="markdown output path")
    ap.add_argument("--json", default=None, help="JSON output path")
    ap.add_argument("--html", default=None, help="HTML output path")
    args = ap.parse_args()

    graph = scan_viewmodels(Path(args.root) / "Convos")

    if args.out:
        Path(args.out).write_text(build_markdown(graph), encoding="utf-8")
        print(f"wrote {args.out}")
    if args.json:
        Path(args.json).write_text(
            json.dumps({"platform": "ios", "viewModels": graph}, indent=2) + "\n",
            encoding="utf-8")
        print(f"wrote {args.json}")
    if args.html:
        Path(args.html).write_text(build_html(
            graph,
            "Convos iOS — ViewModel → Dependency Map",
            "Generated from stored properties, init params, and <code>session.*()</code> factory calls by <code>Scripts/generate_vm_map_ios.py</code>. Click a node to pin its connections; search to filter; Table view for the flat list.",
            "iOS counterpart of android architecture.md §15 — one chart, nothing more.",
            "Scripts/generate_vm_map_ios.py",
        ), encoding="utf-8")
        print(f"wrote {args.html}")


if __name__ == "__main__":
    main()

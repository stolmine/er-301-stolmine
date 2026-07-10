#!/usr/bin/env python3
# [stol:ui-model-manifest]
#
# extract_ui_model.py: the static UI behavior manifest extractor (Layer 2 of the
# ui-model cluster; planning/ui-model-plan.md §3). Walks the ER-301 Lua UI surface
# and emits a DETERMINISTIC, sorted JSON manifest describing, per Window/Control/
# Mode class, the gesture handlers it defines (against the §1 gesture vocabulary)
# with a best-effort static transition target, plus, per unit, the M1-M6 slot ->
# control mapping from its `views.expanded`/`.collapsed` list.
#
# This is heuristic, line/regex-based Lua parsing (NOT a full parser): it is
# deliberately conservative and marks uncertain extractions (`dynamic` targets,
# unresolved class names) rather than guessing. Regenerating on an unchanged tree
# is a byte-identical no-op; the committed testing-assets/emu/ui-model.manifest is
# the BDG baseline the `scripts/dev ui-model` gate diffs against.
#
# Usage:
#   python3 tools/extract_ui_model.py                 # print manifest to stdout
#   python3 tools/extract_ui_model.py -o PATH         # write to PATH
#   python3 tools/extract_ui_model.py --coverage      # print coverage report to stderr
#   python3 tools/extract_ui_model.py --include-packages DIR
#                                                     # also scan an out-of-tree
#                                                     # package lib dir (NOT part
#                                                     # of the committed baseline:
#                                                     # ~/.od is user-specific and
#                                                     # non-deterministic across
#                                                     # machines; for inspection).
#
# The committed baseline scans only the in-repo sources (xroot/, mods/) so the
# manifest is reproducible on any checkout.

import argparse
import json
import os
import re
import sys

SCHEMA_VERSION = 1

# ── §1 gesture vocabulary (Application.lua defaultDispatcher) ─────────────────
# The complete notify(event, ...) alphabet the routing layer dispatches. Handler
# method names on any Window/Control/Mode are drawn from exactly this set.
GESTURE_BASES = [
    "up", "zero", "home", "commit", "enter", "cancel", "dial",
    "main", "sub", "select", "shift",
]
GESTURE_PHASES = ["Pressed", "Released", "Repeated"]


def gesture_vocabulary():
    """The full sorted set of valid gesture-handler method names."""
    names = set()
    for base in GESTURE_BASES:
        for phase in GESTURE_PHASES:
            names.add(base + phase)
    # `encoder` is dispatched without a phase suffix (notify path calls the
    # `encoder(change, shifted)` method directly).
    names.add("encoder")
    return names


VOCAB = gesture_vocabulary()
# A regex alternation of the handler names, longest-first so `main` doesn't shadow.
_VOCAB_ALT = "|".join(sorted(VOCAB, key=len, reverse=True))

# handler def: `function VAR:handlerName(` at column 0 (verified: all 484 gesture
# handler defs in xroot are top-level).
RE_METHOD_DEF = re.compile(
    r"^function\s+([A-Za-z_][A-Za-z0-9_]*):(" + _VOCAB_ALT + r")\s*\(")
# dotted assignment form: `VAR.handlerName = function`
RE_METHOD_ASSIGN = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_]*)\.(" + _VOCAB_ALT + r")\s*=\s*function")
# class-var declaration: `local VAR = Class {` / `Class(` / `Window(` / a base call
RE_CLASS_DECL = re.compile(
    r"^local\s+([A-Z][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_.]*)\s*[\({]")
# mode declaration: `local mode = Mode("Name")`
RE_MODE_DECL = re.compile(
    r"^local\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*Mode\(\s*[\"']([^\"']+)[\"']\s*\)")
# setClassName inside an :init: `self:setClassName("Name")`
RE_SET_CLASSNAME = re.compile(r'setClassName\(\s*["\']([^"\']+)["\']\s*\)')
# `function VAR:init(`, where setClassName typically lives
RE_INIT_DEF = re.compile(r"^function\s+([A-Za-z_][A-Za-z0-9_]*):init\s*\(")
# Signal.register("event", localfn): the Mode gesture-handler idiom
RE_SIGNAL_REGISTER = re.compile(
    r'Signal\.register\(\s*["\'](' + _VOCAB_ALT + r')["\']\s*,\s*([A-Za-z_][A-Za-z0-9_]*)')
# `local function name(`: used to find the body of a Signal-registered handler
RE_LOCAL_FUNC = re.compile(r"^local\s+function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")

# ── transition-call vocabulary (static target resolution) ────────────────────
# Each pattern maps a call found in a handler body to a normalized static target
# string. Order matters only for readability; all matches are collected + sorted.
RE_TARGETS = [
    # doCommand("X") -> command:X
    (re.compile(r'doCommand\(\s*["\']([^"\']+)["\']'), lambda m: "command:" + m.group(1)),
    # notify("Y") -> notify:Y
    (re.compile(r'\bnotify\(\s*["\']([^"\']+)["\']'), lambda m: "notify:" + m.group(1)),
    # activateChooser -> chooser:open
    (re.compile(r'\bactivateChooser\b'), lambda m: "chooser:open"),
    # setViewMode("mode") or setViewMode(x) -> viewMode:<arg>
    (re.compile(r'\bsetViewMode\(\s*["\']?([A-Za-z0-9_.]+)'), lambda m: "viewMode:" + m.group(1)),
    # Context:add(win) -> window:add
    (re.compile(r'\bContext:add\b'), lambda m: "window:add"),
    # obj:replace(...) -> replace
    (re.compile(r'([A-Za-z_][A-Za-z0-9_.]*):replace\('), lambda m: "replace:" + m.group(1)),
    # obj:choose(...) -> choose:<recv>
    (re.compile(r'([A-Za-z_][A-Za-z0-9_.]*):choose\('), lambda m: "choose:" + m.group(1)),
    # var:show()  (window/dialog push) -> show:<recv>
    (re.compile(r'([A-Za-z_][A-Za-z0-9_.]*):show\(\s*\)'), lambda m: "show:" + m.group(1)),
]

# ── view-list extraction ─────────────────────────────────────────────────────
# `expanded = { "a", "b", ... }` / `collapsed = { ... }`; the list may span lines.
RE_VIEW_LIST_START = re.compile(r'\b(expanded|collapsed)\s*=\s*\{')
RE_STRING_ITEM = re.compile(r'["\']([A-Za-z0-9_]+)["\']')

# control-class assignment: `controls.NAME = ClassName {` or `NAME = ClassName {`
# (both idioms appear; the class token is a Capitalized dotted identifier). We
# resolve it per view-list entry name to avoid over-matching.
def _control_class_for(name, text):
    # NAME may be a bare table key (`glitch = NetworkOverviewControl {`) or dotted
    # (`controls.threshold = GainBias {`); the trailing `\s*=` + Capitalized class
    # token + `{` guards against matching a longer identifier or a DSP-object assign.
    pat = re.compile(
        r'(?:^|[^A-Za-z0-9_])' + re.escape(name) + r'\s*=\s*([A-Z][A-Za-z0-9_.]*)\s*\{')
    m = pat.search(text)
    return m.group(1) if m else None


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def function_body(lines, start_idx):
    """Return the body text of a top-level `function`/`local function` beginning at
    lines[start_idx], up to (not including) the matching column-0 `end`. Heuristic:
    all extracted defs are top-level, so the closing `end` is the first line that is
    exactly `end` (optionally with a trailing comment) at column 0 after the def."""
    body = []
    for j in range(start_idx + 1, len(lines)):
        line = lines[j]
        if re.match(r"^end\b", line) or line.rstrip() == "end":
            break
        # a new top-level function also terminates (defensive)
        if re.match(r"^(local\s+)?function\s", line):
            break
        body.append(line)
    return "\n".join(body)


def resolve_targets(body):
    found = set()
    for pat, fn in RE_TARGETS:
        for m in pat.finditer(body):
            found.add(fn(m))
    if not found:
        return ["dynamic"]
    return sorted(found)


def extract_file(path, relpath, classes, units, coverage):
    text = read(path)
    lines = text.split("\n")

    # 1. Map class-vars -> canonical setClassName, and note mode declarations.
    var_to_name = {}       # class-var -> canonical class name (from setClassName)
    class_vars = set()     # vars declared as `local X = Class{...}` etc.
    mode_vars = {}         # mode-var -> mode name (from Mode("Name"))

    for i, line in enumerate(lines):
        m = RE_MODE_DECL.match(line)
        if m:
            mode_vars[m.group(1)] = m.group(2)
            var_to_name[m.group(1)] = m.group(2)
            continue
        m = RE_CLASS_DECL.match(line)
        if m:
            class_vars.add(m.group(1))
        m = RE_INIT_DEF.match(line)
        if m:
            var = m.group(1)
            body = function_body(lines, i)
            cn = RE_SET_CLASSNAME.search(body)
            if cn:
                var_to_name[var] = cn.group(1)

    # A file-global fallback: if exactly one setClassName in the whole file and one
    # class-var with handlers but no init-scoped name, use it. (Conservative.)
    all_setnames = RE_SET_CLASSNAME.findall(text)

    # 2. Collect gesture handlers (method-def + dotted-assign forms).
    file_handlers = {}   # var -> { handler_name -> targets }
    for i, line in enumerate(lines):
        m = RE_METHOD_DEF.match(line)
        var = handler = None
        if m:
            var, handler = m.group(1), m.group(2)
        else:
            m = RE_METHOD_ASSIGN.match(line)
            if m:
                var, handler = m.group(1), m.group(2)
        if var is None:
            continue
        body = function_body(lines, i)
        file_handlers.setdefault(var, {})[handler] = resolve_targets(body)

    # 3. Mode/Signal handlers: Signal.register("event", localfn).
    #    Resolve localfn body for target extraction.
    local_func_bodies = {}
    for i, line in enumerate(lines):
        m = RE_LOCAL_FUNC.match(line)
        if m:
            local_func_bodies[m.group(1)] = function_body(lines, i)
    for m in RE_SIGNAL_REGISTER.finditer(text):
        event, fn = m.group(1), m.group(2)
        # attribute to the (single) mode var in this file, if any.
        if mode_vars:
            mvar = sorted(mode_vars)[0]
            body = local_func_bodies.get(fn, "")
            targets = resolve_targets(body) if body else ["dynamic"]
            file_handlers.setdefault(mvar, {}).setdefault(event, targets)

    # 4. Emit class entries.
    for var, handlers in file_handlers.items():
        name = var_to_name.get(var)
        resolved = name is not None
        if not resolved:
            # single-class file fallback
            if len(all_setnames) == 1 and len(file_handlers) == 1:
                name = all_setnames[0]
                resolved = True
        if not resolved:
            name = var  # fall back to the local class-var identity
        key = name
        # disambiguate collisions deterministically by appending the relpath.
        if key in classes and classes[key]["file"] != relpath:
            key = "%s @%s" % (name, relpath)
        entry = classes.setdefault(key, {
            "file": relpath,
            "class_var": var,
            "name_resolved": resolved,
            "handlers": {},
        })
        for h, targets in handlers.items():
            entry["handlers"][h] = targets
        coverage["classes"] += 1
        coverage["handlers"] += len(handlers)
        if not resolved:
            coverage["classes_unresolved"] += 1

    # 5. Unit view slot maps. A file is a "unit" for our purposes iff it declares an
    #    `expanded`/`collapsed` view list. Parse the list(s), map to M-slots, and
    #    resolve each entry's control class.
    view_lists = {}
    n = len(lines)
    for i, line in enumerate(lines):
        for lm in RE_VIEW_LIST_START.finditer(line):
            kind = lm.group(1)
            # collect the brace-delimited list, possibly multi-line
            frag = line[lm.end() - 1:]  # start at the opening brace
            depth = 0
            collected = []
            j = i
            col = line.find("{", lm.start())
            buf = line[col:]
            while j < n:
                for ch in buf:
                    if ch == "{":
                        depth += 1
                    elif ch == "}":
                        depth -= 1
                        if depth == 0:
                            break
                collected.append(buf)
                if depth == 0:
                    break
                j += 1
                buf = lines[j] if j < n else ""
            listtext = "\n".join(collected)
            items = RE_STRING_ITEM.findall(listtext)
            # only the first occurrence of each kind (the view table) is kept
            view_lists.setdefault(kind, items)

    if view_lists:
        unit_name = os.path.splitext(os.path.basename(relpath))[0]
        slots = {}
        overview = None
        expanded = view_lists.get("expanded", [])
        collapsed = view_lists.get("collapsed", [])
        for idx, entry_name in enumerate(expanded):
            slot = "M%d" % (idx + 1)
            ctrl = _control_class_for(entry_name, text)
            slots[slot] = {"name": entry_name, "control": ctrl or "dynamic"}
            if ctrl and re.search(r"Overview|Graphic|Scope", ctrl) and overview is None:
                overview = {"slot": slot, "name": entry_name, "control": ctrl}
        key = unit_name
        if key in units and units[key]["file"] != relpath:
            key = "%s @%s" % (unit_name, relpath)
        units[key] = {
            "file": relpath,
            "expanded": expanded,
            "collapsed": collapsed,
            "slots": slots,
            "overview": overview,
        }
        coverage["units"] += 1


def walk_lua(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for fn in sorted(filenames):
            if fn.endswith(".lua"):
                yield os.path.join(dirpath, fn)


def build(repo_root, extra_pkg_dirs=None):
    classes = {}
    units = {}
    coverage = {
        "files_scanned": 0,
        "classes": 0,
        "classes_unresolved": 0,
        "handlers": 0,
        "units": 0,
    }
    sources = []
    scan_roots = [
        os.path.join(repo_root, "xroot"),
        os.path.join(repo_root, "mods"),
    ]
    for root in scan_roots:
        if os.path.isdir(root):
            sources.append(os.path.relpath(root, repo_root))
    for pkg in (extra_pkg_dirs or []):
        if os.path.isdir(pkg):
            scan_roots.append(pkg)
            sources.append(pkg)  # absolute; flags non-repo provenance

    for root in scan_roots:
        for path in walk_lua(root):
            # keep relpaths repo-relative when possible so the manifest is portable
            try:
                rel = os.path.relpath(path, repo_root)
            except ValueError:
                rel = path
            if rel.startswith(".."):
                rel = path  # out-of-tree package source: absolute (inspection only)
            extract_file(path, rel, classes, units, coverage)
            coverage["files_scanned"] += 1

    manifest = {
        "_note": "generated by tools/extract_ui_model.py; do not hand-edit. "
                 "run `scripts/dev ui-model` (STOL_UPDATE_UI_MODEL=1 to accept drift)",
        "_schema": SCHEMA_VERSION,
        "_sources": sorted(sources),
        "gesture_vocabulary": sorted(VOCAB),
        "classes": classes,
        "units": units,
    }
    return manifest, coverage


# ── logical gesture -> emu control-protocol mapping ──────────────────────────
# The §1 logical tokens map to the emu control protocol (planning/headless-emu-
# plan.md §2) via the Application.lua button dispatch + hal/events.h button->event
# wiring (DIAL1=dialmode, DIAL2=cancel, DIAL3=home; SHIFT+ENTER=commit; SHIFT+DIAL3
# =zero). This table is the single source for docs/UI_OPERATION.md's mapping.
CONTROL_PROTOCOL_MAP = [
    # (logical gesture, control-protocol realization, notify event(s))
    ("enter",        "press ENTER",                       "enterReleased"),
    ("commit",       "down SHIFT / press ENTER / up SHIFT", "commitReleased"),
    ("cancel",       "press DIAL2",                       "cancelReleased"),
    ("home",         "press DIAL3",                       "homeReleased"),
    ("zero",         "down SHIFT / press DIAL3 / up SHIFT", "zeroReleased"),
    ("dial",         "press DIAL1",                       "dialReleased (dial-mode)"),
    ("up",           "press UP",                          "upReleased"),
    ("shift",        "down SHIFT ... up SHIFT",           "shiftPressed / shiftReleased"),
    ("main<i>",      "press MAIN<i>   (i = 1..6)",        "mainReleased(i)"),
    ("sub<i>",       "press SUB<i>    (i = 1..3)",        "subReleased(i)"),
    ("select<i>",    "press SELECT<i> (i = 1..4)",        "selectReleased(i)"),
    ("encoder<+/-N>", "turn N   (signed detents)",        "encoder(change, shifted)"),
    ("shifted modifier", "wrap any gesture in down SHIFT / ... / up SHIFT",
     "the trailing `shifted` handler arg is true"),
]


def catalog_markdown(manifest):
    """Render the manifest-derived reference tables for docs/UI_OPERATION.md.
    The hand-written canonical-gesture transcripts live in the doc; THIS block is
    regenerable (`--catalog`) so the vocabulary + slot maps never drift."""
    out = []
    out.append("<!-- BEGIN GENERATED: tools/extract_ui_model.py --catalog -->")
    out.append("")
    out.append("### Gesture vocabulary (notify events)")
    out.append("")
    out.append("The complete `notify(event, ...)` alphabet (Application.lua "
               "`defaultDispatcher`). Every Window/Control/Mode handler name is "
               "drawn from exactly this set:")
    out.append("")
    vocab = manifest["gesture_vocabulary"]
    for i in range(0, len(vocab), 4):
        out.append("- " + ", ".join("`%s`" % v for v in vocab[i:i + 4]))
    out.append("")
    out.append("### Logical gesture to emu control-protocol")
    out.append("")
    out.append("| logical gesture | control-protocol | notify event |")
    out.append("|---|---|---|")
    for logical, proto, notify in CONTROL_PROTOCOL_MAP:
        out.append("| `%s` | `%s` | `%s` |" % (logical, proto, notify))
    out.append("")
    out.append("### View-list slot convention (M1-M6)")
    out.append("")
    out.append("A focused unit's controls sit at M1-M6 in the order of its "
               "`views.expanded` list (index 1 -> M1). Sample core units "
               "(name @ slot = control class):")
    out.append("")
    out.append("| unit | M1 | M2 | M3 | M4 | M5 | M6 |")
    out.append("|---|---|---|---|---|---|---|")
    sample = ["FoldUnit", "LadderFilterUnit", "EQ3Unit", "OffsetUnit",
              "LimiterUnit", "MixerUnit"]
    for uname in sample:
        u = manifest["units"].get(uname)
        if not u:
            continue
        cells = []
        for n in range(1, 7):
            s = u["slots"].get("M%d" % n)
            cells.append("%s=%s" % (s["name"], s["control"]) if s else "-")
        out.append("| %s | %s |" % (uname, " | ".join(cells)))
    out.append("")
    out.append("_Total surface: %d classes, %d units, %d gesture handlers "
               "(from `testing-assets/emu/ui-model.manifest`)._" % (
                   len(manifest["classes"]), len(manifest["units"]),
                   sum(len(v["handlers"]) for v in manifest["classes"].values())))
    out.append("")
    out.append("<!-- END GENERATED -->")
    return "\n".join(out) + "\n"


GEN_BEGIN = "<!-- BEGIN GENERATED: tools/extract_ui_model.py --catalog -->"
GEN_END = "<!-- END GENERATED -->"


def splice_doc(doc_text, block):
    """Replace the BEGIN..END GENERATED region of a doc with `block`. Returns the
    new doc text. Raises if the markers are absent/unbalanced."""
    b = doc_text.find(GEN_BEGIN)
    e = doc_text.find(GEN_END)
    if b < 0 or e < 0 or e < b:
        raise ValueError("doc is missing a well-formed GENERATED block")
    e_end = e + len(GEN_END)
    # keep everything before BEGIN and after END; block already carries the markers
    prefix = doc_text[:b]
    suffix = doc_text[e_end:]
    return prefix + block.rstrip("\n") + suffix


def dumps(manifest):
    # sort_keys makes it byte-stable regardless of insertion order.
    return json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Extract the static UI behavior manifest.")
    ap.add_argument("-o", "--output", help="write manifest to PATH (default: stdout)")
    ap.add_argument("--coverage", action="store_true",
                    help="print a coverage report to stderr")
    ap.add_argument("--include-packages", metavar="DIR", action="append", default=[],
                    help="also scan an out-of-tree package lib dir (NOT committed)")
    ap.add_argument("--catalog", action="store_true",
                    help="emit the manifest-derived markdown reference block "
                         "(the generated section of docs/UI_OPERATION.md)")
    ap.add_argument("--check-doc", metavar="DOC",
                    help="exit 1 if DOC's GENERATED block is out of sync (no write)")
    ap.add_argument("--sync-doc", metavar="DOC",
                    help="rewrite DOC's GENERATED block from the current manifest")
    args = ap.parse_args(argv)

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    manifest, coverage = build(repo_root, extra_pkg_dirs=args.include_packages)

    if args.check_doc or args.sync_doc:
        docpath = args.check_doc or args.sync_doc
        block = catalog_markdown(manifest)
        with open(docpath, "r", encoding="utf-8") as f:
            doc = f.read()
        new = splice_doc(doc, block)
        if args.sync_doc:
            with open(docpath, "w", encoding="utf-8") as f:
                f.write(new)
            sys.stderr.write("synced GENERATED block in %s\n" % docpath)
            return 0
        if new != doc:
            sys.stderr.write("doc out of sync: %s (run --sync-doc to update)\n" % docpath)
            return 1
        sys.stderr.write("doc in sync: %s\n" % docpath)
        return 0

    text = catalog_markdown(manifest) if args.catalog else dumps(manifest)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.write(text)

    if args.coverage:
        sys.stderr.write(
            "coverage: files=%d classes=%d (unresolved=%d) handlers=%d units=%d\n" % (
                coverage["files_scanned"], coverage["classes"],
                coverage["classes_unresolved"], coverage["handlers"],
                coverage["units"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""ui_fluents.py -- the ER-301 UI planning-domain STATE SCHEMA (fluent layer).

[stol:ui-planner-state-schema]  Layer "state schema" of the ui-planner cluster
(planning/ui-planning-domain-plan.md §3). This is the FAR-END goal language: a
fixed, typed FLUENT VOCABULARY describing any reachable UI state, plus a
deterministic projection

    live UI state  ->  canonical, SORTED set of fluent strings

A GOAL is a PARTIAL assignment of these fluents (a subset that must hold); the
solver/operators reason entirely in this vocabulary. The UI is deterministic and
fully observable (emu.uiState() is a perfect oracle), so this is a classical
PLANNING problem -- no learning anywhere. See docs/UI_STATE_SCHEMA.md for the
per-fluent derivation, worked example states, and the input-bundle contract.

Stdlib only. Read-only: this module never drives the emu; it normalizes a JSON
state bundle that a caller assembles from `lua` control-command queries (the
emu's `require('emu.UIState').describe()` JSON plus a few supplementary
readbacks -- see STATE BUNDLE below). It does NOT modify xroot/emu/UIState.lua.

────────────────────────────────────────────────────────────────────────────────
THE FLUENT VOCABULARY (printed form -- the CONTRACT the operator sibling mirrors)
────────────────────────────────────────────────────────────────────────────────
Every fluent prints as  name(arg,arg,...)  with NO spaces around the commas or
parens. A fluent SET is the sorted, de-duplicated list of these strings, so
identical UI states yield byte-identical sets and a goal is a literal subset.

  context(<node>)                 exactly one. The visible ui-map node
                                  (home, scope, sequencer, admin,
                                  unit_picker_dense, sample_pool, quicksave,
                                  hold, ...). Falls back to the raw top-window
                                  class when the class is not a mapped node.
  focused_class(<ClassName>)      exactly one. The encoder-focus leaf class.
  focused_unit(<unitTitle>)       0..1. Title of the focused chain unit.
  unit_in_chain(<unitTitle>)      0..N. A unit present in the selected chain.
  linked(<a>,<b>)                 0..N. Channels a,b stereo-linked; a<b adjacent.
  slot_control(<slot>,<id>)       0..N. Control at a slot (M1..M6). <id> is BOTH
                                  the control class AND (when it differs) its
                                  on-screen name, so a goal may name either.
  column_cursor(<colName>)        0..1. Sequencer column cursor
                                  (cv1|cv2|g1L|g2L|stL|tr).
  cell(<slot>,<col>,<row>,<value>) 0..N. Sequencer L1 cell value (numeric; raw,
                                  e.g. 3.0). Compared with numeric tolerance.
  modal(<flag>)                   0..N. Active modal flag (editingL1,
                                  markingMode, bpmLatched, selectionActive,
                                  favoritesEditMode, ...). Mirrors uiState.modals
                                  verbatim.

────────────────────────────────────────────────────────────────────────────────
STATE BUNDLE (the projection input -- "uiState + supplementary readbacks")
────────────────────────────────────────────────────────────────────────────────
Three fluents (cell, linked, column_cursor) and one (focused_unit) are NOT in the
base uiState JSON, so the projection consumes a small BUNDLE the caller assembles
from separate `lua` queries (rather than editing UIState.lua). Shape:

  {
    "uiState": { ...require('emu.UIState').describe()... },   # REQUIRED
    "links":   {"link12": false, "link23": false, "link34": false},
    "focused_unit": "<title>",                # when a Unit is focused
    "units_in_chain": ["<title>", ...],
    "sequencer": {                            # present iff on Sequencer.GridView
      "slot": 0,
      "columnCursor": 0,
      "cells": [["cv1", 0, 3.0], ["cv1", 1, 3.0], ...]   # [colName, row, value]
    }
  }

The exact `lua` one-liners that produce each field are documented in
docs/UI_STATE_SCHEMA.md ("Assembling the bundle"). Everything except `uiState`
is optional; a bare `{"uiState": ...}` still projects context/focused_class/
slot_control/modal.

API:
  project(bundle)            -> sorted list[str]   (the canonical fluent set)
  project_json(json_text)    -> sorted list[str]
  parse_goal(text)           -> sorted list[str]   (from JSON array or lines)
  satisfies(state, goal)     -> bool               (goal subset of state; cell
                                                    values matched within tol)

CLI:
  tools/ui_fluents.py --selftest                 hand-authored fixtures + asserts
  tools/ui_fluents.py --project STATE.json       print the projected fluent set
  tools/ui_fluents.py --project STATE.json --goal 'context(sequencer)\n...'
                                                 also print SATISFIED / NOT
"""

import argparse
import json
import sys

# ── canonical column names (mirror xroot/Sequencer/GridView.lua kColNames) ──────
# GridView stores "tr " with a trailing pad space for the fixed-width header; the
# fluent form strips it to a bare token.
COLNAMES = ["cv1", "cv2", "g1L", "g2L", "stL", "tr"]

# ── top-window class -> ui-map node (mirror testing-assets/emu/ui-map.toml) ─────
# Kept in lockstep with the `recognize` predicates in ui-map.toml. When a class is
# not a mapped node the projection falls back to context(<TopClass>) so the set is
# never missing its (single) context fluent.
CONTEXT_BY_TOPCLASS = {
    "Chain.Root": "home",
    "Chain.ScopeView": "scope",
    "Sequencer.GridView": "sequencer",
    "SceneView.Performance": "hold",
    "Unit.Chooser.Dense": "unit_picker_dense",
    "Unit.Chooser.Default": "unit_picker_classic",
    "Unit.Chooser.Preset": "unit_picker_classic",
    "SamplePool.Interface": "sample_pool",
    "QuickSaver": "quicksave",
}

# Numeric tolerance for cell() value comparison in satisfies().
CELL_TOL = 1e-6


# ── number formatting ───────────────────────────────────────────────────────────

def fmt_value(v):
    """Canonical printed form of a sequencer cell value (a float).

    Whole numbers keep one decimal place (3 -> '3.0') to match the documented
    printed form; fractional values strip trailing zeros (3.250 -> '3.25')."""
    f = float(v)
    if f == int(f):
        return "%d.0" % int(f)
    s = ("%.6f" % f).rstrip("0")
    if s.endswith("."):
        s += "0"
    return s


def _fmt_arg(a):
    """Print a fluent argument. Ints print bare; everything else via str()."""
    if isinstance(a, bool):
        return "true" if a else "false"
    if isinstance(a, int):
        return "%d" % a
    return str(a)


def fluent(name, *args):
    """Build a canonical fluent string:  name(a,b,...)."""
    return "%s(%s)" % (name, ",".join(_fmt_arg(a) for a in args))


# ── parsing ─────────────────────────────────────────────────────────────────────

def parse_fluent(s):
    """Split 'name(a,b,c)' -> ('name', ['a','b','c']). Args are bare tokens (this
    domain has none containing ',' or ')'). Returns (name, args) or None."""
    s = s.strip()
    if not s or "(" not in s or not s.endswith(")"):
        return None
    name, rest = s.split("(", 1)
    inner = rest[:-1]
    args = [a.strip() for a in inner.split(",")] if inner else []
    return name.strip(), args


def normalize_fluent(s):
    """Re-emit a fluent string in canonical form (re-formats cell() values so a
    goal authored as cell(0,cv1,0,3) matches state cell(0,cv1,0,3.0))."""
    parsed = parse_fluent(s)
    if parsed is None:
        return s.strip()
    name, args = parsed
    if name == "cell" and len(args) == 4:
        slot, col, row, val = args
        return fluent("cell", int(float(slot)), col, int(float(row)), fmt_value(val))
    return "%s(%s)" % (name, ",".join(args))


# ── projection ──────────────────────────────────────────────────────────────────

def project(bundle):
    """Project a STATE BUNDLE (see module docstring) to a sorted, de-duplicated
    list of canonical fluent strings."""
    ui = bundle.get("uiState") or {}
    out = set()

    # context(<node>): from the top-window class (+ Admin instance tiebreak).
    stack = ui.get("stack") or []
    focus = ui.get("focus") or {}
    top = stack[0] if stack else focus.get("class", "")
    node = CONTEXT_BY_TOPCLASS.get(top)
    if node is None and top == "Menu":
        name = (ui.get("context") or {}).get("name", "")
        if "Admin" in name:
            node = "admin"
    if node is None:
        node = top or "unknown"
    out.add(fluent("context", node))

    # focused_class(<ClassName>): the encoder-focus leaf.
    fclass = focus.get("class", "")
    if fclass:
        out.add(fluent("focused_class", fclass))

    # slot_control(<slot>,<id>): class always, plus name when it differs/non-empty.
    for c in ui.get("controls") or []:
        slot = c.get("slot")
        klass = c.get("class")
        if not slot or not klass:
            continue
        out.add(fluent("slot_control", slot, klass))
        nm = c.get("name")
        if nm is not None and nm != "" and str(nm) != str(klass):
            out.add(fluent("slot_control", slot, str(nm)))

    # modal(<flag>): mirror uiState.modals verbatim.
    for m in ui.get("modals") or []:
        out.add(fluent("modal", m))

    # focused_unit(<title>): supplementary (getSelection().title). Fall back to
    # the uiState selection sectionName only when it clearly names a Unit.
    fu = bundle.get("focused_unit")
    if fu:
        out.add(fluent("focused_unit", fu))

    # unit_in_chain(<title>): supplementary chain listing.
    for u in bundle.get("units_in_chain") or []:
        if u:
            out.add(fluent("unit_in_chain", u))

    # linked(<a>,<b>): supplementary Channels.serialize().links.
    links = bundle.get("links") or {}
    for a in (1, 2, 3):
        key = "link%d%d" % (a, a + 1)
        if links.get(key):
            out.add(fluent("linked", a, a + 1))

    # column_cursor + cell: supplementary sequencer readback.
    seq = bundle.get("sequencer")
    if seq:
        slot = int(seq.get("slot", 0))
        cc = seq.get("columnCursor")
        if cc is not None:
            idx = int(cc)
            col = COLNAMES[idx] if 0 <= idx < len(COLNAMES) else str(idx)
            out.add(fluent("column_cursor", col))
        for entry in seq.get("cells") or []:
            col, row, val = entry[0], int(entry[1]), float(entry[2])
            out.add(fluent("cell", slot, col, row, fmt_value(val)))

    return sorted(out)


def project_json(json_text):
    return project(json.loads(json_text))


# ── goals + satisfaction ─────────────────────────────────────────────────────────

def parse_goal(text):
    """Parse a partial fluent set from JSON (an array of fluent strings) or a
    newline/semicolon-separated list. '#' comments and blanks are ignored.
    Returns a sorted, de-duplicated, canonicalized list."""
    text = text.strip()
    items = []
    if text.startswith("["):
        items = list(json.loads(text))
    else:
        for chunk in text.replace(";", "\n").split("\n"):
            c = chunk.strip()
            if not c or c.startswith("#"):
                continue
            items.append(c)
    return sorted({normalize_fluent(x) for x in items})


def _cell_key(args):
    """(slot, col, row) identity of a cell fluent; value excluded."""
    return (int(float(args[0])), args[1], int(float(args[2])))


def satisfies(state_fluents, goal_fluents):
    """True iff goal is a subset of state. Non-cell fluents match by exact string;
    cell() fluents match on (slot,col,row) with the value compared within
    CELL_TOL (so 3.0 satisfies a goal of 3.0000001)."""
    state = set(state_fluents)
    # Index state cells by (slot,col,row) -> value for tolerant matching.
    state_cells = {}
    for s in state:
        p = parse_fluent(s)
        if p and p[0] == "cell" and len(p[1]) == 4:
            state_cells[_cell_key(p[1])] = float(p[1][3])

    for g in goal_fluents:
        p = parse_fluent(g)
        if p and p[0] == "cell" and len(p[1]) == 4:
            key = _cell_key(p[1])
            if key not in state_cells:
                return False
            if abs(state_cells[key] - float(p[1][3])) > CELL_TOL:
                return False
        else:
            if normalize_fluent(g) not in state:
                return False
    return True


# ── selftest (hand-authored fixtures; no emu) ────────────────────────────────────

# Fixture: the boot Chain.Root state (captured live 2026-07-10 from the hermetic
# fixture, pickerStyle=dense). uiState fields verified against
# require('emu.UIState').describe() field-by-field.
BOOT_BUNDLE = {
    "uiState": {
        "context": {"class": "Context", "name": "OUT1 edit"},
        "stack": ["Chain.Root"],
        "focus": {"class": "Chain.Root", "name": "OUT1,depth=1",
                  "chain": ["Chain.Root"]},
        "controls": [
            {"slot": "M1", "class": "ChainTitleControl", "name": ""},
            {"slot": "M2", "class": "InputControl", "name": 1},
            {"slot": "M3", "class": "EmptySection.EmptyControl", "name": ""},
            {"slot": "M4", "class": "EmptySection.EmptyControl", "name": ""},
            {"slot": "M5", "class": "EmptySection.EmptyControl", "name": ""},
            {"slot": "M6", "class": "MonitorControl", "name": ""},
        ],
        "modals": [],
        "selection": {"section": "HeaderSection", "control": "ChainTitleControl",
                      "sectionName": ""},
        "gestures": [],
    },
    "links": {"link12": False, "link23": False, "link34": False},
}

# Fixture: the sequencer cv1-rows-0..5 == 3.0 ("C3") state, reproducing the proven
# recipe (mode down -> SHIFT+ENTER -> Sequencer.GridView, MAIN1 focuses cv1, then
# seq:setL1(0,0,r,3.0)). uiState.modals verified live: MAIN1 enters editingL1, and
# markingMode reads truthy because GridView's idle marking state is the string
# "idle" (a UIState.lua scan behavior we faithfully mirror; see UI_STATE_SCHEMA.md).
SEQ_C3_BUNDLE = {
    "uiState": {
        "context": {"class": "Context", "name": "OUT1 sequencer"},
        "stack": ["Sequencer.GridView", "Chain.ScopeView", "Chain.Root"],
        "focus": {"class": "Sequencer.GridView", "name": "",
                  "chain": ["Sequencer.GridView"]},
        "controls": [],
        "modals": ["editingL1", "markingMode"],
        "gestures": [],
    },
    "links": {"link12": False, "link23": False, "link34": False},
    "sequencer": {
        "slot": 0,
        "columnCursor": 0,
        "cells": [["cv1", r, 3.0] for r in range(6)],
    },
}


def selftest():
    failures = []

    def check(cond, msg):
        print("  [%s] %s" % ("PASS" if cond else "FAIL", msg))
        if not cond:
            failures.append(msg)

    print("ui_fluents.py --selftest (projection + goal satisfaction)")

    # ── boot state projection ───────────────────────────────────────────────────
    boot = project(BOOT_BUNDLE)
    bset = set(boot)
    check("context(home)" in bset, "boot -> context(home)")
    check("focused_class(Chain.Root)" in bset, "boot -> focused_class(Chain.Root)")
    check("slot_control(M1,ChainTitleControl)" in bset,
          "boot -> slot_control(M1,ChainTitleControl)")
    check("slot_control(M3,EmptySection.EmptyControl)" in bset,
          "boot -> slot_control(M3,EmptySection.EmptyControl)")
    # M2's InputControl carries the numeric on-screen name 1 -> both class + name.
    check("slot_control(M2,InputControl)" in bset,
          "boot -> slot_control(M2,InputControl) [class]")
    check("slot_control(M2,1)" in bset,
          "boot -> slot_control(M2,1) [numeric name]")
    check(not any(f.startswith("cell(") for f in boot), "boot -> no cell fluents")
    check(not any(f.startswith("modal(") for f in boot), "boot -> no modal fluents")
    check(not any(f.startswith("linked(") for f in boot), "boot -> no linked fluents")
    check(not any(f.startswith("column_cursor(") for f in boot),
          "boot -> no column_cursor fluent")
    check(boot == sorted(boot), "boot fluent set is sorted")
    check(project(BOOT_BUNDLE) == boot, "boot projection is deterministic")

    # ── sequencer C3 projection ─────────────────────────────────────────────────
    seq = project(SEQ_C3_BUNDLE)
    sset = set(seq)
    check("context(sequencer)" in sset, "C3 -> context(sequencer)")
    check("focused_class(Sequencer.GridView)" in sset,
          "C3 -> focused_class(Sequencer.GridView)")
    check("column_cursor(cv1)" in sset, "C3 -> column_cursor(cv1)")
    for r in range(6):
        check(("cell(0,cv1,%d,3.0)" % r) in sset, "C3 -> cell(0,cv1,%d,3.0)" % r)
    check("modal(editingL1)" in sset, "C3 -> modal(editingL1)")
    check("modal(markingMode)" in sset, "C3 -> modal(markingMode)")

    # ── C3 goal satisfaction (the headline proof) ───────────────────────────────
    c3_goal = ["context(sequencer)", "column_cursor(cv1)"] + \
              ["cell(0,cv1,%d,3.0)" % r for r in range(6)]
    check(satisfies(seq, c3_goal), "satisfies(C3 state, C3 goal) is True")
    # Partial goal (a strict subset) still holds.
    check(satisfies(seq, ["context(sequencer)"]),
          "satisfies(C3 state, {context(sequencer)}) is True")
    # Goal authored with integer cell value normalizes and still matches.
    check(satisfies(seq, ["cell(0,cv1,0,3)"]),
          "satisfies tolerates cell(0,cv1,0,3) == 3.0")

    # ── mismatch cases ──────────────────────────────────────────────────────────
    check(not satisfies(seq, ["cell(0,cv1,0,5.0)"]),
          "MISMATCH: wrong cell value -> not satisfied")
    check(not satisfies(seq, ["modal(bpmLatched)"]),
          "MISMATCH: absent modal -> not satisfied")
    check(not satisfies(seq, ["context(home)"]),
          "MISMATCH: wrong context -> not satisfied")
    check(not satisfies(boot, c3_goal),
          "MISMATCH: boot state does not satisfy the C3 goal")

    # ── cell value numeric tolerance boundary ───────────────────────────────────
    near = ["cell(0,cv1,0,3.0000001)"]
    far = ["cell(0,cv1,0,3.01)"]
    check(satisfies(seq, near), "tolerance: 3.0000001 satisfies 3.0")
    check(not satisfies(seq, far), "tolerance: 3.01 does NOT satisfy 3.0")

    # ── linked() from supplementary links ───────────────────────────────────────
    linked_bundle = json.loads(json.dumps(BOOT_BUNDLE))  # deep copy
    linked_bundle["links"] = {"link12": True, "link23": False, "link34": False}
    lf = project(linked_bundle)
    check("linked(1,2)" in lf, "links.link12 -> linked(1,2)")
    check("linked(2,3)" not in lf, "links.link23 false -> no linked(2,3)")

    # ── parse_goal forms ────────────────────────────────────────────────────────
    g_lines = parse_goal("context(sequencer)\ncell(0,cv1,0,3)\n# a comment\n")
    check(g_lines == ["cell(0,cv1,0,3.0)", "context(sequencer)"],
          "parse_goal: lines + comment + cell normalization")
    g_json = parse_goal('["context(home)", "focused_class(Chain.Root)"]')
    check(g_json == ["context(home)", "focused_class(Chain.Root)"],
          "parse_goal: JSON array form")
    g_semi = parse_goal("context(sequencer); column_cursor(cv1)")
    check(g_semi == ["column_cursor(cv1)", "context(sequencer)"],
          "parse_goal: semicolon-separated form")

    print()
    if failures:
        print("SELFTEST FAILED: %d check(s)" % len(failures))
        return 1
    print("SELFTEST OK")
    return 0


# ── cli ─────────────────────────────────────────────────────────────────────────

def main(argv):
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--selftest", action="store_true",
                   help="run the hand-authored projection + satisfaction checks")
    p.add_argument("--project", metavar="STATE.json",
                   help="project a state bundle (JSON file, or '-' for stdin)")
    p.add_argument("--goal", help="a partial fluent set to test against --project")
    args = p.parse_args(argv[1:])

    if args.selftest:
        return selftest()

    if args.project:
        text = sys.stdin.read() if args.project == "-" else open(args.project).read()
        fluents = project_json(text)
        for f in fluents:
            print(f)
        if args.goal:
            goal = parse_goal(args.goal)
            ok = satisfies(fluents, goal)
            print("\n# goal: %s" % goal)
            print("# %s" % ("SATISFIED" if ok else "NOT SATISFIED"))
            return 0 if ok else 1
        return 0

    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""ui_solve.py -- a classical GOAL SOLVER for the ER-301 UI planning domain.

[stol:ui-planner-solver]  The top layer of the ui-planner cluster
(planning/ui-planning-domain-plan.md §5). Given an arbitrary PARTIAL fluent GOAL
it searches the merged operator library for an ordered operator plan that reaches
a state satisfying the goal, renders that plan to control-protocol gestures, and
(with --run) drives the headless emulator to EXECUTE the plan with REAL gestures,
asserting each operator's effect and finally `satisfies(state, goal)`.

The 301 UI is deterministic and fully observable (emu.uiState() is a perfect
oracle), so this is a classical PLANNING problem: forward A* over fluent states.
There is NO learning anywhere -- deterministic search only.

It composes the lower layers, all already on develop:
  * tools/ui_fluents.py                    the fluent vocabulary + project/satisfies
  * testing-assets/emu/ui-operators.toml   20 typed operators (pre/eff/gesture)
  * testing-assets/emu/ui-crawl.map        the [[resolved]] refinements of the 6
                                           needs_crawl operators (gesture skeletons)
  * tools/emu_test.py  (via --run)         the hermetic sandbox + emu process wrapper

MERGE.  The operator set is ui-operators.toml's 20 operators, with each of the 6
`verified = needs_crawl` operators OVERLAID by its `[[resolved]]` block from
ui-crawl.map: the resolved `gesture` becomes the runtime gesture SKELETON, and any
resolved `effect` string that parses as a concrete domain fluent (e.g. set_cell's
`modal(editingL1)`) is unioned into the operator's effect. Prose effects (e.g.
expand/collapse's "slot_control map -> u.views.*") are left unmodeled -- see
COVERAGE below.

SEARCH.  Forward A* over frozenset fluent states.
  * Operators are GROUND-instantiated from the goal's target fluents (link(a,b)
    from linked(a,b); insert(u)/focus_unit(u) from unit_in_chain/focused_unit(u);
    select_column(col) from column_cursor(col); set_cell(slot,col,row,v) from each
    cell(...); the parameterless nav/open_picker operators need no binding).
  * An operator is APPLICABLE when, after binding, its positive preconditions are a
    subset of the state, its negated (`~`) preconditions are absent, and any
    `adjacent(a,b)` holds against the fixed channel topology (1-2, 2-3, 3-4).
  * apply(state, op) = state + eff - conflicts, where the "functional" families
    (context/1, focused_class/1, column_cursor/1, focused_unit/1 are 0..1) drop the
    prior binding and cell/4 replaces the same (slot,col,row) key.
  * Heuristic h = number of goal fluents not yet satisfied (admissible-ish); tie
    breaks are fully sorted so plans are byte-reproducible.
  * Goal test = ui_fluents.satisfies(state, goal).

LIVE-RESOLVED gestures.  Some gestures cannot be emitted offline; they are marked
`[live]` and resolved at --run time from uiState / readback:
  * open_picker -- the EmptyControl column is M3 on a mono chain, M4 after a stereo
    link; press whichever MAIN currently holds EmptySection.EmptyControl.
  * insert(u) -- the dense picker is a 2-column channel-count-filtered sorted list;
    read the live rows, find u's (row, side), `turn 3*row` then MAIN1(left)/MAIN4(right).
  * focus_unit(u) -- encoder detents depend on u's live chain position.
  * set_cell(slot,col,row,v) -- navigate focusHead to `row` (nav-mode encoder),
    ENTER (L1 edit, modal editingL1), `dial` to the right step mode, encoder-nudge
    to `v`, then UP to commit. The value->nudges is ARITHMETIC (see NUDGE MODEL).

NUDGE MODEL (set_cell, the C3 headline).  Each column declares fine/coarse encoder
steps (xroot/Sequencer/GridView.lua, mirrored in SEQUENCER.md). One encoder
THRESHOLD = Env.EncoderThreshold.Default = 3 raw detents (`turn 3`) = one step.
For cv1 the fine step is 1 semitone (1/12 V) and the coarse step is 1 octave
(1.0 V), so C3 = 3.0 V from 0 is 3 COARSE steps: `dial` to coarse then `turn 9`
(3 thresholds x 3 raw detents). The solver picks the mode whose step divides the
delta cleanly (fewest turns) and drives it closed-loop, verifying the cell by
readback within tolerance -- a REAL gesture path, never a `seq:setL1` shortcut.

SUPERSEDES.  This generalizes tools/ui_plan.py: ui_plan takes a fixed goal MENU
(context/link/insert/focus/expand/control_at keys) and emits a straight-line
script; ui_solve takes an ARBITRARY fluent goal and SEARCHES for the operator
sequence. ui_plan.py is left unmodified (its 53-ui-plan-core-insert.test still
guards the insert path); ui_solve.py is the goal-driven successor.

Stdlib only. Usage:
  tools/ui_solve.py --goal '<json-or-lines>'         print the offline plan
  tools/ui_solve.py --goal-file G                    goal from a file
  tools/ui_solve.py --run --goal '<...>'             drive the emu + VERIFY
  tools/ui_solve.py --selftest                        offline planning correctness

COVERAGE (goals the solver cannot plan yet -- missing operator modeling):
  * A goal fixing a specific slot_control map that only expand/collapse can produce:
    those operators' effect is a unit-specific view map (manifest units[u].views.*),
    not modeled as concrete fluents, so the planner will not route through them.
  * focus of a NON-inserted chain unit at a specific detent offset: focus_unit is
    modeled (effect focused_unit(u)) but its live detent count is only resolvable in
    --run; offline it is emitted as a [live] step.
"""

import argparse
import heapq
import itertools
import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "tools"))
import ui_fluents  # noqa: E402  (sibling module, stdlib-only)

DEFAULT_OPERATORS = os.path.join(REPO_ROOT, "testing-assets/emu/ui-operators.toml")
DEFAULT_CRAWL = os.path.join(REPO_ROOT, "testing-assets/emu/ui-crawl.map")

# Column name -> sequencer column index (mirror ui_fluents.COLNAMES / GridView).
COLIDX = {name: i for i, name in enumerate(ui_fluents.COLNAMES)}

# One encoder threshold = this many raw `turn` detents (Env.EncoderThreshold.Default;
# same constant ui_plan.py uses for picker row nav).
ENCODER_THRESHOLD = 3

# Per-column L1 edit step sizes (xroot/Sequencer/GridView.lua kColStep, mirrored in
# SEQUENCER.md). Used to convert a target cell value into encoder nudges.
COL_STEP = {
    "cv1": {"fine": 1.0 / 12.0, "coarse": 1.0},
    "cv2": {"fine": 0.1, "coarse": 1.0},
    "g1L": {"fine": 0.0625, "coarse": 0.25},
    "g2L": {"fine": 0.0625, "coarse": 0.25},
    "stL": {"fine": 0.25, "coarse": 1.0},
    "tr": {"fine": 1.0, "coarse": 12.0},
}

# context(node) -> a live recognize predicate (mirrors testing-assets/emu/ui-map.toml
# `recognize`). Used by --run to verify/skip context effects.
CTX_RECOGNIZE = {
    "home": "require('Application').getVisibleContext():top():getClassName() == 'Chain.Root'",
    "scope": "require('Application').getVisibleContext():top():getClassName() == 'Chain.ScopeView'",
    "sequencer": "require('Application').getVisibleContext():top():getClassName() == 'Sequencer.GridView'",
    "hold": "require('Application').getVisibleContext():top():getClassName() == 'SceneView.Performance'",
    "admin": ("require('Application').getVisibleContext():top():getClassName() == 'Menu' and "
              "require('Application').getVisibleContext():getInstanceName() == 'Admin'"),
    "unit_picker_dense": "require('Application').getVisibleContext():top():getClassName() == 'Unit.Chooser.Dense'",
    "unit_picker_classic": ("require('Application').getVisibleContext():top():getClassName() == 'Unit.Chooser.Default' or "
                            "require('Application').getVisibleContext():top():getClassName() == 'Unit.Chooser.Preset'"),
    "sample_pool": "require('Application').getVisibleContext():top():getClassName() == 'SamplePool.Interface'",
    "quicksave": "require('Application').getVisibleContext():top():getClassName() == 'QuickSaver'",
}

# Functional fluent families: at most one binding at a time, so a new eff of that
# name drops the prior one (apply()).
FUNCTIONAL_UNARY = {"context", "focused_class", "column_cursor", "focused_unit"}


# ── TOML loading ─────────────────────────────────────────────────────────────

def _load_toml(path):
    try:
        import tomllib
    except ImportError as e:  # pragma: no cover
        raise SystemExit("ui_solve.py needs Python 3.11+ (tomllib): %s" % e)
    with open(path, "rb") as f:
        return tomllib.load(f)


# ── the merged operator library ──────────────────────────────────────────────

class Operator:
    """A lifted operator: id, params, precondition/effect fluent TEMPLATES (bare
    param tokens; `~` negates a precondition), the runtime gesture skeleton, and
    whether its gesture must be resolved live."""

    def __init__(self, id, params, pre, eff, gesture, verified, source):
        self.id = id
        self.params = list(params)
        self.pre = list(pre)
        self.eff = list(eff)
        self.gesture = list(gesture)
        self.verified = verified
        self.source = source
        self.live = verified == "needs_crawl"

    def __repr__(self):
        return "Operator(%s%s)" % (self.id, "[live]" if self.live else "")


def load_operators(operators_path=DEFAULT_OPERATORS, crawl_path=DEFAULT_CRAWL):
    """Load ui-operators.toml and MERGE the 6 crawler-resolved refinements.

    Returns (operators_by_id, column_map). Each needs_crawl operator gets its
    resolved gesture SKELETON and any resolved effect that parses as a concrete
    domain fluent unioned into its effect. Prose effects are ignored."""
    optoml = _load_toml(operators_path)
    column_map = optoml.get("column_map", {})
    crawl = _load_toml(crawl_path)
    resolved = {r["id"]: r for r in crawl.get("resolved", [])}

    ops = {}
    for op in optoml.get("operator", []):
        oid = op["id"]
        pre = list(op.get("pre", []))
        eff = list(op.get("eff", []))
        gesture = list(op.get("gesture", []))
        verified = op.get("verified", "static")
        source = op.get("source", "")
        if oid in resolved and verified == "needs_crawl":
            r = resolved[oid]
            # The resolved gesture is the runtime SKELETON.
            gesture = list(r.get("gesture", gesture))
            # Union any resolved effect that is a concrete domain fluent (e.g.
            # set_cell's modal(editingL1)); prose effects are dropped.
            for e in r.get("effect", []):
                if _is_concrete_fluent(e) and e not in eff:
                    eff.append(e)
        ops[oid] = Operator(oid, op.get("params", []), pre, eff, gesture, verified, source)
    return ops, column_map


_FLUENT_NAMES = set(ui_fluents.CONTEXT_BY_TOPCLASS.values()) | {
    "context", "focused_class", "focused_unit", "unit_in_chain", "linked",
    "slot_control", "column_cursor", "cell", "modal", "adjacent",
}


def _is_concrete_fluent(s):
    """True iff s parses as a fluent whose name is in the domain vocabulary and
    whose args carry no unbound {placeholder}/prose (a real merge-able effect)."""
    p = ui_fluents.parse_fluent(s)
    if p is None:
        return False
    name, args = p
    if name not in ("context", "focused_class", "focused_unit", "unit_in_chain",
                    "linked", "slot_control", "column_cursor", "cell", "modal"):
        return False
    # Reject prose like "slot_control map -> ..." (spaces / arrows in the name).
    return " " not in name and "->" not in s


# ── grounding ────────────────────────────────────────────────────────────────

# Which goal fluent supplies each operator's params. "__unit__" = focused_unit or
# unit_in_chain (both name a chain-unit title).
PARAM_SOURCE = {
    "link": ("linked", ["a", "b"]),
    "insert": ("__unit__", ["u"]),
    "focus_unit": ("__unit__", ["u"]),
    "expand": ("focused_unit", ["u"]),
    "collapse": ("focused_unit", ["u"]),
    "select_column": ("column_cursor", ["col"]),
    "set_cell": ("cell", ["slot", "col", "row", "v"]),
}


class GroundOp:
    """A ground operator instance: the lifted Operator + a param binding + the
    substituted precondition/effect fluent lists."""

    def __init__(self, op, binding):
        self.op = op
        self.binding = dict(binding)
        self.pre = [_subst(p, binding) for p in op.pre]
        self.eff = [ui_fluents.normalize_fluent(_subst(e, binding)) for e in op.eff]
        # Gesture-template {param} substitution (e.g. link's "down SELECT{a}").
        # {placeholder}s that are NOT operator params (e.g. set_cell's {nudges},
        # open_picker's {i}) survive and are resolved by the live drivers.
        self.gesture = [self._subst_gesture(g, binding) for g in op.gesture]

    @staticmethod
    def _subst_gesture(line, binding):
        for k, v in binding.items():
            line = line.replace("{%s}" % k, str(v))
        return line

    @property
    def id(self):
        return self.op.id

    def key(self):
        """Deterministic sort/identity key."""
        if not self.binding:
            return self.op.id
        args = ",".join("%s=%s" % (k, self.binding[k]) for k in sorted(self.binding))
        return "%s(%s)" % (self.op.id, args)

    def label(self):
        """Human label: id(param values in declared order)."""
        if not self.op.params:
            return self.op.id
        vals = ",".join(str(self.binding.get(p, p)) for p in self.op.params)
        return "%s(%s)" % (self.op.id, vals)

    def __repr__(self):
        return "GroundOp(%s)" % self.label()


def _subst(templ, binding):
    """Substitute bound params into a fluent template, preserving a leading `~`.
    Bare arg tokens equal to a param name are replaced by the bound value."""
    neg = templ.startswith("~")
    body = templ[1:] if neg else templ
    p = ui_fluents.parse_fluent(body)
    if p is None:
        return templ
    name, args = p
    out_args = [str(binding.get(a, a)) for a in args]
    out = "%s(%s)" % (name, ",".join(out_args))
    return ("~" + out) if neg else out


def _goal_index(goal_fluents):
    """Index goal fluents by name -> list of arg lists."""
    idx = {}
    for g in goal_fluents:
        p = ui_fluents.parse_fluent(g)
        if p:
            idx.setdefault(p[0], []).append(p[1])
    return idx


def ground_ops(operators, goal_fluents):
    """Produce the deterministic, de-duplicated list of ground operator instances
    relevant to the goal (parameterless ops always included)."""
    gidx = _goal_index(goal_fluents)
    seen = {}
    for oid in sorted(operators):
        op = operators[oid]
        if not op.params:
            g = GroundOp(op, {})
            seen[g.key()] = g
            continue
        src, pnames = PARAM_SOURCE.get(oid, (None, op.params))
        arg_lists = []
        if src == "__unit__":
            arg_lists = gidx.get("focused_unit", []) + gidx.get("unit_in_chain", [])
        elif src:
            arg_lists = gidx.get(src, [])
        for args in arg_lists:
            if len(args) != len(pnames):
                continue
            binding = dict(zip(pnames, args))
            g = GroundOp(op, binding)
            seen[g.key()] = g
    return [seen[k] for k in sorted(seen)]


# ── applicability + apply ────────────────────────────────────────────────────

def _adjacent(a, b):
    try:
        a, b = int(a), int(b)
    except (TypeError, ValueError):
        return False
    return 1 <= a and b <= 4 and b == a + 1


def _has(state, name):
    """True iff any fluent of `name` is present in state."""
    for s in state:
        p = ui_fluents.parse_fluent(s)
        if p and p[0] == name:
            return True
    return False


def applicable(gop, state):
    """True iff gop's grounded precondition holds in `state` (a set of canonical
    fluent strings)."""
    # Domain-topology guards not expressible as plain fluents:
    #  * link(a,b) links CLEANLY only with empty chains (operator note: "Both
    #    chains empty -> links with no dialog"); so it must precede any insert.
    #  * nav_home_to_unit_picker_dense is the map's FIXED "press MAIN3" picker edge,
    #    valid only on a MONO chain -- after any stereo link the empty-insert column
    #    shifts (M3->M4), so the live-resolved open_picker must be used instead.
    if gop.op.id == "link" and _has(state, "unit_in_chain"):
        return False
    if gop.op.id == "nav_home_to_unit_picker_dense" and _has(state, "linked"):
        return False
    for pre in gop.pre:
        neg = pre.startswith("~")
        body = pre[1:] if neg else pre
        p = ui_fluents.parse_fluent(body)
        if p and p[0] == "adjacent":
            if neg == _adjacent(*p[1]):
                return False
            continue
        # open_picker's empty-slot precondition is parametric on the live chain
        # width: satisfied by ANY slot holding EmptySection.EmptyControl.
        if (gop.op.id == "open_picker" and p and p[0] == "slot_control"
                and p[1][1] == "EmptySection.EmptyControl"):
            has_empty = any(
                ui_fluents.parse_fluent(s) and ui_fluents.parse_fluent(s)[0] == "slot_control"
                and ui_fluents.parse_fluent(s)[1][1] == "EmptySection.EmptyControl"
                for s in state)
            if neg == has_empty:
                return False
            continue
        f = ui_fluents.normalize_fluent(body)
        present = f in state
        if neg == present:
            return False
    return True


def apply_op(gop, state):
    """Return the successor state (frozenset) of applying gop to `state`."""
    new = set(state)
    for e in gop.eff:
        p = ui_fluents.parse_fluent(e)
        if not p:
            continue
        name, args = p
        if name in FUNCTIONAL_UNARY:
            new = {s for s in new if not (
                ui_fluents.parse_fluent(s) and ui_fluents.parse_fluent(s)[0] == name)}
        elif name == "cell" and len(args) == 4:
            key = (args[0], args[1], args[2])
            new = {s for s in new if not (
                ui_fluents.parse_fluent(s) and ui_fluents.parse_fluent(s)[0] == "cell"
                and tuple(ui_fluents.parse_fluent(s)[1][:3]) == key)}
        new.add(e)
    return frozenset(new)


# ── A* search ────────────────────────────────────────────────────────────────

def _unsat_count(state, goal):
    """Heuristic: number of goal fluents not satisfied by state."""
    n = 0
    for g in goal:
        if not ui_fluents.satisfies(state, [g]):
            n += 1
    return n


class Plan:
    def __init__(self, ops):
        self.ops = list(ops)  # list[GroundOp]

    def __len__(self):
        return len(self.ops)


def solve(operators, start_fluents, goal_fluents, max_expansions=200000):
    """Forward A*. Returns a Plan (list of GroundOp) or None if no plan is found."""
    start = frozenset(ui_fluents.normalize_fluent(f) for f in start_fluents)
    goal = list(goal_fluents)
    insts = ground_ops(operators, goal)

    if ui_fluents.satisfies(start, goal):
        return Plan([])

    counter = itertools.count()
    h0 = _unsat_count(start, goal)
    frontier = [(h0, 0, next(counter), start, [])]
    best = {start: 0}
    expansions = 0

    while frontier:
        f, g, _, state, path = heapq.heappop(frontier)
        if g > best.get(state, g):
            continue
        if ui_fluents.satisfies(state, goal):
            return Plan(path)
        expansions += 1
        if expansions > max_expansions:
            break
        for gop in insts:  # already deterministically sorted
            if not applicable(gop, state):
                continue
            ns = apply_op(gop, state)
            if ns == state:
                continue
            ng = g + 1
            if ns in best and best[ns] <= ng:
                continue
            best[ns] = ng
            heapq.heappush(frontier, (ng + _unsat_count(ns, goal), ng,
                                      next(counter), ns, path + [gop]))
    return None


# ── offline gesture rendering ────────────────────────────────────────────────

def nudge_for(col, cur, target):
    """(mode, n_thresholds) to move a `col` cell from `cur` to `target`. Picks the
    step mode whose step divides the delta most cleanly; ties prefer coarse (fewer
    turns). Returns (mode, signed_int_thresholds)."""
    steps = COL_STEP.get(col)
    if not steps:
        return "fine", 0
    delta = float(target) - float(cur)
    best = None
    for mode in ("coarse", "fine"):
        step = steps[mode]
        n = delta / step
        err = abs(round(n) - n)
        cand = (err, abs(round(n)), mode, int(round(n)))
        if best is None or cand < best:
            best = cand
    return best[2], best[3]


def render_setcell(gop):
    """Render a set_cell instance to an offline gesture block (assuming cur=0.0)."""
    col = gop.binding["col"]
    row = int(float(gop.binding["row"]))
    target = float(gop.binding["v"])
    mode, n = nudge_for(col, 0.0, target)
    lines = ["# [live] navigate focusHead to row %d (nav-mode encoder, %d detents/row)"
             % (row, ENCODER_THRESHOLD)]
    if row:
        lines.append("turn %d   # -> row %d" % (ENCODER_THRESHOLD * row, row))
    lines.append("press ENTER   # -> modal(editingL1)")
    if mode == "coarse":
        lines.append("press DIAL1   # editStepMode -> coarse")
    turns = ENCODER_THRESHOLD * n
    lines.append("turn %d   # %d %s step(s): 0.0 -> %s (%s)"
                 % (turns, n, mode, ui_fluents.fmt_value(target), col))
    lines.append("press UP   # commit + exit edit")
    return lines


def render_gesture(gop, column_map):
    """Concrete or nominal gesture lines for a ground operator, plus a `live` flag."""
    oid = gop.op.id
    if oid == "select_column":
        col = gop.binding["col"]
        main = column_map.get(col, "MAIN?")
        return ["press %s" % main, "frames 6"], False
    if oid == "set_cell":
        return render_setcell(gop), True
    if oid == "open_picker":
        return ["press MAIN{i}   # [live] i = slot holding EmptySection.EmptyControl",
                "frames 15"], True
    if oid == "insert":
        return ["turn {3*row}   # [live] row of %r in the live picker" % gop.binding.get("u"),
                "frames 6",
                "press {MAIN1=left|MAIN4=right}   # [live] u's picker side",
                "frames 30"], True
    if oid == "focus_unit":
        return ["turn {N}   # [live] detents to %r's chain section" % gop.binding.get("u"),
                "frames 6"], True
    if oid in ("expand", "collapse"):
        return ["press {u_header_main}   # [live] MAIN holding Unit.Base.Header",
                "frames 8", "press ENTER", "frames 15"], True
    # static nav / link -> substituted gesture (e.g. link's SELECT1/SELECT2).
    return list(gop.gesture), gop.op.live


def render_plan(plan, goal, column_map, start_desc):
    out = []
    out.append("# ui_solve plan")
    out.append("# start: %s" % start_desc)
    out.append("# goal (%d fluent(s)):" % len(goal))
    for g in goal:
        out.append("#   %s" % g)
    if plan is None:
        out.append("#")
        out.append("# NO PLAN FOUND -- the goal is unreachable with the current operator")
        out.append("# library (see COVERAGE in the module docstring).")
        return "\n".join(out)
    out.append("# %d operator(s):" % len(plan))
    for i, gop in enumerate(plan.ops, 1):
        gestures, live = render_gesture(gop, column_map)
        tag = "  [live]" if live else ""
        out.append("")
        out.append("## op %d: %s%s" % (i, gop.label(), tag))
        out.append("#   pre:  %s" % " & ".join(gop.pre) if gop.pre else "#   pre:  (none)")
        out.append("#   eff:  %s" % " & ".join(gop.eff) if gop.eff else "#   eff:  (none)")
        out.extend(gestures)
    return "\n".join(out)


# ── default start state ──────────────────────────────────────────────────────

def boot_start():
    """The boot Chain.Root projection (home) as the default planning start state."""
    return ui_fluents.project(ui_fluents.BOOT_BUNDLE)


# ── live execution (--run) ───────────────────────────────────────────────────

def _import_harness():
    sys.path.insert(0, os.path.join(REPO_ROOT, "tools"))
    import emu_test
    return emu_test


def _lua_str(s):
    return "'" + str(s).replace("\\", "\\\\").replace("'", "\\'") + "'"


def _strip_instance(title):
    """Drop a trailing ' #<n>' instance suffix so a chain unit title ('Test Osc #1')
    maps to its picker catalog name ('Test Osc')."""
    return re.sub(r"\s+#\d+$", "", str(title))


class Executor:
    """Drives a fresh hermetic emu and executes a Plan with REAL gestures,
    asserting each operator's durable effect and finally satisfies(state, goal)."""

    def __init__(self, column_map, packages=None, emu_bin=None, timeout=120.0):
        self.ET = _import_harness()
        self.column_map = column_map
        self.cfg = self.ET.Config()
        if emu_bin:
            self.cfg.emu_bin = emu_bin
        self.packages = packages or ["core"]
        self.timeout = timeout
        self.emu = None
        self.sandbox = None
        self.results = []   # (label, ok|None, detail)

    # -- process lifecycle -------------------------------------------------------

    def _deadline(self):
        return self.ET._now() + self.timeout

    def start(self):
        self.sandbox, config_path = self.ET.assemble_sandbox(self.cfg, self.packages)
        self.emu = self.ET.EmuProcess(self.cfg, config_path)
        payload = self.emu.read_reply(self._deadline())
        if payload is None or (self.ET.reply_value(payload) != "ready" and payload != "ready"):
            raise RuntimeError("emu did not become ready: %r" % payload)
        self._settle(20)

    def stop(self):
        if self.emu:
            try:
                self.emu.send("quit")
                self.emu.read_reply(self.ET._now() + 5)
            except Exception:
                pass
            self.emu.kill()

    # -- low-level ---------------------------------------------------------------

    def send(self, line):
        self.emu.send(line)
        r = self.emu.read_reply(self._deadline())
        if r is None:
            raise RuntimeError("watchdog on %r" % line)
        return r

    def lua(self, expr):
        r = self.send("lua %s" % expr)
        if self.ET.reply_is_err(r):
            raise RuntimeError("lua error on %r -> %s" % (expr, r))
        return self.ET.reply_value(r)

    def truth(self, expr):
        return self.lua(expr) == "true"

    def _settle(self, n=6):
        self.send("frames %d" % n)

    # -- fluent verification (live) ---------------------------------------------

    def verify_fluent(self, fluent):
        """Evaluate a single positive goal/effect fluent against live state."""
        p = ui_fluents.parse_fluent(fluent)
        if not p:
            return False
        name, args = p
        if name == "context":
            expr = CTX_RECOGNIZE.get(args[0])
            return bool(expr) and self.truth(expr)
        if name == "column_cursor":
            idx = COLIDX.get(args[0])
            if idx is None:
                return False
            return self.truth("require('Application').getVisibleContext():top().columnCursor == %d" % idx)
        if name == "cell":
            slot, col, row = int(float(args[0])), args[1], int(float(args[2]))
            v = float(args[3])
            idx = COLIDX.get(col)
            if idx is None:
                return False
            return self.truth(
                "math.abs(app.AudioThread.getSequencerTask():l1Value(%d,%d,%d) - %r) < 1e-4"
                % (slot, idx, row, v))
        if name == "linked":
            return self.truth("tostring(require('Channels').serialize().links.link%s%s) == 'true'"
                              % (args[0], args[1]))
        if name == "focused_unit":
            return self.truth(
                "(function() local s=require('Channels').getChain(1):getSelection(); "
                "return s ~= nil and s.title == %s end)()" % _lua_str(args[0]))
        if name == "unit_in_chain":
            return self.truth(
                "(function() local c=require('Channels').getChain(1); "
                "for i=1,c:length() do local u=c:getUnit(i); "
                "if u and u.title==%s then return true end end; return false end)()"
                % _lua_str(args[0]))
        if name == "slot_control":
            return self.truth(
                "(require('emu.UIState').controlClassAt(%s)==%s or "
                "require('emu.UIState').controlNameAt(%s)==%s)"
                % (_lua_str(args[0]), _lua_str(args[1]), _lua_str(args[0]), _lua_str(args[1])))
        if name == "modal":
            return self.truth(
                "(function() for _,m in ipairs(require('emu.UIState').describe().modals) do "
                "if m==%s then return true end end return false end)()" % _lua_str(args[0]))
        return False

    def durable_effects(self, gop):
        """Positive effect fluents excluding transient modal(*) (the durable state
        an operator leaves behind; modal(editingL1) for set_cell is verified
        transiently mid-drive, not after the UP commit)."""
        out = []
        for e in gop.eff:
            p = ui_fluents.parse_fluent(e)
            if p and p[0] == "modal":
                continue
            out.append(e)
        return out

    def effects_hold(self, gop):
        return all(self.verify_fluent(e) for e in self.durable_effects(gop))

    # -- run ---------------------------------------------------------------------

    def run(self, plan, goal):
        for gop in plan.ops:
            try:
                ok, detail = self._drive(gop)
            except Exception as e:
                ok, detail = False, "exception: %s" % e
            self.results.append((gop.label(), ok, detail))
            if not ok:
                self.results.append(("  uiState @ failure", None, self._diagnostic()))
                return False
        # final goal check
        ok = all(self.verify_fluent(g) for g in goal if not g.startswith("~"))
        detail = "satisfies(goal)" if ok else "GOAL NOT satisfied; divergent: %s" % (
            [g for g in goal if not g.startswith("~") and not self.verify_fluent(g)])
        self.results.append(("FINAL satisfies(state, goal)", ok, detail))
        return ok

    def _drive(self, gop):
        oid = gop.op.id
        # Idempotence: if the operator's durable effects already hold, skip driving
        # (e.g. select_column(cv1) when the sequencer already boots on cv1 -- driving
        # MAIN1 there would enter L1 edit instead of being a no-op).
        if self.durable_effects(gop) and self.effects_hold(gop):
            return True, "already satisfied (skipped)"
        if oid in ("nav_admin_to_home", "nav_admin_to_sample_pool", "nav_home_to_admin",
                   "nav_home_to_hold", "nav_home_to_quicksave", "nav_home_to_scope",
                   "nav_home_to_unit_picker_dense", "nav_quicksave_to_home",
                   "nav_sample_pool_to_admin", "nav_scope_to_home",
                   "nav_scope_to_sequencer", "nav_unit_picker_dense_to_home", "link"):
            for gline in gop.gesture:
                self.send(gline)
            return self._check_effects(gop)
        if oid == "select_column":
            return self._select_column(gop)
        if oid == "open_picker":
            return self._open_picker(gop)
        if oid == "insert":
            return self._insert(gop)
        if oid == "focus_unit":
            return self._focus_unit(gop)
        if oid == "set_cell":
            return self._set_cell(gop)
        if oid in ("expand", "collapse"):
            return self._toggle_view(gop)
        return False, "no driver for operator %s" % oid

    def _check_effects(self, gop):
        for e in self.durable_effects(gop):
            if not self.verify_fluent(e):
                return False, "effect not reached: %s" % e
        return True, "ok"

    def _select_column(self, gop):
        col = gop.binding["col"]
        main = self.column_map.get(col)
        if not main:
            return False, "no MAIN mapping for column %s" % col
        self.send("press %s" % main)
        self._settle(6)
        return self._check_effects(gop)

    def _empty_slot(self):
        expr = ("(function() for _,c in ipairs(require('emu.UIState').describe().controls) do "
                "if c.class:find('EmptyControl',1,true) then return c.slot end end return '' end)()")
        slot = self.lua(expr)
        return int(slot[1:]) if slot.startswith("M") else None

    def _open_picker(self, gop):
        i = self._empty_slot()
        if i is None:
            return False, "no EmptySection.EmptyControl column on screen"
        self.send("press MAIN%d" % i)
        self._settle(15)
        return self._check_effects(gop)

    def _insert(self, gop):
        title = _strip_instance(gop.binding["u"])
        loc = self.lua(
            "(function() local w=require('Application').getVisibleContext():top(); "
            "for i,r in ipairs(w.rows or {}) do if r.type=='pair' then "
            "if r.left and r.left.title==%s then return (i-1)..',L' end; "
            "if r.right and r.right.title==%s then return (i-1)..',R' end "
            "end end return 'nil' end)()" % (_lua_str(title), _lua_str(title)))
        if loc == "nil":
            return False, "unit %r not present in the live picker" % title
        row_s, side = loc.split(",")
        target_row = int(row_s)
        guard = 0
        while guard < 64:
            cur = int(self.lua("require('Application').getVisibleContext():top().cursorRow"))
            if cur == target_row:
                break
            self.send("turn %d" % (ENCODER_THRESHOLD if target_row > cur else -ENCODER_THRESHOLD))
            self._settle(6)
            guard += 1
        cur = int(self.lua("require('Application').getVisibleContext():top().cursorRow"))
        if cur != target_row:
            return False, "cursor stuck at row %d (want %d)" % (cur, target_row)
        self.send("press MAIN%d" % (1 if side == "L" else 4))
        self._settle(30)
        return self._check_effects(gop)

    def _focus_unit(self, gop):
        # Closed-loop: scroll the chain SpottedStrip until the selected section
        # title matches u. (Usually skipped -- insert auto-focuses.)
        target = str(gop.binding["u"])
        guard = 0
        while guard < 64:
            if self.verify_fluent("focused_unit(%s)" % target):
                break
            self.send("turn %d" % ENCODER_THRESHOLD)
            self._settle(6)
            guard += 1
        return self._check_effects(gop)

    def _grid_field(self, field):
        return self.lua("require('Application').getVisibleContext():top().%s" % field)

    def _cell_value(self, slot, idx, row):
        return float(self.lua("app.AudioThread.getSequencerTask():l1Value(%d,%d,%d)" % (slot, idx, row)))

    def _set_cell(self, gop):
        slot = int(float(gop.binding["slot"]))
        col = gop.binding["col"]
        row = int(float(gop.binding["row"]))
        target = float(gop.binding["v"])
        idx = COLIDX.get(col)
        if idx is None:
            return False, "unknown column %s" % col

        # 0. leave any stale edit so nav-mode encoder scrolls rows.
        if self._grid_field("editingL1") == "true":
            self.send("press UP")
            self._settle(6)
        # 1. nav focusHead to `row` (nav-mode encoder, 3 detents/row), closed-loop.
        guard = 0
        while guard < 128:
            cur = int(self._grid_field("focusHeadRow"))
            if cur == row:
                break
            self.send("turn %d" % (ENCODER_THRESHOLD if row > cur else -ENCODER_THRESHOLD))
            self._settle(4)
            guard += 1
        if int(self._grid_field("focusHeadRow")) != row:
            return False, "could not reach row %d" % row
        # 2. ENTER -> editingL1 (transient modal(editingL1) proof).
        self.send("press ENTER")
        self._settle(6)
        if self._grid_field("editingL1") != "true":
            return False, "ENTER did not enter editingL1"
        # 3. closed-loop nudge to the target, dialing the step mode as needed.
        ok = self._nudge_to(slot, idx, col, row, target)
        # 4. UP commits + exits edit.
        self.send("press UP")
        self._settle(6)
        if not ok:
            return False, "could not nudge cell to %s (got %s)" % (target, self._cell_value(slot, idx, row))
        return self._check_effects(gop)

    def _nudge_to(self, slot, idx, col, row, target, max_iter=64):
        tol = 1e-4
        for _ in range(max_iter):
            cur = self._cell_value(slot, idx, row)
            if abs(cur - target) <= tol:
                return True
            mode, n = nudge_for(col, cur, target)
            if n == 0:
                # step mode can't represent the residual; try the other mode.
                other = "fine" if mode == "coarse" else "coarse"
                step = COL_STEP[col][other]
                n = int(round((target - cur) / step))
                mode = other
                if n == 0:
                    return abs(cur - target) <= tol
            if self._grid_field("editStepMode") != mode:
                self.send("press DIAL1")
                self._settle(4)
                if self._grid_field("editStepMode") != mode:
                    # only two modes; a single toggle should land it.
                    self.send("press DIAL1")
                    self._settle(4)
            self.send("turn %d" % (ENCODER_THRESHOLD * n))
            self._settle(4)
        return abs(self._cell_value(slot, idx, row) - target) <= tol

    def _toggle_view(self, gop):
        i = self.lua(
            "(function() for _,c in ipairs(require('emu.UIState').describe().controls) do "
            "if c.class=='Unit.Base.Header' then return c.slot end end return '' end)()")
        if not i.startswith("M"):
            return False, "no unit header on screen to toggle"
        self.send("press MAIN%s" % i[1:])
        self._settle(8)
        self.send("press ENTER")
        self._settle(15)
        return True, "toggled at %s" % i

    def _diagnostic(self):
        try:
            top = self.lua("require('emu.UIState').topClass()")
            ctx = self.lua("require('emu.UIState').contextName()")
            return "top=%s context=%s" % (top, ctx)
        except Exception as e:
            return "diagnostic failed: %s" % e


def do_run(operators, column_map, goal, args):
    start = parse_from(args) if args.from_state else boot_start()
    plan = solve(operators, start, goal)
    print(render_plan(plan, goal, column_map,
                      "--from" if args.from_state else "boot(home)"))
    if plan is None:
        print("\nRUN FAILED (no plan)")
        return 1
    print("\n# -- executing against the headless emu --")
    ex = Executor(column_map, packages=args.packages, emu_bin=args.emu_bin)
    ok_all = False
    try:
        ex.start()
        ok_all = ex.run(plan, goal)
    finally:
        for label, ok, detail in ex.results:
            if ok is None:
                print("     %s" % detail)
            else:
                print("  [%s] %s -- %s" % ("PASS" if ok else "FAIL", label, detail))
        ex.stop()
        if ex.sandbox and not os.environ.get("STOL_KEEP_SANDBOX"):
            import shutil
            shutil.rmtree(ex.sandbox, ignore_errors=True)
    print("\n%s" % ("RUN OK" if ok_all else "RUN FAILED"))
    return 0 if ok_all else 1


# ── selftest (offline planning correctness; no emu) ──────────────────────────

def selftest():
    operators, column_map = load_operators()
    failures = []

    def check(cond, msg):
        print("  [%s] %s" % ("PASS" if cond else "FAIL", msg))
        if not cond:
            failures.append(msg)

    def ids(plan):
        return [g.op.id for g in plan.ops]

    print("ui_solve.py --selftest (classical planning vs merged operator library)")

    # -- merge sanity ------------------------------------------------------------
    check(len(operators) == 20, "merged library has 20 operators")
    check("modal(editingL1)" in operators["set_cell"].eff,
          "set_cell effect merged modal(editingL1) from ui-crawl.map [[resolved]]")
    check(operators["set_cell"].gesture[:1] == ["press ENTER"],
          "set_cell gesture skeleton comes from the resolved crawl block")
    check(operators["open_picker"].live and operators["set_cell"].live,
          "open_picker + set_cell are marked live (needs_crawl)")

    # -- 1. home -> admin : a single nav operator --------------------------------
    plan = solve(operators, boot_start(), ui_fluents.parse_goal("context(admin)"))
    check(ids(plan) == ["nav_home_to_admin"], "home->admin is one nav op: %s" % ids(plan))

    # -- 2. home -> sequencer : two-hop nav via scope ----------------------------
    plan = solve(operators, boot_start(), ui_fluents.parse_goal("context(sequencer)"))
    check(ids(plan) == ["nav_home_to_scope", "nav_scope_to_sequencer"],
          "home->sequencer routes via scope: %s" % ids(plan))

    # -- 3. the C3 headline plan skeleton ----------------------------------------
    c3_goal = ui_fluents.parse_goal(
        "context(sequencer)\ncolumn_cursor(cv1)\n" +
        "\n".join("cell(0,cv1,%d,3.0)" % r for r in range(6)))
    plan = solve(operators, boot_start(), c3_goal)
    check(plan is not None, "C3 goal is solvable")
    got = ids(plan)
    expect = (["nav_home_to_scope", "nav_scope_to_sequencer", "select_column"]
              + ["set_cell"] * 6)
    check(got == expect, "C3 plan = nav,nav,select_column,6x set_cell: %s" % got)
    # set_cell instances are ordered by (slot,col,row,v) -> rows 0..5.
    setrows = [int(float(g.binding["row"])) for g in plan.ops if g.op.id == "set_cell"]
    check(setrows == list(range(6)), "C3 set_cell rows are 0..5 in order: %s" % setrows)
    # each set_cell value binds to 3.0.
    check(all(abs(float(g.binding["v"]) - 3.0) < 1e-9
              for g in plan.ops if g.op.id == "set_cell"), "C3 set_cell values all 3.0")
    # the C3 nudge model: cv1 3.0 from 0 = 3 coarse octave-steps (turn 9).
    mode, n = nudge_for("cv1", 0.0, 3.0)
    check((mode, n) == ("coarse", 3), "nudge cv1 0->3.0 = 3 coarse steps (turn 9)")
    check(nudge_for("tr", 0.0, 1.0) == ("fine", 1), "nudge tr 0->1.0 = 1 fine step (turn 3)")

    # -- 4. link + insert + focus (the hermetic core-unit goal) ------------------
    li_goal = ui_fluents.parse_goal(
        "linked(1,2)\nunit_in_chain(Test Osc #1)\nfocused_unit(Test Osc #1)")
    plan = solve(operators, boot_start(), li_goal)
    check(plan is not None, "link+insert+focus goal is solvable")
    got = ids(plan)
    check(got == ["link", "open_picker", "insert"],
          "link+insert plan = link, open_picker, insert: %s" % got)
    ins = [g for g in plan.ops if g.op.id == "insert"][0]
    check(ins.binding["u"] == "Test Osc #1", "insert binds u=Test Osc #1")
    check(_strip_instance("Test Osc #1") == "Test Osc", "picker catalog name strips #1")
    lk = [g for g in plan.ops if g.op.id == "link"][0]
    check(lk.eff == ["linked(1,2)"], "link effect is linked(1,2)")
    check(lk.gesture[0] == "down SELECT1",
          "link's {a}/{b} substitute to the SELECT1+SELECT2 chord")

    # -- 5. adjacency guard in link precondition ---------------------------------
    plan = solve(operators, boot_start(), ui_fluents.parse_goal("linked(1,3)"))
    check(plan is None, "non-adjacent linked(1,3) is unplannable (adjacent guard)")

    # -- 6. select_column suppressed when already satisfied ----------------------
    seq_state = frozenset(ui_fluents.parse_goal(
        "context(sequencer)\ncolumn_cursor(cv1)\nfocused_class(Sequencer.GridView)"))
    plan = solve(operators, seq_state, ui_fluents.parse_goal("column_cursor(cv1)"))
    check(ids(plan) == [], "column_cursor(cv1) already holds -> empty plan")
    plan = solve(operators, seq_state, ui_fluents.parse_goal("column_cursor(tr)"))
    check(ids(plan) == ["select_column"], "switching to tr needs one select_column")

    # -- 7. deterministic / reproducible plans -----------------------------------
    a = solve(operators, boot_start(), c3_goal)
    b = solve(operators, boot_start(), c3_goal)
    check([g.key() for g in a.ops] == [g.key() for g in b.ops],
          "planning is deterministic (identical ground-op sequence)")

    # -- 8. already-satisfied goal -> empty plan ---------------------------------
    plan = solve(operators, boot_start(), ui_fluents.parse_goal("context(home)"))
    check(ids(plan) == [], "context(home) already holds at boot -> empty plan")

    print()
    if failures:
        print("SELFTEST FAILED: %d check(s)" % len(failures))
        return 1
    print("SELFTEST OK")
    return 0


# ── cli ──────────────────────────────────────────────────────────────────────

def parse_from(args):
    text = open(args.from_state).read() if os.path.exists(args.from_state) else args.from_state
    return ui_fluents.parse_goal(text)


def parse_goal_arg(args):
    if args.goal_file:
        with open(args.goal_file) as f:
            return ui_fluents.parse_goal(f.read())
    if args.goal:
        return ui_fluents.parse_goal(args.goal)
    raise SystemExit("provide --goal '<fluents>' or --goal-file PATH")


def main(argv):
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--goal", help="partial fluent goal (JSON array or newline/;-list)")
    p.add_argument("--goal-file", help="goal from a file")
    p.add_argument("--from", dest="from_state", default=None,
                   help="start fluent set (file or inline); default = boot(home)")
    p.add_argument("--run", action="store_true",
                   help="assemble a sandbox, drive the emu, and verify the plan")
    p.add_argument("--selftest", action="store_true",
                   help="offline planning correctness (no emu)")
    p.add_argument("--operators", default=DEFAULT_OPERATORS)
    p.add_argument("--crawl", default=DEFAULT_CRAWL)
    p.add_argument("--packages", nargs="*", default=["core"],
                   help="(--run) packages to stage into the sandbox")
    p.add_argument("--emu-bin", default=None)
    args = p.parse_args(argv[1:])

    if args.selftest:
        return selftest()

    operators, column_map = load_operators(args.operators, args.crawl)
    goal = parse_goal_arg(args)
    if args.run:
        return do_run(operators, column_map, goal, args)

    start = parse_from(args) if args.from_state else boot_start()
    plan = solve(operators, start, goal)
    print(render_plan(plan, goal, column_map,
                      "--from" if args.from_state else "boot(home)"))
    return 0 if plan is not None else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

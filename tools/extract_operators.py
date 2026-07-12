#!/usr/bin/env python3
# [stol:ui-planner-operators]
#
# extract_operators.py: the TYPED OPERATOR LIBRARY extractor for the ER-301 UI
# planning domain (planning/ui-planning-domain-plan.md §4). Lifts the ui-map edges
# and the ui-model manifest / ui_plan goal-types into a DETERMINISTIC, SORTED
# operator catalog (testing-assets/emu/ui-operators.toml).
#
# An OPERATOR models one composable action of the UI as a classical planning
# operator:
#
#     (precondition fluents)  --[gesture template]-->  (effect fluents)
#
# Fluents are written against the SHARED fluent vocabulary (documented by the
# schema sibling in docs/UI_STATE_SCHEMA.md; the [fluents] table below pins the
# exact names + arities this file emits). Preconditions may carry `~` negation and
# parameter placeholders (e.g. `linked(a,b)`, `~column_cursor(col)`). Gestures are
# control-protocol templates (planning/headless-emu-plan.md §2) with `{param}`
# substitution; `{col_main}` for select_column resolves through [column_map].
#
# PROVENANCE (the `source` field):
#   * map      — a verified context-navigation edge from testing-assets/emu/ui-map.toml
#                (one nav_<from>_to_<to> operator per edge, gesture = the edge's
#                control-protocol sequence; endpoints are the raw ui-map node
#                names verbatim, matching the state-schema projection).
#   * ui_plan  — a composable action from tools/ui_plan.py's goal-types (link,
#                open_picker, insert, focus_unit) with its known gesture template.
#   * manifest — a firmware/structure action justified by a class in
#                testing-assets/emu/ui-model.manifest (Sequencer.GridView for
#                select_column/set_cell; the per-unit expanded/collapsed view lists
#                for expand/collapse).
#
# HONESTY (the `verified` field): only operators whose target + precondition are
# STATICALLY resolvable are `static`. The ~93% of manifest handler targets are
# `dynamic`, so any operator whose gesture or precondition depends on live,
# channel-count-filtered or unit-specific state is `needs_crawl` — a later crawler
# fills the remainder rather than this pass guessing.
#
# DETERMINISM: operators are sorted by id, keys emitted in a fixed order, no paths
# / timestamps. Regenerating the static subset on an unchanged tree is a
# byte-identical no-op — the `scripts/dev ui-operators` gate diffs against the
# committed testing-assets/emu/ui-operators.toml baseline.
#
# Usage:
#   python3 tools/extract_operators.py            # write the baseline in place
#   python3 tools/extract_operators.py -o PATH    # write elsewhere
#   python3 tools/extract_operators.py --stdout   # print to stdout (no write)

import argparse
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_MAP = os.path.join(REPO_ROOT, "testing-assets/emu/ui-map.toml")
DEFAULT_MANIFEST = os.path.join(REPO_ROOT, "testing-assets/emu/ui-model.manifest")
DEFAULT_GRIDVIEW = os.path.join(REPO_ROOT, "xroot/Sequencer/GridView.lua")
DEFAULT_OUT = os.path.join(REPO_ROOT, "testing-assets/emu/ui-operators.toml")

SCHEMA_VERSION = 1

# ── shared fluent vocabulary (CONTRACT: keep names + arities identical to the
# schema sibling, docs/UI_STATE_SCHEMA.md) ────────────────────────────────────
# `adjacent(a,b)` is a static domain predicate (channel a,b are neighbours, a<b);
# it only ever appears as a precondition, never an effect.
FLUENTS = {
    "adjacent": 2,
    "cell": 4,
    "column_cursor": 1,
    "context": 1,
    "focused_class": 1,
    "focused_unit": 1,
    "linked": 2,
    "modal": 1,
    "slot_control": 2,
    "unit_in_chain": 1,
}

# Context node names are the raw ui-map.toml node names, verbatim, so that
# `context(<node>)` fluents match the state-schema projection (tools/ui_fluents.py,
# which maps top-window-class -> ui-map node) exactly — otherwise the solver could
# not chain a nav operator's effect into another operator's precondition. No
# canonicalization: unit_picker_dense stays unit_picker_dense (distinct from
# unit_picker_classic). Reconciled with ui-planner-state-schema 2026-07-10.
CANON_NODE = {}


# ── inputs ────────────────────────────────────────────────────────────────────

def load_map(path):
    try:
        import tomllib
    except ImportError as e:  # pragma: no cover
        raise SystemExit("extract_operators.py needs Python 3.11+ (tomllib): %s" % e)
    with open(path, "rb") as f:
        return tomllib.load(f)


def load_manifest_classes(path):
    """Return the set of class keys present in the manifest (for provenance
    cross-checks). Stdlib json; the manifest is generated + committed."""
    import json
    if not os.path.exists(path):
        return set()
    with open(path, "r") as f:
        data = json.load(f)
    return set(data.get("classes", {}).keys())


RE_COLNAMES = re.compile(r"local\s+kColNames\s*=\s*\{([^}]*)\}")
RE_QUOTED = re.compile(r'"([^"]*)"')


def load_columns(path):
    """Lift the sequencer column names from GridView.lua's kColNames table, in
    display order. Whitespace-padded names (e.g. "tr ") are stripped. The column
    index (0-based position) drives both the column_cursor fluent value and the
    MAIN button select_column presses (MAIN<index+1>)."""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    m = RE_COLNAMES.search(text)
    if not m:
        raise SystemExit("could not find kColNames in %s" % path)
    cols = [c.strip() for c in RE_QUOTED.findall(m.group(1))]
    if not cols:
        raise SystemExit("kColNames parsed empty in %s" % path)
    return cols


# ── operator model ────────────────────────────────────────────────────────────

class Op:
    __slots__ = ("id", "source", "verified", "params", "pre", "eff", "gesture",
                 "note", "eff_from")

    def __init__(self, id, source, verified, params, pre, eff, gesture, note=None,
                 eff_from=None):
        self.id = id
        self.source = source
        self.verified = verified
        self.params = params
        self.pre = pre
        self.eff = eff
        self.gesture = gesture
        self.note = note
        # [stol:ui-planner-cov-views] MANIFEST-VIEW-DERIVED effect marker. When set
        # (expand/collapse only), the operator's concrete slot_control(Mi,ctrl)
        # effect is NOT literal in `eff` but resolved PER-UNIT at plan time from the
        # target view's slot list (ui_solve.py binds u -> the manifest units[u]
        # /crawl-proof view map). `eff` stays empty; this names the target view.
        self.eff_from = eff_from


# ── context-nav operators (source=map) ────────────────────────────────────────

def nav_operators(uimap):
    ops = []
    for e in uimap.get("edge", []):
        frm = CANON_NODE.get(e["from"], e["from"])
        to = CANON_NODE.get(e["to"], e["to"])
        ops.append(Op(
            id="nav_%s_to_%s" % (frm, to),
            source="map",
            verified="static",  # every edge is "high (verified live)" in the map
            params=[],
            pre=["context(%s)" % frm],
            eff=["context(%s)" % to],
            gesture=list(e["gesture"]),
        ))
    return ops


# ── action operators (source=ui_plan | manifest) ──────────────────────────────

def link_chord_template():
    """The stereo-link SELECT chord over an adjacent pair (a<b), as tools/ui_plan.py
    Planner.link_chord emits it and tests/emu/53-ui-plan-core-insert.test pins it."""
    return [
        "down SELECT{a}", "frames 6",
        "down SELECT{b}", "frames 6",
        "up SELECT{b}", "up SELECT{a}", "frames 10",
    ]


def action_operators(manifest_classes, columns):
    ops = []

    def has(cls):
        return cls in manifest_classes

    # link(a,b) — deterministic chord; effect fully known (ui_plan + 53-test).
    ops.append(Op(
        id="link",
        source="ui_plan",
        verified="static",
        params=["a", "b"],
        pre=["context(home)", "adjacent(a,b)", "~linked(a,b)"],
        eff=["linked(a,b)"],
        gesture=link_chord_template(),
        note="Hold SELECT<a>, tap SELECT<b> (UserMode selectPressed). Both chains "
             "empty -> links with no dialog; context unchanged.",
    ))

    # open_picker — opens the dense chooser by pressing the EmptyControl column.
    # The COLUMN is precondition-dependent (M3 on an empty mono chain, M4 after a
    # stereo link adds a second input spot), so the nominal MAIN3 gesture + the
    # slot_control precondition are crawler-refined.
    empty_note = ("Nominal MAIN3 = the empty-insert column on a mono chain; after a "
                  "stereo link it shifts to M4 (CRAWLER-REFINED: press whichever "
                  "column holds EmptySection.EmptyControl).")
    if has("EmptySection.EmptyControl"):
        empty_note += (" Justified by manifest EmptySection.EmptyControl "
                       "enterReleased/subReleased -> chooser:open.")
    ops.append(Op(
        id="open_picker",
        source="ui_plan",
        verified="needs_crawl",
        params=[],
        pre=["context(home)", "slot_control(M3,EmptySection.EmptyControl)"],
        eff=["context(unit_picker_dense)"],
        gesture=["press MAIN3", "frames 12"],
        note=empty_note,
    ))

    # insert(u) — choose a unit from the open picker. Returns to home focused on
    # the freshly inserted, expanded unit. The row-nav + pick side are live.
    ops.append(Op(
        id="insert",
        source="ui_plan",
        verified="needs_crawl",
        params=["u"],
        pre=["context(unit_picker_dense)"],
        eff=["unit_in_chain(u)", "focused_unit(u)", "context(home)"],
        gesture=["press MAIN1", "frames 30"],
        note="CRAWLER-REFINED: prefix with `turn N` to land the cursor on u's row "
             "(N = 3 raw detents/row) and pick MAIN1 (left) / MAIN4 (right) per u's "
             "cell in the live, channel-count-filtered, sorted picker list.",
    ))

    # [stol:ui-planner-cov-focus]
    # insert_after(u) — open the dense picker on a NON-empty chain. After the first
    # insert, ChainBase:loadUnit removes the empty insert section (xroot/Chain/
    # Base.lua ~L458), so open_picker / nav_home_to_unit_picker_dense (both keyed on
    # the empty-insert column) are dead and a 2nd unit could never be inserted. But
    # every unit's view carries its OWN Chain.InsertControl at view-slot vc[1], BEFORE
    # the header (xroot/Unit/Section.lua:13), which opens the SAME dense chooser
    # (goal="insert") relative to that unit. Reveal it by scrolling the chain cursor
    # left to the focused unit's insert spot, then ENTER (Chain.InsertControl:
    # enterReleased -> activateChooser). This is the ONLY operator that opens the
    # picker on a non-empty chain, so it is what makes a MULTI-unit chain (and hence
    # focus_unit, which needs >=2 units to re-focus a non-last one) reachable.
    ops.append(Op(
        id="insert_after",
        source="ui_plan",
        verified="needs_crawl",
        params=["u"],
        pre=["context(home)", "focused_unit(u)"],
        eff=["context(unit_picker_dense)"],
        gesture=["press ENTER", "frames 15"],
        note="[stol:ui-planner-cov-focus] Open the dense picker on a NON-empty chain "
             "via the focused unit u's Chain.InsertControl (xroot/Unit/Section.lua:13, "
             "vc[1] before the header). CRAWLER-REFINED: reveal the insert control by "
             "scrolling the chain SpottedStrip cursor LEFT to u's insert spot "
             "(getSelectedSpotIndex == 0; after `insert`/`focus_unit` the cursor "
             "auto-lands there), then ENTER fires Chain.InsertControl:enterReleased -> "
             "activateChooser(goal=\"insert\"). Unlike open_picker (keyed on the "
             "empty-insert column that loadUnit drops on the first insert), this works "
             "when the chain already holds units, so the 2nd+ insert routes through it. "
             "Justified by manifest Chain.InsertControl enterReleased -> chooser:open.",
    ))

    # focus_unit(u) — scroll the chain focus onto an already-inserted unit.
    ops.append(Op(
        id="focus_unit",
        source="ui_plan",
        verified="needs_crawl",
        params=["u"],
        pre=["context(home)", "unit_in_chain(u)"],
        eff=["focused_unit(u)"],
        gesture=["turn 3", "frames 6"],
        note="CRAWLER-REFINED: encoder-scroll the chain SpottedStrip to u's section; "
             "detent count depends on u's live position in the chain.",
    ))

    # select_column(col) — press the column's MAIN button in the grid sequencer.
    # STATIC: the col->MAIN mapping is GridView:mainReleased (columnCursor=i-1).
    # Guard ~column_cursor(col): pressing the already-focused column edits instead.
    ops.append(Op(
        id="select_column",
        source="manifest",
        verified="static",
        params=["col"],
        pre=["context(sequencer)", "~column_cursor(col)"],
        eff=["column_cursor(col)"],
        gesture=["press {col_main}", "frames 6"],
        note="Resolve {col_main} via [column_map][col]. GridView:mainReleased(i) "
             "sets columnCursor=i-1 for a non-focused column; the same button on "
             "the focused column instead enters edit (hence ~column_cursor(col)).",
    ))

    # set_cell(slot,col,row,v) — write an L1 cell value in the grid sequencer.
    setcell_note = ("Gesture: encoder-scroll focusHead to `row` (nav mode), ENTER -> "
                    "editingL1, encoder-nudge to `v` (per-column step). CRAWLER-"
                    "REFINED: row + nudge counts are dynamic. Direct-write equivalent "
                    "used in tests: seq:setL1(slot,col,row,v) / seq:l1Value(...).")
    if has("Sequencer.GridView"):
        setcell_note += " Justified by manifest Sequencer.GridView (grid L1 editing)."
    ops.append(Op(
        id="set_cell",
        source="manifest",
        verified="needs_crawl",
        params=["slot", "col", "row", "v"],
        pre=["context(sequencer)", "column_cursor(col)"],
        eff=["cell(slot,col,row,v)"],
        gesture=["press ENTER", "turn 3", "frames 6"],
        note=setcell_note,
    ))

    # [stol:ui-planner-cov-views]
    # expand(u) / collapse(u) — toggle the focused unit's view by pressing its
    # header spot. The EFFECT is a unit-specific slot_control remap (expanded ->
    # M1=header, M2=expanded[1], ...). It is UNIT-PARAMETRIC, so it is NOT written
    # literally in `eff`; instead we emit a machine-readable `eff_from` marker
    # naming the TARGET VIEW ("manifest.views.expanded" / ".collapsed"). ui_solve
    # binds u and grounds the concrete slot_control(Mi,ctrl) add/remove set from
    # that unit's per-view slot list at plan time (added = target-view slots,
    # removed = the other view's), then --run drives the resolved header-MAIN +
    # ENTER toggle and asserts the resulting map.
    for opid, verb in (("expand", "expanded"), ("collapse", "collapsed")):
        ops.append(Op(
            id=opid,
            source="manifest",
            verified="needs_crawl",
            params=["u"],
            pre=["context(home)", "focused_unit(u)"],
            eff=[],
            eff_from="manifest.views.%s" % verb,
            gesture=["press {u_header_main}", "frames 15"],
            note="Press u's header spot (the MAIN column whose control is "
                 "Unit.Base.Header) then ENTER to toggle to the %s view. The effect "
                 "is the UNIT-PARAMETRIC slot_control map named by `eff_from` "
                 "(u's per-view slot list, manifest units[u].views.%s, made concrete "
                 "by the crawl-proof exemplar); ui_solve grounds it per-unit and "
                 "{u_header_main} is the live header column." % (verb, verb),
        ))

    return ops


# ── durable-modal operators (source=manifest) ─────────────────────────────────
# [stol:ui-planner-cov-modals]
# The `modal` fluent type is otherwise uncovered: the only modeled modal is
# set_cell's TRANSIENT modal(editingL1) (stripped as non-durable — you never route
# TO an in-edit transient). But some modals ARE durable end-states an agent would
# target. This function emits those as first-class operators (pre = the context the
# modal lives in; eff = the durable modal fluent; gesture = crawler-refined).
#
# DURABLE + DISTINGUISHABLE + REACHABLE, so modeled here:
#   * build_selection -> modal(selectionActive). Nav-mode shift+encoder on the grid
#     sequencer builds a row-range selection on the focused column
#     (xroot/Sequencer/GridView.lua GridView:encoder, `self.selectionActive = true`).
#     self.selectionActive INITIALIZES false, so modal(selectionActive) is ABSENT
#     idle and present only after the gesture — a clean, distinguishable fluent
#     boundary. It persists (durable) until UP/CANCEL/column-change; non-destructive
#     (just a highlighted row-range; the bulk edit is a later, separate gesture).
#
# REJECTED durable modals (documented, NOT faked — they stay out of the coverage
# denominator alongside the transient modal(editingL1)):
#   * modal(markingMode) — Sequencer.GridView S2 (subReleased 2) enters mark mode
#     (`self.markingMode = "marking_end"`), a durable modal. But its idle value is
#     the STRING "idle" (Lua truthy) and UIState scans obj[flag] for PRESENCE, so
#     modal(markingMode) reads truthy at EVERY Sequencer.GridView state (the quirk
#     documented in docs/UI_STATE_SCHEMA.md). A goal {context(sequencer),
#     modal(markingMode)} is therefore satisfied by nav ALONE and pressing S2
#     crosses no fluent boundary — the operator could never be exercised by its own
#     goal and the crawl would see no modal delta. Non-distinguishable → excluded.
#   * modal(favoritesEditMode) — Unit.Chooser SHIFT (Chooser:shiftReleased ->
#     toggleFavoritesEditMode) enters favorites-tagging mode, durable. But
#     toggleFavoritesEditMode is a NO-OP in the dense picker (`if self.style ==
#     "dense" then return end`), and the hermetic sandbox forces pickerStyle=dense
#     (testing-assets/emu/fixtures/rear/settings.lua). The classic chooser that owns
#     the gesture is context(unit_picker_classic), which the ui-map has NO nav edge
#     to (it is a SAFE_RESTRICTED crawl screen). Unreachable in the modeled domain →
#     excluded.
def modal_operators(manifest_classes):
    ops = []

    def has(cls):
        return cls in manifest_classes

    # build_selection — nav-mode shift+encoder builds a durable row-range selection.
    sel_note = ("Nav-mode shift+encoder on the grid sequencer builds a row-range "
                "selection on the focused column (GridView:encoder shifted branch: "
                "`self.selectionActive = true`). DURABLE — persists until "
                "UP/CANCEL/column-change; non-destructive (a highlighted range; the "
                "bulk-edit nudge is a later, separate gesture). ~modal(selectionActive) "
                "guards re-entry. CRAWLER-REFINED: the gesture skeleton + driven "
                "modal-boundary proof come from ui-crawl.map [[resolved]].")
    if has("Sequencer.GridView"):
        sel_note += " Justified by manifest Sequencer.GridView (grid selection modal)."
    ops.append(Op(
        id="build_selection",
        source="manifest",
        verified="needs_crawl",
        params=[],
        pre=["context(sequencer)", "~modal(selectionActive)"],
        eff=["modal(selectionActive)"],
        gesture=["down SHIFT", "turn 3", "up SHIFT", "frames 6"],
        note=sel_note,
    ))

    return ops


# ── deterministic TOML emission ───────────────────────────────────────────────

def q(s):
    """Quote a string as a TOML basic string."""
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def arr(items):
    """A single-line TOML array of quoted strings."""
    return "[" + ", ".join(q(x) for x in items) + "]"


HEADER = (
    "# ER-301 (stolmine) UI planning domain — TYPED OPERATOR LIBRARY.\n"
    "#\n"
    "# GENERATED by tools/extract_operators.py [stol:ui-planner-operators]; do NOT\n"
    "# hand-edit. Regenerate + gate with `scripts/dev ui-operators`\n"
    "# (STOL_UPDATE_UI_OPERATORS=1 accepts drift). Deterministic: sorted by id,\n"
    "# byte-identical on an unchanged tree.\n"
    "#\n"
    "# Each [[operator]] = (pre fluents) --[gesture]--> (eff fluents). Fluents use\n"
    "# the shared vocabulary in [fluents] (arity per name); `~` negates a\n"
    "# precondition; {param} / {col_main} are gesture-template substitutions.\n"
    "# `verified = static` means statically resolvable; `needs_crawl` means a live\n"
    "# crawler must refine the gesture/precondition/effect (see each `note`).\n"
    "# ─────────────────────────────────────────────────────────────────────────────\n"
)


def emit(ops, columns):
    by_source = {}
    by_verified = {}
    for o in ops:
        by_source[o.source] = by_source.get(o.source, 0) + 1
        by_verified[o.verified] = by_verified.get(o.verified, 0) + 1

    lines = [HEADER.rstrip("\n"), ""]

    # [meta]
    lines.append("[meta]")
    lines.append("schema = %d" % SCHEMA_VERSION)
    lines.append("generator = %s" % q("tools/extract_operators.py"))
    lines.append("total = %d" % len(ops))
    lines.append("sources = %s" % arr(sorted(by_source)))
    lines.append("")
    lines.append("[meta.by_source]")
    for k in sorted(by_source):
        lines.append("%s = %d" % (k, by_source[k]))
    lines.append("")
    lines.append("[meta.by_verified]")
    for k in sorted(by_verified):
        lines.append("%s = %d" % (k, by_verified[k]))
    lines.append("")

    # [fluents] — the CONTRACT vocabulary (name = arity).
    lines.append("# Shared fluent vocabulary (name = arity). Must match the schema")
    lines.append("# sibling (docs/UI_STATE_SCHEMA.md). `adjacent` is a static domain")
    lines.append("# predicate used only in preconditions.")
    lines.append("[fluents]")
    for k in sorted(FLUENTS):
        lines.append("%s = %d" % (k, FLUENTS[k]))
    lines.append("")

    # [column_map] — col name -> MAIN button, lifted from GridView kColNames.
    lines.append("# Grid-sequencer column -> MAIN button (from xroot/Sequencer/")
    lines.append("# GridView.lua kColNames). Resolves select_column's {col_main}.")
    lines.append("[column_map]")
    for i, c in enumerate(columns):
        lines.append("%s = %s" % (c, q("MAIN%d" % (i + 1))))
    lines.append("")

    # [[operator]] — sorted by id, fixed key order.
    for o in sorted(ops, key=lambda x: x.id):
        lines.append("[[operator]]")
        lines.append("id = %s" % q(o.id))
        lines.append("source = %s" % q(o.source))
        lines.append("verified = %s" % q(o.verified))
        lines.append("params = %s" % arr(o.params))
        lines.append("pre = %s" % arr(o.pre))
        lines.append("eff = %s" % arr(o.eff))
        if o.eff_from:
            lines.append("eff_from = %s" % q(o.eff_from))
        lines.append("gesture = %s" % arr(o.gesture))
        if o.note:
            lines.append("note = %s" % q(o.note))
        lines.append("")

    return "\n".join(lines).rstrip("\n") + "\n"


# ── build ─────────────────────────────────────────────────────────────────────

def build(map_path=DEFAULT_MAP, manifest_path=DEFAULT_MANIFEST,
          gridview_path=DEFAULT_GRIDVIEW):
    uimap = load_map(map_path)
    manifest_classes = load_manifest_classes(manifest_path)
    columns = load_columns(gridview_path)
    ops = (nav_operators(uimap) + action_operators(manifest_classes, columns)
           + modal_operators(manifest_classes))  # [stol:ui-planner-cov-modals]
    return emit(ops, columns)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Extract the UI-planning operator library.")
    ap.add_argument("-o", "--output", default=DEFAULT_OUT,
                    help="write the operator TOML to PATH (default: the committed baseline)")
    ap.add_argument("--stdout", action="store_true",
                    help="print to stdout instead of writing")
    ap.add_argument("--map", default=DEFAULT_MAP)
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    ap.add_argument("--gridview", default=DEFAULT_GRIDVIEW)
    args = ap.parse_args(argv)

    text = build(args.map, args.manifest, args.gridview)
    if args.stdout:
        sys.stdout.write(text)
    else:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(text)
        sys.stderr.write("wrote %d bytes to %s\n" % (len(text), args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())

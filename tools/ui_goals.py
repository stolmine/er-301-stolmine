#!/usr/bin/env python3
"""ui_goals.py -- the example-goal CORPUS runner + coverage metric for the
ER-301 UI planning domain.

[stol:ui-planner-goal-corpus]  The FINAL layer of the ui-planner cluster
(planning/ui-planning-domain-plan.md §6). The lower layers -- the fluent schema
(tools/ui_fluents.py), the operator library (testing-assets/emu/ui-operators.toml
+ ui-crawl.map), and the SOLVER (tools/ui_solve.py) -- are all on develop. This
layer freezes a CORPUS of worked goal examples that are simultaneously:

  * WORKED EXAMPLES an agent can consult: each goal ships its offline PLAN (the
    operator-instance sequence ui_solve produces) and, from a live `--run`, its
    frame-stripped context/stack TRACE.
  * REGRESSION GOLDENS: the plan + trace are committed and byte-diffed, so a
    change to the operator library / solver that silently reroutes a goal is
    caught.
  * a COVERAGE METRIC the ledger tracks: which of the 20 operators and which of
    the 9 goal-fluent TYPES are exercised by >=1 corpus goal, as a single
    headline number that grows monotonically as goals are added.

The corpus lives in testing-assets/emu/goals/ -- one `<name>.goal` per goal (a
fluent set with a `#` description header, the same syntax ui_solve/ui_fluents
parse), beside its `<name>.plan` and `<name>.trace` goldens. Everything is
DETERMINISTIC (sorted, no timestamps/paths), so goldens are byte-reproducible.

This module does NOT re-implement planning or driving: it IMPORTS ui_solve and
reuses solve()/Executor verbatim (the trace half also reuses emu_test's
frame-strip). It never edits ui_solve.py or any sibling tool.

Stdlib only. Usage:
  tools/ui_goals.py --check-plans      offline: solve each goal, diff <name>.plan
  tools/ui_goals.py --coverage         offline: emit/compare goal-coverage.txt
  tools/ui_goals.py --run [NAME...]    drive the emu per goal; assert satisfies +
                                       diff <name>.trace
  tools/ui_goals.py --list             list the corpus goals + their plans

  STOL_UPDATE_GOALS=1  regenerate goldens (plans / coverage / traces) in place.

The FAST offline half (--check-plans + --coverage) is the per-commit gate
(`scripts/dev goal-corpus`); the slow --run half (one emu boot per goal) is the
tests/emu suite + an explicit `scripts/dev goal-corpus --run`.
"""

import argparse
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "tools"))
import ui_fluents   # noqa: E402  (sibling module, stdlib-only)
import ui_solve      # noqa: E402  (the solver -- imported, never modified)

GOALS_DIR = os.path.join(REPO_ROOT, "testing-assets/emu/goals")
COVERAGE_FILE = os.path.join(REPO_ROOT, "testing-assets/emu/goal-coverage.txt")

# The 9 goal-fluent TYPES an agent may put in a goal (the ui_fluents vocabulary;
# `adjacent` is a precondition-only domain predicate, never a goal fluent).
FLUENT_TYPES = [
    "cell", "column_cursor", "context", "focused_class", "focused_unit",
    "linked", "modal", "slot_control", "unit_in_chain",
]

# Why an operator can end up uncovered by ANY boot-start goal. Printed beside
# each currently-uncovered operator so the coverage gap is self-documenting; an
# operator that later gains a goal simply moves to the covered list.
UNCOVERED_OP_WHY = {
    "collapse": "prose view-map effect (slot_control map), not a concrete fluent -- unplannable as a goal",
    "expand": "prose view-map effect (slot_control map), not a concrete fluent -- unplannable as a goal",
    "focus_unit": "focused_unit(u) is auto-produced by insert; on a boot start no unit pre-exists to re-focus",
    "nav_admin_to_home": "effect context(home) is the boot START; A* never routes back to it",
    "nav_scope_to_home": "effect context(home) is the boot START; A* never routes back to it",
    "nav_quicksave_to_home": "effect context(home) is the boot START; A* never routes back to it",
    "nav_unit_picker_dense_to_home": "effect context(home) is the boot START; A* never routes back to it",
    "nav_sample_pool_to_admin": "context(admin) is reached in 1 op (nav_home_to_admin), so A* never routes via sample_pool",
}

# Why a goal-fluent TYPE can end up uncovered.
UNCOVERED_TYPE_WHY = {
    "slot_control": "only expand/collapse produce a slot map, and that effect is prose (unmodeled)",
    "modal": "modal(editingL1) is set_cell's transient effect, stripped as non-durable -- not a stable goal",
    "focused_class": "not an effect of any modeled operator (nav ops set only context)",
}


def _updating():
    return os.environ.get("STOL_UPDATE_GOALS") == "1"


# ── corpus discovery + loading ───────────────────────────────────────────────

def discover_goals():
    """Sorted list of corpus goal names (basenames of goals/*.goal)."""
    if not os.path.isdir(GOALS_DIR):
        return []
    return sorted(
        os.path.splitext(fn)[0]
        for fn in os.listdir(GOALS_DIR)
        if fn.endswith(".goal")
    )


def goal_path(name, ext):
    return os.path.join(GOALS_DIR, "%s.%s" % (name, ext))


def load_goal(name):
    """Parse `<name>.goal` -> the sorted, canonical fluent list (comments/blanks
    ignored, same contract as ui_fluents.parse_goal).

    Full-line `#` comments are stripped FIRST so a description header may contain
    any punctuation -- notably `;`, which ui_fluents.parse_goal treats as a fluent
    separator before it strips comments. The optional `# start:` directive
    (load_start) is a `#` comment too, so it is ignored here -- it never leaks into
    the goal fluent set."""
    with open(goal_path(name, "goal")) as f:
        body = "\n".join(
            ln for ln in f.read().splitlines() if not ln.lstrip().startswith("#"))
    return ui_fluents.parse_goal(body)


# [stol:ui-planner-cov-starts]  NON-BOOT START STATES.  A goal file may declare a
# start CONTEXT other than boot(home) via a `# start: <fluent(s)>` directive, e.g.
#
#     # start: context(admin)
#     context(home)
#
# The directive is OPTIONAL: a goal with no `# start:` behaves exactly as before
# (start = boot(home)), so every pre-existing goal -- and any start-less goal a
# sibling adds -- plans, runs, and covers identically under this version. A
# declared start lets A* route the FOUR return-navs back to home
# (nav_{admin,scope,quicksave,unit_picker_dense}_to_home) and the indirect
# nav_sample_pool_to_admin, none of which an all-boot-start corpus ever exercises
# (context(home)/context(admin) are already reached at/near the start).
#
# At --run time the runner FIRST solves + drives a SETUP route boot(home) ->
# declared start (setup_plan_for), THEN plans + drives the goal FROM that start.
# The setup route is NOT part of the goal's measured .plan golden nor the coverage
# tally -- only the goal's own plan (plan_for, solved from the declared start) is.

START_DIRECTIVE = "# start:"


def load_start(name):
    """The goal's declared `# start: <fluent(s)>` start context as a canonical
    fluent list, or None when the goal starts at the default boot(home) state.

    The value after `# start:` is parsed with ui_fluents.parse_goal (so it accepts
    the same `;`/newline fluent syntax). Only the FIRST such directive is honored.
    [stol:ui-planner-cov-starts]"""
    with open(goal_path(name, "goal")) as f:
        for ln in f.read().splitlines():
            s = ln.strip()
            if s.startswith(START_DIRECTIVE):
                spec = s[len(START_DIRECTIVE):].strip()
                if spec:
                    return ui_fluents.parse_goal(spec)
    return None


def start_state(name):
    """The concrete planning start for a goal: its declared `# start:` fluents, or
    ui_solve.boot_start() (home) when none is declared."""
    st = load_start(name)
    return st if st is not None else ui_solve.boot_start()


def plan_for(name, operators):
    """Solve the goal FROM its start -- the declared `# start:` context, or
    boot(home) when start-less. Returns (goal, ui_solve.Plan|None)."""
    goal = load_goal(name)
    return goal, ui_solve.solve(operators, start_state(name), goal)


def setup_plan_for(name, operators):
    """Plan the SETUP route boot(home) -> a start-goal's declared start context.
    Returns a ui_solve.Plan (possibly empty) or None for a boot-start goal.

    This route is driven FIRST at --run to place the emu in the declared start; it
    is deliberately SEPARATE from plan_for (the goal's measured plan), so the setup
    never enters the .plan golden or the coverage tally. [stol:ui-planner-cov-starts]"""
    st = load_start(name)
    if st is None:
        return None
    return ui_solve.solve(operators, ui_solve.boot_start(), st)


# ── plan golden (deterministic text) ─────────────────────────────────────────

def render_plan_golden(name, goal, plan, start=None):
    """The committed offline-plan golden: the goal echoed as a comment header
    plus one operator-instance LABEL per line (id(param values)). Fully
    deterministic (ui_solve grounds + sorts stably).

    For a declared-start goal, a `# start:` line records the non-boot start the
    plan was solved from; start-less goals emit no such line, so their goldens are
    byte-identical to the pre-directive format. [stol:ui-planner-cov-starts]"""
    out = ["# ui_solve offline plan -- goal '%s'" % name]
    if start:
        out.append("# start: %s" % "; ".join(start))
    out.append("# goal (%d fluent(s)):" % len(goal))
    for g in goal:
        out.append("#   %s" % g)
    if plan is None:
        out.append("# plan: NO PLAN (unreachable with the current operator library)")
        return "\n".join(out) + "\n"
    out.append("# plan: %d operator(s)" % len(plan.ops))
    for gop in plan.ops:
        out.append(gop.label())
    return "\n".join(out) + "\n"


def _diff(want, got, label):
    import difflib
    return "".join(difflib.unified_diff(
        want.splitlines(keepends=True), got.splitlines(keepends=True),
        fromfile="%s (golden)" % label, tofile="%s (regenerated)" % label))


def cmd_check_plans(names):
    """Offline: regenerate each goal's plan text and diff against its golden.
    STOL_UPDATE_GOALS=1 writes goldens. Returns 0 (all match / updated) or 1."""
    operators, _ = ui_solve.load_operators()
    update = _updating()
    rc = 0
    for name in names:
        goal, plan = plan_for(name, operators)
        if plan is None:
            print("  [FAIL] %s -- NO PLAN (goal unreachable)" % name)
            rc = 1
            continue
        text = render_plan_golden(name, goal, plan, load_start(name))
        path = goal_path(name, "plan")
        if update:
            with open(path, "w") as f:
                f.write(text)
            print("  [update] %s -- %d op(s)" % (name, len(plan.ops)))
            continue
        if not os.path.exists(path):
            print("  [FAIL] %s -- plan golden missing: %s (STOL_UPDATE_GOALS=1 to create)"
                  % (name, os.path.relpath(path, REPO_ROOT)))
            rc = 1
            continue
        with open(path) as f:
            want = f.read()
        if want != text:
            print("  [FAIL] %s -- plan drift (STOL_UPDATE_GOALS=1 to accept):" % name)
            print(_diff(want, text, name + ".plan").rstrip("\n"))
            rc = 1
        else:
            print("  [PASS] %s -- %d op(s)" % (name, len(plan.ops)))
    return rc


# ── coverage ─────────────────────────────────────────────────────────────────

def compute_coverage(names, operators):
    """Return the coverage model: per-goal (name, plan_len, op_ids) rows, the
    covered/uncovered operator + fluent-type sets. Offline (solve only)."""
    all_ops = sorted(operators)
    rows = []
    covered_ops = set()
    covered_types = set()
    for name in names:
        goal, plan = plan_for(name, operators)
        ops = sorted({g.op.id for g in plan.ops}) if plan else []
        covered_ops.update(ops)
        rows.append((name, len(plan.ops) if plan else 0, ops))
        for g in goal:
            p = ui_fluents.parse_fluent(g)
            if p:
                covered_types.add(p[0])
    uncovered_ops = [o for o in all_ops if o not in covered_ops]
    covered_types_l = [t for t in FLUENT_TYPES if t in covered_types]
    uncovered_types = [t for t in FLUENT_TYPES if t not in covered_types]
    return {
        "rows": rows,
        "n_ops": len(all_ops),
        "covered_ops": sorted(covered_ops),
        "uncovered_ops": uncovered_ops,
        "n_types": len(FLUENT_TYPES),
        "covered_types": covered_types_l,
        "uncovered_types": uncovered_types,
    }


def render_coverage(cov):
    """The committed testing-assets/emu/goal-coverage.txt (deterministic)."""
    L = []
    L.append("# ER-301 (stolmine) UI planning domain -- example-goal corpus COVERAGE.")
    L.append("#")
    L.append("# GENERATED by tools/ui_goals.py [stol:ui-planner-goal-corpus]; do NOT")
    L.append("# hand-edit. Regenerate with STOL_UPDATE_GOALS=1 scripts/dev goal-corpus")
    L.append("# (or: STOL_UPDATE_GOALS=1 python3 tools/ui_goals.py --coverage). The")
    L.append("# headline numbers grow monotonically as goals/*.goal are added.")
    L.append("# Deterministic: sorted, no timestamps/paths.")
    L.append("")
    L.append("operators covered: %d/%d" % (len(cov["covered_ops"]), cov["n_ops"]))
    L.append("goal-fluent types: %d/%d" % (len(cov["covered_types"]), cov["n_types"]))
    L.append("")
    L.append("[goals]  (name -> plan length -> operators exercised)")
    for name, plen, ops in cov["rows"]:
        L.append("%-22s %2d  %s" % (name, plen, ",".join(ops) if ops else "(empty plan)"))
    L.append("")
    L.append("[operators.covered]  (%d)" % len(cov["covered_ops"]))
    L.extend(cov["covered_ops"])
    L.append("")
    L.append("[operators.uncovered]  (%d)" % len(cov["uncovered_ops"]))
    for o in cov["uncovered_ops"]:
        why = UNCOVERED_OP_WHY.get(o, "(no goal exercises it)")
        L.append("%-30s # %s" % (o, why))
    L.append("")
    L.append("[fluent_types.covered]  (%d)" % len(cov["covered_types"]))
    L.extend(cov["covered_types"])
    L.append("")
    L.append("[fluent_types.uncovered]  (%d)" % len(cov["uncovered_types"]))
    for t in cov["uncovered_types"]:
        why = UNCOVERED_TYPE_WHY.get(t, "(no goal exercises it)")
        L.append("%-30s # %s" % (t, why))
    return "\n".join(L) + "\n"


def cmd_coverage(names):
    """Emit/compare goal-coverage.txt. STOL_UPDATE_GOALS=1 writes it. Returns 0/1."""
    operators, _ = ui_solve.load_operators()
    cov = compute_coverage(names, operators)
    text = render_coverage(cov)
    if _updating():
        with open(COVERAGE_FILE, "w") as f:
            f.write(text)
        print("  [update] %s" % os.path.relpath(COVERAGE_FILE, REPO_ROOT))
        print("  operators covered: %d/%d; goal-fluent types: %d/%d"
              % (len(cov["covered_ops"]), cov["n_ops"],
                 len(cov["covered_types"]), cov["n_types"]))
        return 0
    if not os.path.exists(COVERAGE_FILE):
        print("  [FAIL] coverage file missing: %s (STOL_UPDATE_GOALS=1 to create)"
              % os.path.relpath(COVERAGE_FILE, REPO_ROOT))
        return 1
    with open(COVERAGE_FILE) as f:
        want = f.read()
    if want != text:
        print("  [FAIL] coverage drift (STOL_UPDATE_GOALS=1 to accept):")
        print(_diff(want, text, "goal-coverage.txt").rstrip("\n"))
        return 1
    print("  [PASS] coverage: operators %d/%d, fluent types %d/%d"
          % (len(cov["covered_ops"]), cov["n_ops"],
             len(cov["covered_types"]), cov["n_types"]))
    return 0


# ── live run (drive the emu; verify satisfies + trace golden) ────────────────

def _first_failure(results):
    for label, res, det in results:
        if res is False:
            return label, det
    return None, None


def _run_one(name, operators, emu_bin=None):
    """Solve + drive `<name>` against a fresh hermetic emu with UI tracing on.
    Returns (satisfies_ok, trace_lines, detail). Reuses ui_solve.Executor and
    emu_test.normalize_trace verbatim (never re-implements the drive).

    For a DECLARED-START goal the SETUP route (boot -> declared start) is driven
    FIRST with tracing STILL OFF, so only the goal's own transitions land in the
    trace golden and the setup is never measured; then tracing is enabled and the
    goal itself is driven FROM that start. [stol:ui-planner-cov-starts]"""
    goal, plan = plan_for(name, operators)
    if plan is None:
        return False, None, "NO PLAN (goal unreachable)"
    start = load_start(name)
    setup = setup_plan_for(name, operators)
    if start is not None and setup is None:
        return False, None, "NO SETUP PLAN (declared start %s unreachable from boot)" % start
    ex = ui_solve.Executor(operators_column_map(operators), packages=["core"], emu_bin=emu_bin)
    emu_test = ex.ET
    ok = False
    trace = None
    try:
        ex.start()
        # SETUP: drive boot -> declared start with tracing OFF (so no @trace lines
        # accumulate for it). ex.run(setup, start) reuses the Executor verbatim and
        # verifies satisfies(declared start) as its own final check.
        if setup is not None and setup.ops:
            if not ex.run(setup, start):
                label, det = _first_failure(ex.results)
                return False, None, "SETUP route failed at %s: %s" % (label, det)
        # Enable UI tracing AFTER any setup (before the goal's first gesture) so the
        # captured route is the goal portion ONLY; boot-settle + setup are past.
        ex.send("trace on")
        setup_results = len(ex.results)
        ok = ex.run(plan, goal)
        trace = emu_test.normalize_trace(ex.emu.trace)
    finally:
        ex.stop()
        if ex.sandbox and not os.environ.get("STOL_KEEP_SANDBOX"):
            import shutil
            shutil.rmtree(ex.sandbox, ignore_errors=True)
    detail = "satisfies + %d trace line(s)" % (len(trace) if trace else 0)
    if not ok:
        # Surface the first failing drive result from the GOAL portion.
        label, det = _first_failure(ex.results[setup_results:])
        if label is not None:
            detail = "drive FAILED at %s: %s" % (label, det)
    return ok, trace, detail


def operators_column_map(operators):
    # ui_solve.load_operators returns (operators, column_map); Executor needs the
    # column_map. Reload it once (cheap, deterministic) to avoid threading it.
    _, column_map = ui_solve.load_operators()
    return column_map


def cmd_run(names, emu_bin=None):
    """Drive every named goal: assert satisfies(goal) live and diff the
    frame-stripped context/stack trace against `<name>.trace`.
    STOL_UPDATE_GOALS=1 writes trace goldens. Returns 0/1."""
    operators, _ = ui_solve.load_operators()
    update = _updating()
    rc = 0
    for name in names:
        # [stol:ui-planner-cov-starts] Make the setup->goal split visible in the
        # transcript for a declared-start goal.
        st = load_start(name)
        if st is not None:
            setup = setup_plan_for(name, operators)
            _, gplan = plan_for(name, operators)
            setup_ids = ",".join(g.op.id for g in setup.ops) if setup else "(none)"
            goal_ids = ",".join(g.op.id for g in gplan.ops) if gplan else "NO PLAN"
            print("  [start] %s -- setup home->{%s}: %s | goal-from-start: %s"
                  % (name, "; ".join(st), setup_ids, goal_ids))
        ok, trace, detail = _run_one(name, operators, emu_bin=emu_bin)
        if not ok:
            print("  [FAIL] %s -- %s" % (name, detail))
            rc = 1
            continue
        text = "".join(l + "\n" for l in trace)
        path = goal_path(name, "trace")
        if update:
            with open(path, "w") as f:
                f.write(text)
            print("  [update] %s -- %s" % (name, detail))
            continue
        if not os.path.exists(path):
            print("  [FAIL] %s -- trace golden missing: %s (STOL_UPDATE_GOALS=1 to create)"
                  % (name, os.path.relpath(path, REPO_ROOT)))
            rc = 1
            continue
        with open(path) as f:
            want = f.read()
        if want != text:
            print("  [FAIL] %s -- trace drift (STOL_UPDATE_GOALS=1 to accept):" % name)
            print(_diff(want, text, name + ".trace").rstrip("\n"))
            rc = 1
        else:
            print("  [PASS] %s -- %s" % (name, detail))
    return rc


# ── cli ──────────────────────────────────────────────────────────────────────

def cmd_list(names):
    operators, _ = ui_solve.load_operators()
    for name in names:
        goal, plan = plan_for(name, operators)
        ops = ",".join(g.label() for g in plan.ops) if plan else "NO PLAN"
        print("%-22s %s" % (name, ops))
    return 0


def main(argv):
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--check-plans", action="store_true",
                   help="offline: diff each goal's plan against its golden")
    p.add_argument("--coverage", action="store_true",
                   help="offline: emit/compare goal-coverage.txt")
    p.add_argument("--run", action="store_true",
                   help="drive the emu per goal; assert satisfies + diff trace golden")
    p.add_argument("--list", action="store_true", help="list corpus goals + plans")
    p.add_argument("--emu-bin", default=None, help="(--run) emu binary override")
    p.add_argument("names", nargs="*", help="restrict to these goal names (default: all)")
    args = p.parse_args(argv[1:])

    names = args.names or discover_goals()
    if not names:
        print("no goals found in %s" % os.path.relpath(GOALS_DIR, REPO_ROOT))
        return 1

    if not (args.check_plans or args.coverage or args.run or args.list):
        p.print_help()
        return 2

    rc = 0
    if args.list:
        rc |= cmd_list(names)
    if args.check_plans:
        print("ui_goals.py --check-plans (%d goal(s))" % len(names))
        rc |= cmd_check_plans(names)
    if args.coverage:
        print("ui_goals.py --coverage (%d goal(s))" % len(names))
        rc |= cmd_coverage(names)
    if args.run:
        print("ui_goals.py --run (%d goal(s))" % len(names))
        rc |= cmd_run(names, emu_bin=args.emu_bin)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))

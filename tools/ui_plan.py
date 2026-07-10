#!/usr/bin/env python3
"""ui_plan.py -- goal -> gesture-sequence path planner for the ER-301 headless emu.

[stol:ui-model-planner]  Layer 3 of the ui-model cluster (planning/ui-model-plan.md
§4). Turns a high-level GOAL into a control-protocol gesture sequence, and can
(optionally) drive the headless emulator to execute it and CONFIRM arrival via the
runtime introspection API (xroot/emu/UIState.lua, Layer 1).

It composes the three sibling inputs, all already on develop:
  * testing-assets/emu/ui-map.toml        verified context nodes + edges (Layer / map)
  * testing-assets/emu/ui-model.manifest  per-class handlers + per-unit slot maps (Layer 2)
  * docs/UI_OPERATION.md                   the canonical logical-gesture catalog (Layer 0)
  * emu.UIState (via the `lua` command)    live "describe the UI + affordances" (Layer 1)

Design: prefer OFFLINE planning (map BFS + manifest + catalog); fall back to LIVE
introspection only where a gesture is statically ambiguous. Two things are
irreducibly runtime-dependent and are resolved live in --run:
  1. WHICH main column opens the unit picker -- it is the column currently holding
     an EmptySection.EmptyControl, which shifts with chain width (M3 on an empty
     mono chain, M4 after a stereo link adds a second input spot).
  2. WHERE a named unit sits in the dense picker -- its (row, column) depends on the
     live, channel-count-filtered, sorted unit list.
Everything else (context navigation, the link chord, the pick side, the assert
targets) is emitted deterministically offline.

Stdlib only. Usage:

  tools/ui_plan.py --goal '<json>'            print the offline plan (gestures + steps)
  tools/ui_plan.py --goal-file G.json         same, goal from a file
  tools/ui_plan.py --run --goal '<json>'      assemble a sandbox, drive the emu, VERIFY
  tools/ui_plan.py --selftest                 offline planning correctness (no emu)

Goal schema (all keys optional; steps run in this order):
  {
    "context":    "<map node>",         navigate here first (BFS over ui-map edges)
    "link":       [1, 2],               stereo-link an adjacent channel pair
    "insert":     "<unit title>",       open the picker + choose this unit
    "focus":      "<unit title>",       assert this unit is the focused section
    "expand":     true|false,           toggle the focused unit's expanded view
    "control_at": {"M2": "V/oct"},      assert control NAME (or class) at a slot
    "packages":   ["core"]              (--run) packages to stage into the sandbox
  }

`control_at` values match either the on-screen control NAME or its class (so both
"V/oct" and "Unit.ViewControl.Pitch" are accepted for the same slot).

The Network-on-M1 real-world demo (verified manually; NON-hermetic) is documented in
docs/UI_OPERATION.md and at the bottom of this file. The committed hermetic
acceptance test is tests/emu/53-ui-plan-core-insert.test (a CORE unit).
"""

import argparse
import json
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_MAP = os.path.join(REPO_ROOT, "testing-assets/emu/ui-map.toml")
DEFAULT_MANIFEST = os.path.join(REPO_ROOT, "testing-assets/emu/ui-model.manifest")


# ── inputs ────────────────────────────────────────────────────────────────────

def load_map(path=DEFAULT_MAP):
    """Load ui-map.toml -> dict. Uses stdlib tomllib (Python 3.11+)."""
    try:
        import tomllib
    except ImportError as e:  # pragma: no cover - matches emu_test's requirement
        raise SystemExit("ui_plan.py needs Python 3.11+ (tomllib): %s" % e)
    with open(path, "rb") as f:
        return tomllib.load(f)


def load_manifest(path=DEFAULT_MANIFEST):
    with open(path, "r") as f:
        return json.load(f)


# ── map graph ────────────────────────────────────────────────────────────────

class UiMap:
    def __init__(self, data):
        self.meta = data.get("meta", {})
        self.nodes = data.get("node", {})
        self.edges = data.get("edge", [])
        self.boot = self.meta.get("boot_node", "home")
        self.adj = {}
        for e in self.edges:
            self.adj.setdefault(e["from"], []).append(e)

    def recognize(self, node):
        return self.nodes.get(node, {}).get("recognize")

    def bfs(self, start, goal):
        """Shortest edge path start -> goal (list of edge dicts), or None.
        [] means already there."""
        if start == goal:
            return []
        from collections import deque
        q = deque([(start, [])])
        seen = {start}
        while q:
            node, path = q.popleft()
            for e in self.adj.get(node, []):
                nxt = e["to"]
                if nxt in seen:
                    continue
                npath = path + [e]
                if nxt == goal:
                    return npath
                seen.add(nxt)
                q.append((nxt, npath))
        return None


# ── plan model ───────────────────────────────────────────────────────────────

class Step:
    """One planned action.

    kind:    'nav' | 'link' | 'open_picker' | 'choose_unit' | 'expand' | 'assert'
    gestures: concrete control-protocol lines resolvable OFFLINE (may be []).
    live:    True iff the concrete gestures are resolved at run time from uiState.
    check:   optional list of (lua_expr, description) asserted in --run.
    meta:    step-specific data (unit name, slot map, pair, ...).
    """

    def __init__(self, kind, desc, gestures=None, live=False, check=None, meta=None):
        self.kind = kind
        self.desc = desc
        self.gestures = gestures or []
        self.live = live
        self.check = check or []
        self.meta = meta or {}

    def __repr__(self):
        tag = " [live]" if self.live else ""
        return "Step(%s%s: %s)" % (self.kind, tag, self.desc)


# ── the planner ──────────────────────────────────────────────────────────────

# Dense picker: EncoderThreshold.Default = 3 raw detents per selectable-row step
# (xroot/Env.lua). `turn N` adds N raw detents (emu/Emulator.cpp cmd "turn").
ROW_TURN = 3
# Dense picker pick columns: M1/ENTER = left cell, M4 = right cell
# (xroot/Unit/Chooser/Dense.lua mainReleased).
PICK_MAIN = {"L": 1, "R": 4}


class Planner:
    def __init__(self, uimap, manifest):
        self.map = uimap
        self.manifest = manifest

    # -- helpers -----------------------------------------------------------------

    def link_chord(self, pair):
        """Control-protocol lines for the link chord over an adjacent pair.
        Catalog: hold SELECT<a>, tap SELECT<b> (docs/UI_OPERATION.md)."""
        a, b = sorted(pair)
        if b != a + 1:
            raise ValueError("link pair must be adjacent, got %s" % (pair,))
        return [
            "down SELECT%d" % a, "frames 6",
            "down SELECT%d" % b, "frames 6",
            "up SELECT%d" % b, "up SELECT%d" % a, "frames 10",
        ]

    def link_key(self, pair):
        a, b = sorted(pair)
        return "link%d%d" % (a, b)

    def unit_expanded(self, title):
        """The focused unit's expanded view list from the manifest, best-effort.
        Returns (unit_key, [names], slotmap) or (None, [], {}). The manifest is
        keyed by class-ish names, so match on title-ish or by builtin file."""
        units = self.manifest.get("units", {})
        # exact key, else a unit whose file basename resembles the title
        if title in units:
            u = units[title]
            return title, u.get("expanded", []), u.get("slots", {})
        # Heuristic fallback: the manifest is keyed by class-ish names / file
        # basenames (e.g. "Test Osc" -> TestOscillator @ builtins/TestOscillator).
        # Match the space-squashed title against the key or file basename, exact
        # first then as a prefix (a title is a prefix of its "…Unit"/"…illator"
        # class name).
        squashed = title.replace(" ", "")

        def norm(x):
            return os.path.splitext(os.path.basename(x))[0]

        for exact in (True, False):
            for k, u in units.items():
                base = norm(u.get("file", ""))
                cands = (base, k.split(" @")[0])
                for c in cands:
                    if (c == squashed if exact else c.startswith(squashed)):
                        return k, u.get("expanded", []), u.get("slots", {})
        return None, [], {}

    # -- plan --------------------------------------------------------------------

    def plan(self, goal, from_node=None):
        steps = []
        cur = from_node or self.map.boot

        # 1. Context navigation -- BFS over verified ui-map edges.
        target_ctx = goal.get("context")
        if target_ctx:
            path = self.map.bfs(cur, target_ctx)
            if path is None:
                steps.append(Step(
                    "nav",
                    "NO PATH from %r to %r -- map growth needed" % (cur, target_ctx),
                    meta={"unreachable": True, "from": cur, "to": target_ctx}))
            else:
                for e in path:
                    steps.append(Step(
                        "nav", "%s -> %s" % (e["from"], e["to"]),
                        gestures=list(e["gesture"]),
                        check=[(self.map.recognize(e["to"]),
                                "at node %s" % e["to"])],
                        meta={"edge": e}))
                cur = target_ctx

        # 2. Stereo link -- deterministic chord.
        if goal.get("link"):
            pair = goal["link"]
            steps.append(Step(
                "link", "stereo-link channels %s" % (pair,),
                gestures=self.link_chord(pair),
                check=[("tostring(require('Channels').serialize().links.%s) == 'true'"
                        % self.link_key(pair), "%s linked" % self.link_key(pair))],
                meta={"pair": pair}))

        # 3. Insert a named unit -- open picker (live slot) + choose (live nav).
        if goal.get("insert"):
            title = goal["insert"]
            # Offline NOMINAL open-picker gesture from the map (empty mono chain);
            # in --run this is re-resolved to whichever column holds the
            # EmptyControl (M3 mono / M4 after a link).
            open_edge = None
            for e in self.map.edges:
                if e["to"] == "unit_picker_dense":
                    open_edge = e
                    break
            nominal = list(open_edge["gesture"]) if open_edge else ["press MAIN3", "frames 12"]
            steps.append(Step(
                "open_picker",
                "open dense unit picker (press the EmptyControl column)",
                gestures=nominal, live=True,
                check=[("require('emu.UIState').topClass() == 'Unit.Chooser.Dense'",
                        "picker open")],
                meta={"nominal": nominal}))
            steps.append(Step(
                "choose_unit", "choose unit %r from the picker" % title,
                gestures=[], live=True,
                check=[("require('Channels').getChain(1):length() >= 1",
                        "a unit was inserted")],
                meta={"unit": title}))

        # 4. Focus assertion (after insert the unit is auto-focused + expanded).
        if goal.get("focus"):
            ftitle = goal["focus"]
            steps.append(Step(
                "assert", "focused section is unit %r" % ftitle,
                check=[
                    ("require('emu.UIState').selectionSectionClass() == 'Unit'",
                     "a Unit is focused"),
                    ("require('Channels').getChain(1):getSelection().title:find(%s,1,true) == 1"
                     % _lua_str(ftitle), "focused unit is %s" % ftitle),
                ],
                meta={"focus": ftitle}))

        # 5. Optional expand toggle (press the focused unit header spot).
        if goal.get("expand") is not None:
            steps.append(Step(
                "expand", "toggle focused unit expanded view",
                gestures=[], live=True, meta={"expand": goal["expand"]}))

        # 6. control_at assertions -- verify the on-screen slot map.
        for slot, want in (goal.get("control_at") or {}).items():
            steps.append(Step(
                "assert", "control at %s is %r" % (slot, want),
                check=[(
                    "(function() local U=require('emu.UIState'); "
                    "return U.controlNameAt(%s)==%s or U.controlClassAt(%s)==%s end)()"
                    % (_lua_str(slot), _lua_str(want), _lua_str(slot), _lua_str(want)),
                    "%s == %s" % (slot, want))],
                meta={"slot": slot, "want": want}))

        return steps


def _lua_str(s):
    return "'" + str(s).replace("\\", "\\\\").replace("'", "\\'") + "'"


# ── offline rendering ────────────────────────────────────────────────────────

def render_plan(steps, goal):
    out = []
    out.append("# ui_plan: goal = %s" % json.dumps(goal, sort_keys=True))
    out.append("# %d step(s). '[live]' steps resolve their concrete gestures from" % len(steps))
    out.append("# uiState() at run time (see --run).")
    n = 0
    for s in steps:
        n += 1
        tag = "  [live]" if s.live else ""
        out.append("")
        out.append("## step %d: %s%s -- %s" % (n, s.kind, tag, s.desc))
        if s.meta.get("unreachable"):
            frm, to = s.meta["from"], s.meta["to"]
            out.append("#   !! no ui-map path %s -> %s; suggested edge:" % (frm, to))
            out.extend("#   " + l for l in suggest_edge(frm, to))
        if s.gestures:
            label = "# nominal (re-resolved live):" if s.live else "# gestures:"
            out.append(label)
            out.extend(s.gestures)
        elif s.live:
            out.append("# (gestures resolved live from uiState -- run with --run)")
        for expr, desc in s.check:
            if expr:
                out.append("# assert: %s" % desc)
    return "\n".join(out)


def suggest_edge(frm, to, gesture=None, arrival=None):
    """A ui-map.toml [[edge]] block a human can paste after VERIFYING it live."""
    g = gesture or ["<gesture lines>"]
    lines = [
        "[[edge]]",
        'from = "%s"' % frm,
        'to = "%s"' % to,
        "# SUGGESTED by ui_plan.py -- VERIFY live before committing.",
        "gesture = [%s]" % ", ".join('"%s"' % x for x in g),
    ]
    if arrival:
        lines.append('arrival = "%s"' % arrival)
    return lines


# ── live execution (--run) ───────────────────────────────────────────────────

def _import_harness():
    sys.path.insert(0, os.path.join(REPO_ROOT, "tools"))
    import emu_test  # noqa: E402
    return emu_test


class Executor:
    """Drives a fresh hermetic emu, executes the plan, verifies via uiState."""

    def __init__(self, packages=None, emu_bin=None, timeout=90.0):
        self.ET = _import_harness()
        self.cfg = self.ET.Config()
        if emu_bin:
            self.cfg.emu_bin = emu_bin
        self.packages = packages or ["core"]
        self.timeout = timeout
        self.emu = None
        self.sandbox = None
        self.results = []      # (step_desc, ok, detail)
        self.suggestions = []  # map-growth suggestions

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

    def _settle(self, n=10):
        self.send("frames %d" % n)

    def assert_true(self, expr):
        return self.lua(expr) == "true"

    # -- step drivers ------------------------------------------------------------

    def run(self, steps):
        for s in steps:
            try:
                ok, detail = self._drive(s)
            except Exception as e:
                ok, detail = False, "exception: %s" % e
            self.results.append((s.desc, ok, detail))
            if not ok:
                # capture divergence for the report and stop (later steps depend
                # on this one having landed).
                self.results.append(("  uiState @ failure",
                                     None, self._diagnostic()))
                break
        return all(ok for _, ok, _ in self.results if ok is not None)

    def _drive(self, s):
        if s.kind in ("nav", "link"):
            for g in s.gestures:
                self.send(g)
            return self._verify_checks(s)
        if s.kind == "open_picker":
            return self._open_picker(s)
        if s.kind == "choose_unit":
            return self._choose_unit(s)
        if s.kind == "expand":
            return self._expand(s)
        if s.kind == "assert":
            return self._verify_checks(s)
        return False, "unknown step kind %s" % s.kind

    def _verify_checks(self, s):
        for expr, desc in s.check:
            if not expr:
                continue
            if not self.assert_true(expr):
                got = None
                try:
                    got = self.lua(expr)
                except Exception:
                    pass
                return False, "check failed: %s (expr -> %r)" % (desc, got)
        return True, "ok"

    def _empty_control_slot(self):
        """Which MAIN column (1..6) currently holds an EmptySection.EmptyControl."""
        expr = ("(function() for _,c in ipairs(require('emu.UIState').describe().controls) do "
                "if c.class:find('EmptyControl',1,true) then return c.slot end end return '' end)()")
        slot = self.lua(expr)
        if slot and slot.startswith("M"):
            return int(slot[1:])
        return None

    def _open_picker(self, s):
        i = self._empty_control_slot()
        if i is None:
            self.suggestions.append(
                "open_picker: no EmptyControl slot found; is the chain non-empty?")
            return False, "no EmptyControl column on screen"
        resolved = ["press MAIN%d" % i, "frames 15"]
        s.meta["resolved"] = resolved
        if resolved[0] != s.meta.get("nominal", [None])[0]:
            # The live opener differs from the map's nominal (e.g. after a link).
            # Surface it as a map-growth note, not an error.
            self.suggestions.append(
                "open_picker resolved to 'press MAIN%d' (map nominal was %r); "
                "consider a dedicated ui-map edge for the current chain width."
                % (i, s.meta.get("nominal")))
        for g in resolved:
            self.send(g)
        return self._verify_checks(s)

    def _choose_unit(self, s):
        title = s.meta["unit"]
        loc = self.lua(
            "(function() local w=require('Application').getVisibleContext():top(); "
            "for i,r in ipairs(w.rows or {}) do if r.type=='pair' then "
            "if r.left and r.left.title==%s then return (i-1)..',L' end; "
            "if r.right and r.right.title==%s then return (i-1)..',R' end "
            "end end return 'nil' end)()" % (_lua_str(title), _lua_str(title)))
        if loc == "nil":
            self.suggestions.append(
                "choose_unit: %r not present in the live picker (check package set / "
                "channel-count filter)." % title)
            return False, "unit %r not in picker" % title
        row_s, side = loc.split(",")
        target_row = int(row_s)
        # Closed-loop cursor navigation: turn ROW_TURN detents per selectable row.
        guard = 0
        while guard < 64:
            cur = int(self.lua("require('Application').getVisibleContext():top().cursorRow"))
            if cur == target_row:
                break
            step = ROW_TURN if target_row > cur else -ROW_TURN
            self.send("turn %d" % step)
            self._settle(6)
            guard += 1
        cur = int(self.lua("require('Application').getVisibleContext():top().cursorRow"))
        if cur != target_row:
            return False, "could not land cursor on row %d (stuck at %d)" % (target_row, cur)
        # Pick the correct column and wait out the ~0.12s pick-flash timer.
        self.send("press MAIN%d" % PICK_MAIN[side])
        self._settle(30)
        s.meta["resolved"] = {"row": target_row, "side": side}
        return self._verify_checks(s)

    def _expand(self, s):
        # Toggle the focused unit's view by pressing its header spot (the slot
        # whose class is Unit.Base.Header).
        i = self.lua(
            "(function() for _,c in ipairs(require('emu.UIState').describe().controls) do "
            "if c.class=='Unit.Base.Header' then return c.slot end end return '' end)()")
        if i and i.startswith("M"):
            self.send("press MAIN%s" % i[1:])
            self._settle(15)
            return True, "toggled at %s" % i
        return False, "no unit header on screen to expand"

    def _diagnostic(self):
        try:
            ctx = self.lua("require('emu.UIState').contextName()")
            top = self.lua("require('emu.UIState').topClass()")
            sel = self.lua("require('emu.UIState').selectionSectionClass()")
            slots = []
            for k in range(1, 7):
                c = self.lua("require('emu.UIState').controlClassAt('M%d')" % k)
                n = self.lua("require('emu.UIState').controlNameAt('M%d')" % k)
                if c:
                    slots.append("M%d=%s(%s)" % (k, c, n))
            return "context=%s top=%s focus=%s | %s" % (ctx, top, sel, "  ".join(slots))
        except Exception as e:
            return "diagnostic failed: %s" % e


def do_run(goal, args):
    uimap = UiMap(load_map(args.map))
    manifest = load_manifest(args.manifest)
    planner = Planner(uimap, manifest)
    steps = planner.plan(goal, from_node=args.from_node)

    print(render_plan(steps, goal))
    print("\n# ── executing against the headless emu ──")

    ex = Executor(packages=goal.get("packages") or args.packages,
                  emu_bin=args.emu_bin)
    ok_all = True
    try:
        ex.start()
        ok_all = ex.run(steps)
    finally:
        for desc, ok, detail in ex.results:
            if ok is None:
                print("     %s" % detail)
            else:
                print("  [%s] %s -- %s" % ("PASS" if ok else "FAIL", desc, detail))
        if ex.suggestions:
            print("\n# map-growth suggestions:")
            for sug in ex.suggestions:
                print("#   %s" % sug)
        ex.stop()
        if ex.sandbox and not os.environ.get("STOL_KEEP_SANDBOX"):
            import shutil
            shutil.rmtree(ex.sandbox, ignore_errors=True)
    print("\n%s" % ("RUN OK" if ok_all else "RUN FAILED"))
    return 0 if ok_all else 1


# ── selftest (offline planning correctness; no emu) ──────────────────────────

def selftest():
    uimap = UiMap(load_map())
    manifest = load_manifest()
    planner = Planner(uimap, manifest)
    failures = []

    def check(cond, msg):
        marker = "PASS" if cond else "FAIL"
        print("  [%s] %s" % (marker, msg))
        if not cond:
            failures.append(msg)

    def gestures_of(steps, kind):
        out = []
        for s in steps:
            if s.kind == kind:
                out.extend(s.gestures)
        return out

    print("ui_plan.py --selftest (offline planning vs ui-map.toml + manifest)")

    # 1. home -> admin : one nav step, exact map-edge gestures.
    steps = planner.plan({"context": "admin"}, from_node="home")
    nav = [s for s in steps if s.kind == "nav"]
    check(len(nav) == 1, "home->admin is a single nav edge")
    check(gestures_of(steps, "nav") == ["storage center", "frames 10"],
          "home->admin emits the verified STORAGE-center gesture")

    # 2. home -> unit_picker_dense : the MAIN3 spot-open edge.
    steps = planner.plan({"context": "unit_picker_dense"}, from_node="home")
    check(gestures_of(steps, "nav") == ["press MAIN3", "frames 12"],
          "home->picker emits the verified MAIN3 spot-open gesture")

    # 3. multi-hop nav uses BFS (home -> sequencer = scope then SHIFT+ENTER).
    steps = planner.plan({"context": "sequencer"}, from_node="home")
    navdescs = [s.desc for s in steps if s.kind == "nav"]
    check(navdescs == ["home -> scope", "scope -> sequencer"],
          "home->sequencer BFS routes via scope: %s" % navdescs)
    check(gestures_of(steps, "nav") ==
          ["mode down", "frames 10", "down SHIFT", "press ENTER", "up SHIFT", "frames 10"],
          "home->sequencer concatenates both edges' gestures")

    # 4. the canonical link + insert + focus + control_at goal.
    goal = {"link": [1, 2], "insert": "Test Osc", "focus": "Test Osc",
            "control_at": {"M2": "V/oct"}}
    steps = planner.plan(goal, from_node="home")
    kinds = [s.kind for s in steps]
    check(kinds == ["link", "open_picker", "choose_unit", "assert", "assert"],
          "link+insert+focus+control_at yields the expected step spine: %s" % kinds)

    # link chord is the exact known-good sequence (docs/UI_OPERATION.md).
    link = [s for s in steps if s.kind == "link"][0]
    expected_chord = [
        "down SELECT1", "frames 6", "down SELECT2", "frames 6",
        "up SELECT2", "up SELECT1", "frames 10",
    ]
    check(link.gestures == expected_chord,
          "link[1,2] emits the verified SELECT1+SELECT2 chord")
    check(link.check[0][0] ==
          "tostring(require('Channels').serialize().links.link12) == 'true'",
          "link step carries the link12 verification predicate")

    # open_picker + choose_unit are live-resolved (statically ambiguous).
    op = [s for s in steps if s.kind == "open_picker"][0]
    cu = [s for s in steps if s.kind == "choose_unit"][0]
    check(op.live and cu.live, "open_picker and choose_unit are marked [live]")
    check(op.gestures == ["press MAIN3", "frames 12"],
          "open_picker nominal is the map's MAIN3 edge (re-resolved live in --run)")
    check(cu.meta.get("unit") == "Test Osc",
          "choose_unit carries the target unit name")

    # focus + control_at asserts target the right predicates.
    asserts = [s for s in steps if s.kind == "assert"]
    focus_ok = any("selectionSectionClass() == 'Unit'" in e for a in asserts for e, _ in a.check)
    check(focus_ok, "focus assert checks a Unit is selected")
    ctrl_ok = any("controlNameAt('M2')" in e and "V/oct" in e
                  for a in asserts for e, _ in a.check)
    check(ctrl_ok, "control_at assert checks name/class at M2")

    # 5. manifest cross-check: Test Osc's expanded[1] is the Pitch control, which
    #    is what lands on-screen right of the header (verified live at M2).
    key, expanded, slots = planner.unit_expanded("Test Osc")
    check(expanded[:1] == ["tune"] or (slots.get("M1", {}).get("control") == "Pitch"),
          "manifest: Test Osc expanded[1] is the Pitch control (key=%s)" % key)

    # 6. unreachable context surfaces a map-growth suggestion, not a crash.
    steps = planner.plan({"context": "nonexistent_node"}, from_node="home")
    check(any(s.meta.get("unreachable") for s in steps),
          "unreachable context yields an 'unreachable' nav step + suggested edge")

    print()
    if failures:
        print("SELFTEST FAILED: %d check(s)" % len(failures))
        return 1
    print("SELFTEST OK")
    return 0


# ── cli ──────────────────────────────────────────────────────────────────────

def parse_goal(args):
    if args.goal_file:
        with open(args.goal_file) as f:
            return json.load(f)
    if args.goal:
        return json.loads(args.goal)
    raise SystemExit("provide --goal '<json>' or --goal-file PATH")


def main(argv):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--goal", help="goal as an inline JSON object")
    p.add_argument("--goal-file", help="goal as a JSON file")
    p.add_argument("--from", dest="from_node", default=None,
                   help="starting map node (default: boot_node from the map)")
    p.add_argument("--run", action="store_true",
                   help="assemble a sandbox, drive the emu, and verify arrival")
    p.add_argument("--selftest", action="store_true",
                   help="offline planning correctness checks (no emu)")
    p.add_argument("--map", default=DEFAULT_MAP)
    p.add_argument("--manifest", default=DEFAULT_MANIFEST)
    p.add_argument("--packages", nargs="*", default=["core"],
                   help="(--run) packages to stage into the sandbox")
    p.add_argument("--emu-bin", default=None)
    args = p.parse_args(argv[1:])

    if args.selftest:
        return selftest()

    goal = parse_goal(args)
    if args.run:
        return do_run(goal, args)

    uimap = UiMap(load_map(args.map))
    manifest = load_manifest(args.manifest)
    planner = Planner(uimap, manifest)
    steps = planner.plan(goal, from_node=args.from_node)
    print(render_plan(steps, goal))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))


# ─────────────────────────────────────────────────────────────────────────────
# DOCUMENTED MANUAL DEMO -- the real-world "Network on M1" scenario (NON-hermetic)
# ─────────────────────────────────────────────────────────────────────────────
#
# This is the motivating scenario the human verified manually (2026-07-10):
# stereo-link 1+2, insert the Network unit, and its overview graphic ('glitch' =
# NetworkOverviewControl, the unit's expanded[1]) sits on M1. Network ships in the
# `spreadsheet` package, whose units are NOT pure Lua -- they need the user's
# installed ~/.od packages AND the vectorised-math preload, so this run is
# deliberately NON-hermetic (which is exactly why the committed acceptance test,
# tests/emu/53-ui-plan-core-insert.test, uses a CORE builtin instead).
#
# Exact invocation:
#
#   LD_PRELOAD=/usr/lib/libmvec.so.1 \
#   STOL_EMU_PKG_DIR="$HOME/.od/front/ER-301/packages" \
#   python3 tools/ui_plan.py --run \
#       --packages core spreadsheet \
#       --goal '{"link":[1,2], "insert":"Network", "focus":"Network",
#                "control_at":{"M1":"glitch"}}'
#
# Notes / prerequisites:
#   * LD_PRELOAD=/usr/lib/libmvec.so.1 -- the spreadsheet package's compiled units
#     resolve vector-math symbols at load; without the preload they fail to
#     register and `Network` never appears in the picker.
#   * STOL_EMU_PKG_DIR must point at a package repo where the `spreadsheet-*.pkg`
#     units actually load for this emu ABI (a fully-provisioned device / emu). On a
#     bench emu where only the Lua builtins register, the planner reports a clean
#     `choose_unit: 'Network' not present in the live picker` and a map-growth
#     suggestion -- it does not crash.
#   * Unlike a plain unit (header at on-screen M1, expanded[1] at M2), Network is an
#     OVERVIEW unit: its expanded[1] 'glitch' control is the full-width overview and
#     renders at M1 directly -- hence control_at {"M1":"glitch"}.
#
# Every gesture in this scenario is derived from source exactly as the planner
# emits it: the link chord (docs/UI_OPERATION.md), the picker opener (the live
# EmptyControl column), and the pick (dense picker row/column) -- the manual read
# the ui-model plan set out to turn into a tool.

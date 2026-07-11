#!/usr/bin/env python3
"""ui_crawl.py -- the EMPIRICAL UI crawler for the ER-301 planning domain.

[stol:ui-planner-crawler]  Layer 4 (crawler) of the ui-planner cluster
(planning/ui-planning-domain-plan.md §4). A CONVENTIONAL graph explorer with a
PERFECT ORACLE -- no learning anywhere. It drives gestures against the headless
emu, observes the ACTUAL resulting state through emu.uiState() projected to the
shared fluent vocabulary (tools/ui_fluents.py), records the empirical transitions,
and RESOLVES the 6 `needs_crawl` operators in testing-assets/emu/ui-operators.toml
(open_picker, insert, focus_unit, set_cell, expand, collapse) to concrete
precondition->gesture rules with driven proofs.

──────────────────────────────────────────────────────────────────────────────
ALGORITHM
──────────────────────────────────────────────────────────────────────────────
* FRONTIER: breadth-first over states keyed by a canonical FLUENT HASH
  (sha1 of the sorted fluent set from ui_fluents.project). A UI state is its
  fluent projection, so identical states dedup and the crawl terminates.
* REPLAY-FROM-BOOT: the emu is deterministic under `--seed 301`, so the safe,
  reproducible way to reach a frontier state is to BOOT FRESH and replay the
  recorded gesture path. To expand a state we replay its path, apply ONE
  candidate gesture, project the post-state, and record the transition
  (pre-hash --gesture--> post-hash + fluent delta). Backtracking = re-boot.
  Every probe is a fresh hermetic sandbox (tools/emu_test.assemble_sandbox), so
  no state bleeds between probes.
* AFFORDANCE PRUNING: candidate gestures are the logical tokens (enter, cancel,
  home, dial, up, commit, main1-6, sub1-3, select1-4, encoder, mode/storage
  toggles) mapped to control-protocol lines (docs/UI_OPERATION.md). At each state
  we only probe a gesture whose notify token is in uiState().gestures with
  handled==true (the toggles, which are not notify events, are always eligible).
* BOUNDING (mandatory): max depth, max states (fluent-hash visited cap), and a
  DENYLIST of destructive/irreversible gestures (eject/unmount; unit-header
  delete/replace commands; and a per-screen safe allowlist for admin / sample
  pool / quicksave / hold / unknown screens so the crawl never activates a
  destructive menu item). The encoder is a SINGLE representative probe per state
  (its structural effect -- enter edit / move cursor -- NOT a value sweep).
  Everything skipped is counted by reason (honest coverage).

Because the fluent vocabulary does not model the SpottedStrip cursor position
(e.g. "the unit header is focused"), some operators are genuinely multi-step
through a fluent-invisible sub-state (expand/collapse: focus the header, THEN
press ENTER). Those are RESOLVED by a targeted resolver that drives the compound
gesture and records the observed effect -- still drive+observe, never a guess.
The other four dynamic operators emerge directly as single-gesture BFS
transitions (open_picker, insert, focus_unit, set_cell all cross a fluent
boundary in one gesture) and the resolver distills a clean proof for each.

──────────────────────────────────────────────────────────────────────────────
OUTPUT: testing-assets/emu/ui-crawl.map (deterministic, SORTED, byte-identical
on an unchanged build). Consumed alongside the STATIC testing-assets/emu/
ui-operators.toml by the next layer (the solver): ui-operators.toml supplies the
operator SPINE (ids, params, static pre/eff), ui-crawl.map supplies the crawler-
resolved precondition RULES + gesture SKELETONS for the 6 dynamic operators and
the empirical transition graph for drift detection.

Stdlib only. app.EMULATION path only (drives the linux emu; never od/hal). Does
NOT modify xroot/emu/UIState.lua -- it reflects it through the `lua` command.

Usage:
  tools/ui_crawl.py                 crawl + resolve, write the committed map
  tools/ui_crawl.py -o PATH         write elsewhere
  tools/ui_crawl.py --stdout        print the map (no write) -- used by the gate
  tools/ui_crawl.py --selftest      offline determinism checks (no emu)

Env:
  STOL_EMU_BIN            emu binary (default via tools/emu_test.Config)
  STOL_CRAWL_MAX_DEPTH    override max BFS depth (default 4)
  STOL_CRAWL_MAX_STATES   override max visited states (default 40)
  STOL_CRAWL_PACKAGES     space-separated packages to stage (default none;
                          the firmware builtins already populate the picker)
"""

import argparse
import hashlib
import os
import shutil
import sys
from collections import deque

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "tools"))
import emu_test as ET          # harness reuse: sandbox assembly + EmuProcess
import ui_fluents              # the fluent projection (perfect-oracle normalizer)

DEFAULT_OUT = os.path.join(REPO_ROOT, "testing-assets/emu/ui-crawl.map")
DEFAULT_MANIFEST = os.path.join(REPO_ROOT, "testing-assets/emu/ui-model.manifest")

SCHEMA_VERSION = 1

# ── bounds ────────────────────────────────────────────────────────────────────
# Kept modest so the gate stays a few minutes (it reboots the emu once per probed
# candidate). The 6 operator resolutions are independent of these BFS bounds (they
# are targeted drives), so the graph size is purely for coverage + drift detection.
MAX_DEPTH = int(os.environ.get("STOL_CRAWL_MAX_DEPTH", "3"))
MAX_STATES = int(os.environ.get("STOL_CRAWL_MAX_STATES", "24"))
SETTLE = 20            # frames to settle after each probed candidate gesture
ENCODER_DETENTS = 3    # one selectable-row / one nav step (EncoderThreshold.Default)

# ── the candidate gesture alphabet (logical token -> control-protocol lines) ────
# tokens: the uiState().gestures affordance tokens that make this candidate
# eligible; None => always eligible (toggles are mode changes, not notify events).
def _candidates():
    c = [
        ("cancel", ["press DIAL2"], {"cancelReleased", "cancelPressed"}),
        ("commit", ["down SHIFT", "press ENTER", "up SHIFT"],
         {"commitReleased", "commitPressed"}),
        ("dial", ["press DIAL1"], {"dialReleased", "dialPressed"}),
        ("encoder", ["turn %d" % ENCODER_DETENTS], {"encoder"}),
        ("enter", ["press ENTER"], {"enterReleased", "enterPressed"}),
        ("home_btn", ["press DIAL3"], {"homeReleased", "homePressed"}),
        ("mode_center", ["mode center"], None),
        ("mode_down", ["mode down"], None),
        ("mode_up", ["mode up"], None),
        ("storage_center", ["storage center"], None),
        ("storage_down", ["storage down"], None),   # ALWAYS denied (eject/unmount)
        ("storage_up", ["storage up"], None),
        ("up_btn", ["press UP"], {"upReleased", "upPressed"}),
    ]
    for i in range(1, 7):
        c.append(("main%d" % i, ["press MAIN%d" % i], {"main%d" % i}))
    for i in range(1, 4):
        c.append(("sub%d" % i, ["press SUB%d" % i], {"sub%d" % i}))
    for i in range(1, 5):
        c.append(("select%d" % i, ["press SELECT%d" % i], {"select%d" % i}))
    return sorted(c, key=lambda x: x[0])


CANDIDATES = _candidates()
CAND_LINES = {name: lines for name, lines, _ in CANDIDATES}

# ── the denylist (destructive / irreversible) ──────────────────────────────────
# Never probed anywhere: eject/unmount (drops the card).
DENY_GLOBAL = {"storage_down"}
# In the chain/home view a focused unit's header SUB buttons run its command list
# (move / replace / DELETE); never probe them.
DENY_HOME_DESTRUCTIVE = {"sub1", "sub2", "sub3"}
# Screens we cross but never fully probe -- only the safe nav-out / sample-pool
# allowlist, so the crawl never activates a destructive menu item (Firmware,
# clear, save-slot overwrite, sample delete, ...). Everything else is skipped.
SAFE_RESTRICTED = {
    "admin": {"main2", "cancel", "storage_up"},   # main2 -> sample_pool (also safe)
    "sample_pool": {"cancel"},
    "quicksave": {"cancel"},
    "hold": {"mode_center", "cancel"},
    "unit_picker_classic": {"cancel"},
}
# The screens where the 6 dynamic operators live: fully affordance-gated probing.
UNRESTRICTED = {"home", "scope", "sequencer", "unit_picker_dense"}
# Any other (unknown / fallback) node: only try to exit, never mutate.
DEFAULT_RESTRICT = {"cancel", "storage_up", "mode_center"}

# ── seeded start states (name -> setup control-protocol lines from boot) ────────
# Chosen so the crawl reaches every needs_crawl precondition with firmware + the
# picker builtins (no packages): a mono empty chain, a stereo-linked chain (moves
# the empty-insert column M3->M4), the grid sequencer, and a chain with a focused
# expanded unit (Test Osc). Sorted by name for a deterministic frontier order.
SEEDS = {
    "boot": [],
    "linked12": ["down SELECT1", "frames 6", "down SELECT2", "frames 6",
                 "up SELECT2", "up SELECT1", "frames 10"],
    "sequencer": ["mode down", "frames 10",
                  "down SHIFT", "press ENTER", "up SHIFT", "frames 10"],
    "unit_inserted": ["press MAIN3", "frames 12", "turn %d" % ENCODER_DETENTS,
                      "frames 6", "press MAIN4", "frames 30"],
}


# ── emu session (fresh hermetic sandbox per boot; deterministic replay) ─────────

class Emu:
    """One booted headless emu over a fresh hermetic sandbox. Replay-from-boot:
    construct, `replay(lines)`, `observe()`, `close()`. A new instance == a reboot."""

    def __init__(self, cfg, packages, timeout=60.0):
        self.cfg = cfg
        self.timeout = timeout
        self.sandbox, config_path = ET.assemble_sandbox(cfg, packages)
        self.emu = ET.EmuProcess(cfg, config_path)
        p = self.emu.read_reply(self._dl())
        if not (ET.reply_value(p) == "ready" or p == "ready"):
            raise RuntimeError("emu never became ready: %r" % p)
        self.replay(["frames 20"])

    def _dl(self):
        return ET._now() + self.timeout

    def send(self, line):
        self.emu.send(line)
        r = self.emu.read_reply(self._dl())
        if r is None:
            raise RuntimeError("watchdog on %r" % line)
        return r

    def replay(self, lines):
        for l in lines:
            r = self.send(l)
            if ET.reply_is_err(r):
                raise RuntimeError("emu err on %r -> %s" % (l, r))

    def lua(self, expr):
        r = self.send("lua %s" % expr)
        if ET.reply_is_err(r):
            raise RuntimeError("lua err on %r -> %s" % (expr, r))
        return ET.reply_value(r)

    def close(self):
        try:
            self.emu.send("quit")
            self.emu.read_reply(ET._now() + 5)
        except Exception:
            pass
        self.emu.kill()
        if not os.environ.get("STOL_KEEP_SANDBOX"):
            shutil.rmtree(self.sandbox, ignore_errors=True)

    # -- observation: assemble the ui_fluents bundle from small accessor calls --
    # (the emu caps a `lua` reply near ~511 bytes, so uiState().json() is
    # truncated -- we read compact slices instead and synthesize the bundle.)

    _A = ("(function() local U=require('emu.UIState'); local d=U.describe(); "
          "local w=require('Application').getVisibleContext():top(); "
          "local cc=(w and type(w.columnCursor)=='number') and tostring(w.columnCursor) or ''; "
          "local l=require('Channels').serialize().links; "
          "local sel=(d.selection and d.selection.section) or ''; local fu=''; "
          "if sel=='Unit' then local s=require('Channels').getChain(1):getSelection(); "
          "fu=(s and s.title) or '' end; "
          "return (d.stack[1] or '')..'|'..((d.focus and d.focus.class) or '')..'|'"
          "..((d.context and d.context.name) or '')..'|'..table.concat(d.modals,',')..'|'"
          "..cc..'|'..tostring(l.link12)..','..tostring(l.link23)..','..tostring(l.link34)"
          "..'|'..sel..'|'..fu end)()")
    _B = ("(function() local U=require('emu.UIState'); local t={}; for i=1,6 do "
          "local c=U.controlClassAt('M'..i); if c~='' then "
          "t[#t+1]='M'..i..'~'..c..'~'..tostring(U.controlNameAt('M'..i)) end end; "
          "return table.concat(t,';') end)()")
    _C = ("(function() local g=require('emu.UIState').describe().gestures; local t={}; "
          "for _,x in ipairs(g) do if x.handled then t[#t+1]=x.token end end; "
          "return table.concat(t,',') end)()")
    # Physical STORAGE/MODE toggle positions. These are NOT in the goal-fluent
    # vocabulary (they aren't a goal you'd assert), but they ARE part of the true
    # UI state: e.g. `mode_down` is a no-op when MODE is already down but a real
    # transition otherwise. Two states that differ ONLY in toggle position project
    # to identical fluents and would alias to one hash, making a toggle gesture's
    # outcome nondeterministic across crawls. Folding a synthetic `_toggle(<bits>)`
    # key-fluent into the state de-aliases them (and honestly records toggle moves
    # in transition deltas). The solver ignores non-vocabulary `_toggle(...)`.
    _D = ("(function() local G=app.Gpio_read; "
          "return (G(app.TOGGLE_MODE_A) and '1' or '0')..(G(app.TOGGLE_MODE_B) and '1' or '0')"
          "..(G(app.TOGGLE_STORAGE_A) and '1' or '0')..(G(app.TOGGLE_STORAGE_B) and '1' or '0') end)()")

    def observe(self):
        """Return (fluents_sorted_list, handled_token_set)."""
        a = self.lua(self._A)
        b = self.lua(self._B)
        c = self.lua(self._C)
        top, focus, ctxname, modals, cc, links, sel, fu = (a.split("|") + [""] * 8)[:8]
        controls = []
        if b:
            for entry in b.split(";"):
                slot, cls, nm = (entry.split("~") + ["", "", ""])[:3]
                controls.append({"slot": slot, "class": cls, "name": nm})
        ln = (links.split(",") + ["false", "false", "false"])[:3]
        bundle = {
            "uiState": {
                "stack": [top] if top else [],
                "focus": {"class": focus},
                "context": {"name": ctxname},
                "controls": controls,
                "modals": [m for m in modals.split(",") if m],
            },
            "links": {"link12": ln[0] == "true", "link23": ln[1] == "true",
                      "link34": ln[2] == "true"},
        }
        if fu:
            bundle["focused_unit"] = fu
        if top == "Sequencer.GridView" and cc != "":
            bundle["sequencer"] = {"slot": 0, "columnCursor": int(cc), "cells": []}
        fluents = ui_fluents.project(bundle)
        # Fold the physical toggle signature into the state key (see _D). Kept as a
        # sorted synthetic fluent so the hash + deltas de-alias toggle-only state
        # differences; not part of the goal vocabulary.
        tog = self.lua(self._D)
        fluents = sorted(fluents + ["_toggle(%s)" % tog])
        handled = set(t for t in c.split(",") if t)
        return fluents, handled


# ── fluent hashing + node parsing ───────────────────────────────────────────────

def fhash(fluents):
    return hashlib.sha1("\n".join(fluents).encode("utf-8")).hexdigest()[:12]


def node_of(fluents):
    for f in fluents:
        if f.startswith("context("):
            return f[len("context("):-1]
    return "unknown"


def delta(pre, post):
    ps, qs = set(pre), set(post)
    return sorted(qs - ps), sorted(ps - qs)


# ── candidate eligibility (affordance pruning + denylist) ───────────────────────

def eligible_candidates(node, handled):
    """Return (eligible[list of name], skips{reason:count}) for a state."""
    skips = {}

    def bump(r):
        skips[r] = skips.get(r, 0) + 1

    if node in UNRESTRICTED:
        allow = None
    elif node in SAFE_RESTRICTED:
        allow = SAFE_RESTRICTED[node]
    else:
        allow = DEFAULT_RESTRICT

    elig = []
    for name, _lines, tokens in CANDIDATES:
        if name in DENY_GLOBAL:
            bump("deny_global")
            continue
        if node == "home" and name in DENY_HOME_DESTRUCTIVE:
            bump("deny_destructive")
            continue
        if allow is not None and name not in allow:
            bump("deny_context")
            continue
        if tokens is not None and not (tokens & handled):
            bump("no_affordance")
            continue
        elig.append(name)
    return elig, skips


# ── the crawl (BFS, replay-from-boot) ───────────────────────────────────────────

class Crawl:
    def __init__(self, cfg, packages):
        self.cfg = cfg
        self.packages = packages
        self.states = {}        # hash -> {"fluents","node","seed","depth"}
        self.transitions = []   # {"pre","gesture","post","added","removed"}
        self.skips = {"deny_global": 0, "deny_context": 0, "deny_destructive": 0,
                      "no_affordance": 0, "depth_cap": 0, "state_cap": 0,
                      "self_loop": 0}

    def _fresh(self):
        return Emu(self.cfg, self.packages)

    def run(self):
        queue = deque()
        # Seed states (sorted by seed name for determinism).
        for seed in sorted(SEEDS):
            lines = list(SEEDS[seed])
            e = self._fresh()
            try:
                e.replay(lines)
                fluents, handled = e.observe()
            finally:
                e.close()
            h = fhash(fluents)
            if h not in self.states:
                self.states[h] = {"fluents": fluents, "node": node_of(fluents),
                                  "seed": seed, "depth": 0, "handled": handled,
                                  "lines": lines}
                queue.append(h)

        # BFS.
        while queue:
            h = queue.popleft()
            st = self.states[h]
            if st["depth"] >= MAX_DEPTH:
                continue
            elig, skips = eligible_candidates(st["node"], st["handled"])
            for r, n in skips.items():
                self.skips[r] += n
            for name in elig:
                probe_lines = list(st["lines"]) + list(CAND_LINES[name]) + \
                    ["frames %d" % SETTLE]
                e = self._fresh()
                try:
                    e.replay(probe_lines)
                    post_fluents, post_handled = e.observe()
                finally:
                    e.close()
                post_h = fhash(post_fluents)
                if post_h == h:
                    self.skips["self_loop"] += 1
                    continue
                add, rem = delta(st["fluents"], post_fluents)
                self.transitions.append({"pre": h, "gesture": name, "post": post_h,
                                         "added": add, "removed": rem})
                if post_h not in self.states:
                    if len(self.states) >= MAX_STATES:
                        self.skips["state_cap"] += 1
                        continue
                    depth = st["depth"] + 1
                    self.states[post_h] = {
                        "fluents": post_fluents, "node": node_of(post_fluents),
                        "seed": st["seed"], "depth": depth, "handled": post_handled,
                        "lines": probe_lines}
                    if depth < MAX_DEPTH:
                        queue.append(post_h)
                    else:
                        self.skips["depth_cap"] += 1
        # De-dup + sort transitions deterministically.
        seen = set()
        uniq = []
        for t in sorted(self.transitions, key=lambda x: (x["pre"], x["gesture"], x["post"])):
            key = (t["pre"], t["gesture"], t["post"])
            if key in seen:
                continue
            seen.add(key)
            uniq.append(t)
        self.transitions = uniq
        return self


# ── operator resolution (targeted drive + observe; perfect-oracle proofs) ───────

class Resolver:
    """Drives each of the 6 needs_crawl operators explicitly and records the
    observed precondition->gesture->effect with concrete fluent proofs."""

    def __init__(self, cfg, packages):
        self.cfg = cfg
        self.packages = packages

    def _fresh(self):
        return Emu(self.cfg, self.packages)

    def _empty_slot(self, e):
        return e.lua("(function() for _,c in ipairs(require('emu.UIState').describe()"
                     ".controls) do if c.class:find('EmptyControl',1,true) then "
                     "return c.slot end end return '' end)()")

    def _header_slot(self, e):
        return e.lua("(function() for _,c in ipairs(require('emu.UIState').describe()"
                     ".controls) do if c.class=='Unit.Base.Header' then return c.slot "
                     "end end return '' end)()")

    def resolve_all(self):
        out = []
        out.append(self._open_picker())
        out.append(self._insert())
        out.append(self._focus_unit())
        out.append(self._set_cell())
        out.extend(self._expand_collapse())
        return sorted(out, key=lambda x: x["id"])

    # open_picker: press the MAIN column holding EmptySection.EmptyControl.
    def _open_picker(self):
        proofs = []
        for label, setup in (("mono", SEEDS["boot"]), ("linked", SEEDS["linked12"])):
            e = self._fresh()
            try:
                e.replay(setup)
                pre, _ = e.observe()
                slot = self._empty_slot(e)          # e.g. "M3" / "M4"
                e.replay(["press MAIN%s" % slot[1:], "frames 15"])
                post, _ = e.observe()
            finally:
                e.close()
            proofs.append({"case": label, "empty_slot": slot,
                           "pre": fhash(pre), "post": fhash(post),
                           "opened": node_of(post) == "unit_picker_dense"})
        return {
            "id": "open_picker",
            "precondition": ["context(home)", "slot_control(M{i},EmptySection.EmptyControl)"],
            "gesture": ["press MAIN{i}", "frames 15"],
            "rule": "i = the MAIN slot index whose control is EmptySection.EmptyControl "
                    "(M3 on a mono chain; M4 after a stereo link adds a second input spot).",
            "effect": "context(unit_picker_dense)",
            "proofs": proofs,
        }

    # insert(u): from the open picker, `turn 3*row` then MAIN1 (left) / MAIN4 (right).
    def _insert(self):
        e = self._fresh()
        try:
            e.replay(["press MAIN3", "frames 12"])   # open picker (mono)
            # read the live 2-col picker so the row/side rule is grounded in data.
            grid = e.lua("(function() local w=require('Application').getVisibleContext()"
                         ":top(); local t={}; for i,row in ipairs(w.rows or {}) do "
                         "local L=row.left and row.left.title or '-'; "
                         "local R=row.right and row.right.title or '-'; "
                         "t[#t+1]=(i-1)..':'..L..'|'..R end; return table.concat(t,' ; ') "
                         "end)()")
            pre, _ = e.observe()
            # Test Osc sits at row index 1, right column -> turn 3 then MAIN4.
            e.replay(["turn %d" % ENCODER_DETENTS, "frames 6", "press MAIN4", "frames 30"])
            post, _ = e.observe()
            title = e.lua("require('Channels').getChain(1):getSelection().title")
            view = e.lua("(select(2, require('Channels').getChain(1):getSelection()))")
        finally:
            e.close()
        return {
            "id": "insert",
            "precondition": ["context(unit_picker_dense)"],
            "gesture": ["turn {3*row}", "frames 6", "press {MAIN1=left|MAIN4=right}",
                        "frames 30"],
            "rule": "The picker is a 2-column channel-count-filtered sorted list "
                    "(read live from window.rows). row = target row index (0-based); "
                    "N = 3 raw detents/row (EncoderThreshold.Default); pick MAIN1 for "
                    "the left cell, MAIN4 for the right. Lands home, unit focused+expanded.",
            "effect": ["unit_in_chain(u)", "focused_unit(u)", "context(home)"],
            "proofs": [{"picker_rows": grid, "picked": "row 1 right (turn 3, MAIN4)",
                        "title": title, "view": view,
                        "pre": fhash(pre), "post": fhash(post)}],
        }

    # focus_unit(u): the effect focused_unit(u) holds iff the chain SpottedStrip
    # cursor sits on u's section. Landing on u is exactly what insert does (the
    # freshly inserted unit auto-focuses), which is the clean observable proof that
    # focused_unit(u) is reachable + controllable. The encoder detent count to reach
    # an ALREADY-inserted, currently-unfocused unit is a live position lookup (a
    # single expanded unit fills M1-M6, so the section cursor only scrolls once the
    # chain holds more sections than the view -- an honest structural finding).
    def _focus_unit(self):
        e = self._fresh()
        try:
            e.replay(SEEDS["unit_inserted"])
            focused, _ = e.observe()                   # cursor auto-lands on the unit
            title = e.lua("require('Channels').getChain(1):getSelection().title")
            sel = e.lua("require('emu.UIState').selectionSectionClass()")
        finally:
            e.close()
        has_fu = any(f == ("focused_unit(%s)" % title) for f in focused)
        return {
            "id": "focus_unit",
            "precondition": ["context(home)", "unit_in_chain(u)"],
            "gesture": ["turn {N}", "frames 6"],
            "rule": "N = signed detents (3 raw/step) to move the chain SpottedStrip "
                    "section cursor to u; the count depends on u's live position in the "
                    "chain and the current cursor. focused_unit(u) holds iff the section "
                    "cursor sits on u's Unit section (selectionSectionClass=='Unit'); "
                    "landing on u is what insert does (auto-focus, proof below).",
            "effect": ["focused_unit(u)"],
            "proofs": [{"unit": title, "selection_class": sel,
                        "focused_unit_holds": has_fu, "state": fhash(focused)}],
        }

    # set_cell(slot,col,row,v): select_column, ENTER -> editingL1, encoder-nudge.
    def _set_cell(self):
        e = self._fresh()
        try:
            e.replay(SEEDS["sequencer"])
            pre, _ = e.observe()
            e.replay(["press MAIN6", "frames 6"])          # select_column(tr)
            col, _ = e.observe()
            v0 = e.lua("string.format('%.4f', app.AudioThread.getSequencerTask()"
                       ":l1Value(0,5,0))")
            e.replay(["press ENTER", "frames 6"])          # -> editingL1
            editing, _ = e.observe()
            e.replay(["turn %d" % ENCODER_DETENTS, "frames 6"])   # one nudge
            v1 = e.lua("string.format('%.4f', app.AudioThread.getSequencerTask()"
                       ":l1Value(0,5,0))")
            after, _ = e.observe()
        finally:
            e.close()
        return {
            "id": "set_cell",
            "precondition": ["context(sequencer)", "column_cursor(col)"],
            "gesture": ["press ENTER", "turn {nudges}", "frames 6"],
            "rule": "Enter L1 edit with ENTER (modal editingL1), then encoder-nudge to v. "
                    "The row is reached by scrolling focusHead in nav mode first. The "
                    "value is ARITHMETIC, not crawled: v = f(nudges) with a per-column "
                    "step (SEQUENCER.md); e.g. the tr/transpose column steps 1.0 per "
                    "encoder threshold (turn 3), so one nudge takes 0 -> 1.0.",
            "effect": ["modal(editingL1)", "cell(slot,col,row,v)"],
            "proofs": [{"col_hash": fhash(col), "editing_modal":
                        any(f == "modal(editingL1)" for f in editing),
                        "value_before": v0, "value_after_one_nudge": v1,
                        "pre": fhash(pre), "after": fhash(after)}],
        }

    # expand / collapse: focus the unit header (its MAIN column), then ENTER toggles
    # currentViewName collapsed<->expanded (Header:enterReleased). The header-focus
    # sub-state is OUTSIDE the fluent vocabulary, so this is driven, not BFS-found.
    def _expand_collapse(self):
        e = self._fresh()
        try:
            e.replay(SEEDS["unit_inserted"])       # Test Osc, expanded, header focused
            exp_fluents, _ = e.observe()
            exp_view = e.lua("(select(2, require('Channels').getChain(1):getSelection()))")
            hslot = self._header_slot(e)           # e.g. "M1"
            # focus the header spot, then ENTER toggles expanded -> collapsed.
            e.replay(["press MAIN%s" % hslot[1:], "frames 8", "press ENTER", "frames 15"])
            col_fluents, _ = e.observe()
            col_view = e.lua("(select(2, require('Channels').getChain(1):getSelection()))")
            # The header stays focused after the toggle, so a second ENTER re-expands
            # (collapsed -> expanded round-trip). Re-pressing the header MAIN here
            # would instead open its floating menu (spotReleased on an already-focused
            # spot), so ENTER alone is the correct re-toggle.
            e.replay(["press ENTER", "frames 15"])
            exp2_fluents, _ = e.observe()
            exp2_view = e.lua("(select(2, require('Channels').getChain(1):getSelection()))")
        finally:
            e.close()
        exp_slots = sorted(f for f in exp_fluents if f.startswith("slot_control("))
        col_slots = sorted(f for f in col_fluents if f.startswith("slot_control("))
        common = {
            "gesture": ["press {u_header_main}", "frames 8", "press ENTER", "frames 15"],
            "rule": "Press u's header MAIN column to focus its header spot, then ENTER "
                    "(Unit.Base.Header:enterReleased) toggles currentViewName "
                    "collapsed<->expanded. {u_header_main} = the live MAIN slot whose "
                    "control is Unit.Base.Header. The resulting slot_control map is "
                    "u-specific: manifest units[u].views.expanded / .collapsed.",
        }
        expand = dict(common)
        expand.update({
            "id": "expand",
            "precondition": ["context(home)", "focused_unit(u)", "collapsed view"],
            "effect": "slot_control map -> u.views.expanded (unit-specific)",
            "proofs": [{"from_view": col_view, "to_view": exp2_view,
                        "expanded_slots": sorted(f for f in exp2_fluents
                                                 if f.startswith("slot_control("))}],
        })
        collapse = dict(common)
        collapse.update({
            "id": "collapse",
            "precondition": ["context(home)", "focused_unit(u)", "expanded view"],
            "effect": "slot_control map -> u.views.collapsed (unit-specific)",
            "proofs": [{"from_view": exp_view, "to_view": col_view,
                        "expanded_slots": exp_slots, "collapsed_slots": col_slots}],
        })
        return [collapse, expand]


# ── deterministic map emission ──────────────────────────────────────────────────

def q(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def arr(items):
    return "[" + ", ".join(q(x) for x in items) + "]"


HEADER = (
    "# ER-301 (stolmine) UI planning domain -- EMPIRICAL CRAWL MAP.\n"
    "#\n"
    "# GENERATED by tools/ui_crawl.py [stol:ui-planner-crawler]; do NOT hand-edit.\n"
    "# Re-crawl + gate with `scripts/dev ui-crawl` (STOL_UPDATE_UI_CRAWL=1 accepts a\n"
    "# vetted change). Crawling drives the headless emu and is SLOW -- it is a manual\n"
    "# / CI gate ONLY, never on the commit path. Deterministic: seeded emu, sorted\n"
    "# output, byte-identical on an unchanged build.\n"
    "#\n"
    "# [[transition]]  pre-fluents --[gesture]--> post-fluents (added/removed delta),\n"
    "#                 keyed by fluent hash; single-gesture BFS observations.\n"
    "# [[state]]       the fluent set behind each hash.\n"
    "# [[resolved]]    the 6 needs_crawl operators (ui-operators.toml) resolved to a\n"
    "#                 precondition RULE + gesture SKELETON with driven proofs. The\n"
    "#                 solver consumes these alongside the static ui-operators.toml.\n"
    "# --------------------------------------------------------------------------------\n"
)


def emit(crawl, resolved):
    L = [HEADER.rstrip("\n"), ""]
    L.append("[meta]")
    L.append("schema = %d" % SCHEMA_VERSION)
    L.append("generator = %s" % q("tools/ui_crawl.py"))
    L.append("seeds = %s" % arr(sorted(SEEDS)))
    L.append("states = %d" % len(crawl.states))
    L.append("transitions = %d" % len(crawl.transitions))
    L.append("resolved = %d" % len(resolved))
    L.append("")
    L.append("[bounds]")
    L.append("max_depth = %d" % MAX_DEPTH)
    L.append("max_states = %d" % MAX_STATES)
    L.append("settle_frames = %d" % SETTLE)
    L.append("encoder_detents = %d" % ENCODER_DETENTS)
    L.append("unrestricted_nodes = %s" % arr(sorted(UNRESTRICTED)))
    L.append("# denylisted (never probed): destructive / irreversible gestures.")
    L.append("deny_global = %s" % arr(sorted(DENY_GLOBAL)))
    L.append("deny_home_header_commands = %s" % arr(sorted(DENY_HOME_DESTRUCTIVE)))
    L.append("")
    L.append("[bounds.safe_restricted]  # screen -> only these candidates probed")
    for node in sorted(SAFE_RESTRICTED):
        L.append("%s = %s" % (node, arr(sorted(SAFE_RESTRICTED[node]))))
    L.append("")
    L.append("[skipped]  # honest coverage: candidates NOT probed, by reason")
    for r in sorted(crawl.skips):
        L.append("%s = %d" % (r, crawl.skips[r]))
    L.append("")
    L.append("# Logical gesture -> control-protocol (docs/UI_OPERATION.md); the")
    L.append("# solver renders a resolved skeleton through this table.")
    L.append("[gesture_map]")
    for name, lines, _ in CANDIDATES:
        L.append("%s = %s" % (name, arr(lines)))
    L.append("")

    # transitions (already sorted).
    for t in crawl.transitions:
        L.append("[[transition]]")
        L.append("pre = %s" % q(t["pre"]))
        L.append("gesture = %s" % q(t["gesture"]))
        L.append("post = %s" % q(t["post"]))
        L.append("added = %s" % arr(t["added"]))
        L.append("removed = %s" % arr(t["removed"]))
        L.append("")

    # states (sorted by hash).
    for h in sorted(crawl.states):
        st = crawl.states[h]
        L.append("[[state]]")
        L.append("hash = %s" % q(h))
        L.append("node = %s" % q(st["node"]))
        L.append("fluents = %s" % arr(st["fluents"]))
        L.append("")

    # resolved operators (sorted by id).
    for r in resolved:
        L.append("[[resolved]]")
        L.append("id = %s" % q(r["id"]))
        pre = r["precondition"]
        L.append("precondition = %s" % arr(pre if isinstance(pre, list) else [pre]))
        L.append("gesture = %s" % arr(r["gesture"]))
        eff = r["effect"]
        L.append("effect = %s" % arr(eff if isinstance(eff, list) else [eff]))
        L.append("rule = %s" % q(r["rule"]))
        L.append("proof = %s" % q(_proof_str(r["proofs"])))
        L.append("")

    return "\n".join(L).rstrip("\n") + "\n"


def _proof_str(proofs):
    """Flatten a proof list to a single deterministic, sorted-key string."""
    parts = []
    for p in proofs:
        kv = "; ".join("%s=%s" % (k, _scalar(p[k])) for k in sorted(p))
        parts.append("{%s}" % kv)
    return " ".join(parts)


def _scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, list):
        return "[" + ",".join(str(x) for x in v) + "]"
    return str(v)


# ── build + cli ─────────────────────────────────────────────────────────────────

def build_map():
    cfg = ET.Config()
    packages = [p for p in os.environ.get("STOL_CRAWL_PACKAGES", "").split() if p]
    crawl = Crawl(cfg, packages).run()
    resolved = Resolver(cfg, packages).resolve_all()
    return emit(crawl, resolved), crawl, resolved


def selftest():
    """Offline determinism checks (no emu): the pure functions the crawl relies on."""
    failures = []

    def check(cond, msg):
        print("  [%s] %s" % ("PASS" if cond else "FAIL", msg))
        if not cond:
            failures.append(msg)

    print("ui_crawl.py --selftest (offline: hashing / projection / pruning / emit)")

    # fluent hashing is a pure function of the (always-sorted) projection list.
    check(fhash(["context(home)"]) == fhash(["context(home)"]), "fhash deterministic")
    check(fhash(["context(home)"]) != fhash(["context(scope)"]), "fhash distinguishes states")

    # projection via ui_fluents over a synthesized boot bundle (mirrors observe()).
    boot_bundle = {
        "uiState": {
            "stack": ["Chain.Root"], "focus": {"class": "Chain.Root"},
            "context": {"name": "OUT1 edit"},
            "controls": [
                {"slot": "M1", "class": "ChainTitleControl", "name": ""},
                {"slot": "M2", "class": "InputControl", "name": "1"},
                {"slot": "M3", "class": "EmptySection.EmptyControl", "name": ""},
            ],
            "modals": [],
        },
        "links": {"link12": False, "link23": False, "link34": False},
    }
    fl = ui_fluents.project(boot_bundle)
    check(node_of(fl) == "home", "node_of(boot projection) == home")
    check("slot_control(M3,EmptySection.EmptyControl)" in fl,
          "boot projection carries the empty-insert slot (open_picker precondition)")

    # affordance pruning: home probes mains but never the destructive header subs
    # nor the global eject; admin is restricted to its safe allowlist.
    handled = {"main1", "main2", "main3", "main4", "main5", "main6", "enterReleased",
               "sub1", "sub2", "sub3", "encoder"}
    elig, skips = eligible_candidates("home", handled)
    check("main3" in elig, "home eligible: main3 (open_picker opener)")
    check("enter" in elig, "home eligible: enter")
    check(all(s not in elig for s in ("sub1", "sub2", "sub3")),
          "home NEVER probes header sub-commands (delete/replace)")
    check("storage_down" not in elig, "eject is globally denylisted")
    check(skips.get("deny_destructive", 0) == 3, "3 header subs counted as skipped")
    aelig, _ = eligible_candidates("admin", {"main1", "main2", "main3", "main4"})
    check(set(aelig) <= {"main2", "cancel", "storage_up"},
          "admin restricted to its safe allowlist (no destructive submenu dives)")
    uelig, _ = eligible_candidates("some_unknown_screen", {"main1", "enterReleased"})
    check(set(uelig) <= DEFAULT_RESTRICT,
          "unknown screens only try to exit (never mutate)")

    # delta.
    add, rem = delta(["context(home)", "x"], ["context(scope)", "x"])
    check(add == ["context(scope)"] and rem == ["context(home)"], "delta added/removed")

    # emit determinism on a tiny synthetic crawl/resolved.
    class _C:
        states = {"aaaa": {"fluents": ["context(home)"], "node": "home"}}
        transitions = [{"pre": "aaaa", "gesture": "main3", "post": "bbbb",
                        "added": ["context(unit_picker_dense)"],
                        "removed": ["context(home)"]}]
        skips = dict.fromkeys(
            ["deny_global", "deny_context", "deny_destructive", "no_affordance",
             "depth_cap", "state_cap", "self_loop"], 0)
    res = [{"id": "open_picker", "precondition": ["context(home)"],
            "gesture": ["press MAIN{i}"], "effect": "context(unit_picker_dense)",
            "rule": "r", "proofs": [{"case": "mono", "empty_slot": "M3"}]}]
    t1 = emit(_C(), res)
    t2 = emit(_C(), res)
    check(t1 == t2, "emit is byte-deterministic")
    check("[[resolved]]" in t1 and "open_picker" in t1, "emit renders resolved ops")

    print()
    if failures:
        print("SELFTEST FAILED: %d check(s)" % len(failures))
        return 1
    print("SELFTEST OK")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", default=DEFAULT_OUT,
                    help="write the crawl map to PATH (default: the committed baseline)")
    ap.add_argument("--stdout", action="store_true",
                    help="print the map to stdout (no write) -- used by the gate")
    ap.add_argument("--selftest", action="store_true",
                    help="offline determinism checks (no emu)")
    args = ap.parse_args(argv[1:])

    if args.selftest:
        return selftest()

    text, crawl, resolved = build_map()
    if args.stdout:
        sys.stdout.write(text)
    else:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(text)
        sys.stderr.write(
            "wrote %d bytes to %s  (%d states, %d transitions, %d resolved; "
            "skipped %s)\n" % (
                len(text), args.output, len(crawl.states), len(crawl.transitions),
                len(resolved), ", ".join("%s=%d" % (k, crawl.skips[k])
                                         for k in sorted(crawl.skips))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

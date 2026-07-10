#!/usr/bin/env python3
"""er-301-stolmine ledger tool — the BDG traceability machine.

The ledger (planning/ledger.toml) is the single source of truth for work items.
This tool reconciles it against the code and tests, generates the human-readable
TODO (planning/TODO.md), and prints a session summary. It is deterministic and
exit-code-gated — the AI never sits in the gate; it only drafts prose from these
machine-readable facts.

Commands:
  check    Validate the ledger against itself + the tree. Exit 1 on any hard
           violation (the commit gate). Warnings never fail.
  render   Regenerate planning/TODO.md from the ledger.
  status   Print a short summary (counts, open WIP, violations) for the hooks.

Grain: one item = one independently-verifiable behavior (a test / screenshot /
gate). Code references an item as a [stol:<id>] comment tag at its impl seam.

Ported from Ligature's tools/ledger.py per planning/ledger-regime-portable.md.
"""

import datetime
import fnmatch
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Paths are env-overridable ONLY so the parallel-infra self-tests can run against
# a COPY of the ledger / claims in a tmp dir (never the real files). Unset =
# today's paths.
LEDGER = Path(os.environ.get("STOL_LEDGER") or (ROOT / "planning" / "ledger.toml"))
TODO = Path(os.environ.get("STOL_TODO") or (ROOT / "planning" / "TODO.md"))
CLAIMS = Path(os.environ.get("STOL_CLAIMS") or (ROOT / "planning" / "claims.toml"))
# Firmware source trees, repo-relative. NEVER add `testing/` here — it is build
# output (generated artifacts), not source or tests; scan() also skips it.
SRC_DIRS = [ROOT / "od", ROOT / "xroot", ROOT / "emu", ROOT / "hal", ROOT / "mods"]
# Test harness is future work: tests/ does not exist yet. collect_testcases()
# returns an empty set, so the orphan-test rule is vacuously satisfied until a
# real harness lands (see collect_testcases + the note in the portability spec).
TEST_DIRS = [ROOT / "tests"]

STATUSES = {"todo", "wip", "done", "blocked"}
AREAS = {"ui", "sequencer", "scenes", "i2c", "dsp", "emu", "docs", "infra"}
TAG_RE = re.compile(r"\[stol:([a-z0-9][a-z0-9-]*)\]")
TESTCASE_RE = re.compile(r'TEST_CASE\("([^"]*)"\)')

# ANSI (only when a tty)
def _c(code):
    return code if sys.stdout.isatty() else ""
RED, YEL, GRN, DIM, BOLD, RST = (_c(x) for x in ("\033[31m", "\033[33m", "\033[32m", "\033[2m", "\033[1m", "\033[0m"))


def load_items():
    with open(LEDGER, "rb") as f:
        data = tomllib.load(f)
    return data.get("item", [])


def scan(dirs, exts):
    """Yield (path, text) for every source file under dirs with a matching ext.

    Any path with a `testing/` component is skipped: that tree is build output,
    not source, and must never be scanned for tags or tests.
    """
    for d in dirs:
        if not d.exists():
            continue
        for p in d.rglob("*"):
            if "testing" in p.parts:
                continue
            if p.suffix in exts and p.is_file():
                yield p, p.read_text(errors="replace")


def collect_tags():
    """id -> [relpaths] for every [stol:<id>] tag in the source + test trees."""
    tags = {}
    for p, text in scan(SRC_DIRS + TEST_DIRS, {".c", ".cpp", ".h", ".hpp", ".lua"}):
        for m in TAG_RE.finditer(text):
            tags.setdefault(m.group(1), []).append(str(p.relative_to(ROOT)))
    return tags


def collect_testcases():
    # No test harness yet: TEST_DIRS (tests/) does not exist, so this returns an
    # empty set and the orphan-test rule is vacuously satisfied. The doctest
    # TEST_CASE("...") regex is kept as a placeholder for when a harness lands.
    names = set()
    for _p, text in scan(TEST_DIRS, {".cpp"}):
        names.update(TESTCASE_RE.findall(text))
    return names


def validate(items):
    """Return (errors, warnings). errors fail the gate; warnings never do."""
    errors, warnings = [], []
    ids = [it.get("id") for it in items]

    # schema + uniqueness
    seen = set()
    for it in items:
        iid = it.get("id")
        if not iid:
            errors.append(f"item with no id: {it.get('title', '?')!r}")
            continue
        if iid in seen:
            errors.append(f"duplicate id: {iid}")
        seen.add(iid)
        if it.get("status") not in STATUSES:
            errors.append(f"{iid}: bad status {it.get('status')!r} (want {sorted(STATUSES)})")
        if it.get("area") not in AREAS:
            errors.append(f"{iid}: bad area {it.get('area')!r} (want {sorted(AREAS)})")
        v = it.get("verify") or {}
        if v.get("kind") not in {"test", "screenshot", "manual"}:
            errors.append(f"{iid}: verify.kind must be test|screenshot|manual")
        links = it.get("links") or {}
        for rel in ("depends_on", "supersedes"):
            for tgt in links.get(rel, []):
                if tgt not in ids:
                    errors.append(f"{iid}: links.{rel} -> unknown item {tgt!r}")
        # optional write-footprint lease target (parallel-infra claims); tolerate
        # it, but if present it must be a list of glob strings.
        touches = it.get("touches")
        if touches is not None and not (
                isinstance(touches, list) and all(isinstance(t, str) for t in touches)):
            errors.append(f"{iid}: touches must be a list of glob strings")
        # optional machine timestamp (pipeline-timestamps): written by the gate,
        # never required; if present it must be a string.
        stamped = it.get("stamped")
        if stamped is not None and not isinstance(stamped, str):
            errors.append(f"{iid}: stamped must be a string (machine-written; "
                          f"see scripts/dev now)")

    tags = collect_tags()
    tests = collect_testcases()

    # every test a ledger item CLAIMS (verify.ref for kind=test, plus any tests[]).
    claimed = set()
    for it in items:
        v = it.get("verify") or {}
        if v.get("kind") == "test" and v.get("ref"):
            claimed.add(v["ref"])
        for t in it.get("tests", []):
            claimed.add(t)

    # orphan tags: a [stol:x] in code with no matching item
    for tag_id, locs in tags.items():
        if tag_id not in seen:
            errors.append(f"orphan tag [stol:{tag_id}] (no such item) in {locs[0]}")

    # ORPHAN TESTS (code -> ledger direction): every TEST_CASE must be claimed by
    # some item. This is what stops "I built + tested a behavior but never
    # ledgered it" from passing silently — you cannot add a test without an item.
    # (Vacuous today: no test harness, so `tests` is empty.)
    for t in sorted(tests - claimed):
        errors.append(f'untracked TEST_CASE("{t}") — no ledger item claims it '
                      f"(add it to an item's verify.ref or tests[])")

    # a concretely-listed tests[] entry must actually exist (catches typo/rename)
    for it in items:
        for t in it.get("tests", []):
            if t not in tests:
                errors.append(f'{it.get("id")}: tests[] names a missing TEST_CASE("{t}")')

    # done items: their verification must be real, not a zero-friction claim
    for it in items:
        iid, status = it.get("id"), it.get("status")
        if status != "done" or not iid:
            continue
        v = it.get("verify") or {}
        kind = v.get("kind")
        if kind == "test":
            if v.get("ref", "") not in tests:
                errors.append(f"{iid}: DONE but its test is missing: TEST_CASE(\"{v.get('ref')}\")")
        else:
            # No silent soft-done: a done item not backed by a test must carry an
            # explicit, non-empty `attested` string (a conscious, auditable claim).
            if not (it.get("attested") or "").strip():
                errors.append(f"{iid}: DONE with verify.kind={kind!r} needs an "
                              f"`attested = \"...\"` line (soft verify can't be silent)")
        # anchor: an item flagged anchor=true must carry a [stol:id] tag in src.
        if it.get("anchor") and iid not in tags:
            errors.append(f"{iid}: DONE anchor=true but no [stol:{iid}] tag found in src/")

    # generated doc must match the ledger (no hand-edits, no forgotten render).
    # The "Rendered YYYY-MM-DD" stamp is normalised out so a day rolling over
    # never fails the gate on an untouched tree (commit's render refreshes it).
    try:
        rendered_re = re.compile(r"\*Rendered \d{4}-\d{2}-\d{2}\.\*")
        if TODO.exists() and (rendered_re.sub("*Rendered*", TODO.read_text())
                              != rendered_re.sub("*Rendered*", render_text(items))):
            errors.append("planning/TODO.md is stale/hand-edited — run: scripts/dev render")
    except Exception as e:  # never let the doc check crash the gate
        warnings.append(f"could not verify TODO.md render: {e}")

    return errors, warnings


def cmd_check(_args):
    items = load_items()
    errors, warnings = validate(items)
    for w in warnings:
        print(f"{YEL}warn{RST} {w}")
    for e in errors:
        print(f"{RED}FAIL{RST} {e}")
    if errors:
        print(f"\n{RED}{BOLD}ledger check: {len(errors)} error(s){RST} "
              f"({len(warnings)} warning(s)) — commit blocked.")
        return 1
    print(f"{GRN}ledger check: OK{RST} ({len(items)} items, {len(warnings)} warning(s)).")
    return 0


def cmd_status(_args):
    items = load_items()
    by_status = {}
    for it in items:
        by_status.setdefault(it.get("status"), []).append(it)
    counts = " ".join(f"{s}:{len(by_status.get(s, []))}"
                      for s in ("done", "wip", "todo", "blocked") if by_status.get(s))
    print(f"{BOLD}ledger{RST} {counts}  ({len(items)} items)")
    wip = by_status.get("wip", [])
    if wip:
        print(f"{BOLD}in progress:{RST}")
        for it in wip:
            print(f"  · {it['id']} — {it['title']}")
    errors, warnings = validate(items)
    if errors:
        print(f"{RED}{len(errors)} gate violation(s):{RST}")
        for e in errors[:10]:
            print(f"  {RED}✗{RST} {e}")
    elif warnings:
        print(f"{DIM}{len(warnings)} warning(s) (run: scripts/dev check){RST}")
    else:
        print(f"{GRN}gate clean.{RST}")
    return 0


AREA_TITLES = {
    "ui": "UI / interaction", "sequencer": "Sequencer", "scenes": "Scenes / hold-mode",
    "i2c": "I2C / external control", "dsp": "DSP units", "emu": "Emulator",
    "docs": "Documentation", "infra": "Infrastructure",
}
STATUS_MARK = {"done": "✓", "wip": "~", "todo": " ", "blocked": "✗"}


def render_text(items):
    lines = []
    lines.append("ER-301-STOLMINE TODO (generated — DO NOT EDIT)")
    lines.append("=============================================")
    lines.append("")
    lines.append("*Generated from `planning/ledger.toml` by `scripts/dev render`. Edit the")
    lines.append("ledger, not this file. Status/verification are gate-enforced (`scripts/dev")
    lines.append("check`): a `done` item must have a real test or its named artifact.*")
    lines.append("")
    # counts
    c = {}
    for it in items:
        c[it["status"]] = c.get(it["status"], 0) + 1
    summary = ", ".join(f"{c.get(s,0)} {s}" for s in ("done", "wip", "todo", "blocked") if c.get(s))
    lines.append(f"**{len(items)} items** — {summary}. *Rendered {_now_iso()[:10]}.*")
    lines.append("")
    for area in ["sequencer", "scenes", "ui", "dsp", "i2c", "emu", "docs", "infra"]:
        group = [it for it in items if it.get("area") == area]
        if not group:
            continue
        lines.append(f"## {AREA_TITLES.get(area, area)}")
        lines.append("")
        lines.append("| | id | item | verify |")
        lines.append("|---|---|---|---|")
        order = {"wip": 0, "todo": 1, "blocked": 2, "done": 3}
        for it in sorted(group, key=lambda i: (order.get(i["status"], 9), i["id"])):
            v = it.get("verify") or {}
            vtxt = f"{v.get('kind')}: {v.get('ref')}" if v.get("kind") != "manual" else "manual"
            if it.get("attested"):
                vtxt += " *(attested)*"
            if it.get("stamped"):  # machine stamp: date of the last status change
                vtxt += f" · {str(it['stamped'])[:10]}"
            mark = STATUS_MARK.get(it["status"], "?")
            lines.append(f"| {mark} | `{it['id']}` | {it['title']} | {vtxt} |")
        lines.append("")
    return "\n".join(lines) + "\n"


def cmd_render(_args):
    items = load_items()
    TODO.write_text(render_text(items))
    try:
        shown = TODO.relative_to(ROOT)
    except ValueError:
        shown = TODO.name  # STOL_TODO points outside the repo (a self-test copy)
    print(f"rendered {shown} ({len(items)} items)")
    return 0


# ── parallel-infra: fragment append ──────────────────────────────────────────
# Parallel agents never edit the shared ledger tail concurrently; new items
# arrive as FRAGMENT FILES (a [[item]] array) that this command validates and
# appends verbatim. Same schema as the main ledger; the append is refused whole
# if anything is wrong (dup id / missing field / unknown dep / bad shape).

def validate_fragment(frag_items, existing_ids):
    """Return a list of errors for a fragment's items against the ledger's ids.

    Mirrors the schema half of validate() (no test/tag scan — a fragment names
    new work, its tests need not exist yet). Refuses: missing id/title/status/
    area, bad status/area, bad verify.kind, ids colliding with the ledger or
    within the fragment, and depends_on/supersedes targets unknown in either.
    """
    errors = []
    existing = set(existing_ids)
    frag_ids = []
    seen = set()
    for it in frag_items:
        iid = it.get("id")
        if not iid:
            errors.append(f"fragment item with no id: {it.get('title', '?')!r}")
            continue
        if iid in existing:
            errors.append(f"duplicate id {iid!r}: already in the ledger")
        if iid in seen:
            errors.append(f"duplicate id {iid!r}: appears twice in the fragment")
        seen.add(iid)
        frag_ids.append(iid)
        for field in ("title", "status", "area"):
            val = it.get(field)
            if not (val.strip() if isinstance(val, str) else val):
                errors.append(f"{iid}: missing required field {field!r}")
        if it.get("status") not in STATUSES:
            errors.append(f"{iid}: bad status {it.get('status')!r} (want {sorted(STATUSES)})")
        if it.get("area") not in AREAS:
            errors.append(f"{iid}: bad area {it.get('area')!r} (want {sorted(AREAS)})")
        v = it.get("verify") or {}
        if v.get("kind") not in {"test", "screenshot", "manual"}:
            errors.append(f"{iid}: verify.kind must be test|screenshot|manual")
    known = existing | set(frag_ids)
    for it in frag_items:
        iid = it.get("id")
        if not iid:
            continue
        links = it.get("links") or {}
        for rel in ("depends_on", "supersedes"):
            for tgt in links.get(rel, []):
                if tgt not in known:
                    errors.append(f"{iid}: links.{rel} -> unknown item {tgt!r}")
    return errors


def cmd_append(args):
    if not args:
        print("usage: ledger.py append <fragment.toml>", file=sys.stderr)
        return 2
    frag_path = Path(args[0])
    if not frag_path.exists():
        print(f"{RED}FAIL{RST} fragment not found: {frag_path}")
        return 1
    try:
        with open(frag_path, "rb") as f:
            frag_data = tomllib.load(f)
    except Exception as e:
        print(f"{RED}FAIL{RST} {frag_path}: not valid TOML ({e})")
        return 1
    frag_items = frag_data.get("item", [])
    if not frag_items:
        print(f"{RED}FAIL{RST} {frag_path}: no [[item]] entries")
        return 1

    existing_ids = [it.get("id") for it in load_items()]
    errors = validate_fragment(frag_items, existing_ids)
    if errors:
        for e in errors:
            print(f"{RED}FAIL{RST} {e}")
        print(f"\n{RED}{BOLD}fragment refused: {len(errors)} error(s){RST} — ledger unchanged.")
        return 1

    # Append verbatim (preserve the author's formatting) with a blank-line gap,
    # then regenerate the TODO so the ledger and its doc stay coherent. Each
    # appended item is stamped with machine time (pipeline-timestamps).
    frag_text = frag_path.read_text().strip("\n")
    frag_text, _ = _stamp_items_in_text(
        frag_text + "\n", {it.get("id") for it in frag_items}, _now_iso())
    frag_text = frag_text.strip("\n")
    ledger_text = LEDGER.read_text().rstrip("\n")
    LEDGER.write_text(ledger_text + "\n\n" + frag_text + "\n")
    items = load_items()
    TODO.write_text(render_text(items))
    ids = ", ".join(it.get("id") for it in frag_items)
    print(f"{GRN}appended {len(frag_items)} item(s){RST}: {ids} "
          f"→ {LEDGER.name}; rendered {TODO.name}.")
    return 0


# ── parallel-infra: claims (write-footprint leases) ──────────────────────────
# One agent per FOOTPRINT (not per repo) is the contention law. `claim` records
# item+branch+footprint in planning/claims.toml; a second claim whose footprint
# INTERSECTS a live lease on another branch is refused. Glob intersection is
# deliberately CONSERVATIVE — when in doubt, intersect (a false collision only
# serialises two agents; a missed one lets them corrupt each other).

def _static_prefix(glob):
    """The leading '/'-joined path components of a glob before any wildcard."""
    out = []
    for part in glob.strip("/").split("/"):
        if any(c in part for c in "*?["):
            break
        out.append(part)
    return "/".join(out)


def _path_prefix(short, long):
    """True if `short` is a whole-component path prefix of `long` (or equal)."""
    sp, lp = short.split("/"), long.split("/")
    return lp[: len(sp)] == sp


def globs_intersect(a, b):
    """Could two repo-relative path globs ever match a common file? Conservative."""
    a, b = a.strip("/"), b.strip("/")
    if a == b:
        return True
    # either glob matching the other as a literal path (handles dir/*.ext cases)
    if fnmatch.fnmatchcase(a, b) or fnmatch.fnmatchcase(b, a):
        return True
    pa, pb = _static_prefix(a), _static_prefix(b)
    # a leading wildcard means no static anchor -> could be anywhere -> intersect
    if not pa or not pb:
        return True
    # shared subtree (one static prefix contains the other) -> intersect
    if _path_prefix(pa, pb) or _path_prefix(pb, pa):
        return True
    return False


def footprints_intersect(fa, fb):
    """True if any glob in footprint fa intersects any glob in fb."""
    return any(globs_intersect(x, y) for x in fa for y in fb)


def load_claims():
    if not CLAIMS.exists():
        return []
    with open(CLAIMS, "rb") as f:
        return tomllib.load(f).get("claim", [])


def _toml_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_claims(claims):
    lines = ["# Live write-footprint leases — `scripts/dev claim/release/claims`.",
             "# Coordination state (commits like the ledger). Generated; do not hand-edit.",
             ""]
    for c in claims:
        touches = ", ".join(_toml_str(t) for t in c.get("touches", []))
        lines += ["[[claim]]",
                  f"item = {_toml_str(c['item'])}",
                  f"branch = {_toml_str(c['branch'])}",
                  f"touches = [{touches}]",
                  f"at = {_toml_str(c.get('at', ''))}",
                  ""]
    CLAIMS.write_text("\n".join(lines).rstrip("\n") + "\n")


def _parse_flag(args, flag):
    """Pop `--flag VALUE` from args, returning (value_or_None, remaining_args)."""
    out, val = [], None
    i = 0
    while i < len(args):
        if args[i] == flag and i + 1 < len(args):
            val = args[i + 1]
            i += 2
        else:
            out.append(args[i])
            i += 1
    return val, out


def cmd_claim(args):
    branch, args = _parse_flag(args, "--branch")
    touches_override, items = _parse_flag(args, "--touches")
    if not branch:
        print("usage: ledger.py claim --branch <b> [--touches g,g] <item...>", file=sys.stderr)
        return 2
    if not items:
        print(f"{RED}FAIL{RST} nothing to claim (name at least one item id)")
        return 1
    override = [t.strip() for t in touches_override.split(",") if t.strip()] if touches_override else None

    ledger = {it.get("id"): it for it in load_items()}
    claims = load_claims()
    # resolve each item's footprint (its `touches`, or the --touches override)
    want = []  # (item, footprint)
    for iid in items:
        if iid not in ledger:
            print(f"{RED}FAIL{RST} unknown item {iid!r} (not in the ledger)")
            return 1
        fp = override or ledger[iid].get("touches")
        if not fp:
            print(f"{RED}FAIL{RST} {iid}: no `touches` footprint in the ledger — "
                  f"pass one with --touches g,g")
            return 1
        want.append((iid, fp))

    # refuse if any requested footprint intersects a live lease on ANOTHER branch
    for iid, fp in want:
        for c in claims:
            if c["branch"] == branch:
                continue
            if footprints_intersect(fp, c.get("touches", [])):
                print(f"{RED}FAIL{RST} {iid}: footprint {fp} intersects live claim "
                      f"'{c['item']}' on branch '{c['branch']}' (touches {c.get('touches')}).")
                print(f"{RED}claim refused{RST} — footprints must be disjoint across branches.")
                return 1

    # accept: add/refresh this branch's claims (idempotent per item)
    now = _now_iso()
    kept = [c for c in claims if not (c["branch"] == branch and c["item"] in dict(want))]
    for iid, fp in want:
        kept.append({"item": iid, "branch": branch, "touches": fp, "at": now})
    write_claims(kept)
    claimed = ", ".join(iid for iid, _ in want)
    print(f"{GRN}claimed{RST} on {branch}: {claimed}")
    return 0


def cmd_release(args):
    branch, items = _parse_flag(args, "--branch")
    if not branch:
        print("usage: ledger.py release --branch <b> [<item...>]  (no items = whole branch)",
              file=sys.stderr)
        return 2
    claims = load_claims()
    before = len(claims)
    if items:
        drop = set(items)
        kept = [c for c in claims if not (c["branch"] == branch and c["item"] in drop)]
        what = ", ".join(items)
    else:
        kept = [c for c in claims if c["branch"] != branch]
        what = "all items"
    write_claims(kept)
    print(f"{GRN}released{RST} on {branch}: {what} ({before - len(kept)} lease(s) cleared)")
    return 0


def cmd_claims(_args):
    claims = load_claims()
    if not claims:
        print(f"{DIM}no live claims.{RST}")
        return 0
    by_branch = {}
    for c in claims:
        by_branch.setdefault(c["branch"], []).append(c)
    print(f"{BOLD}live claims{RST} ({len(claims)} lease(s), {len(by_branch)} branch(es)):")
    for branch, cs in sorted(by_branch.items()):
        print(f"  {BOLD}{branch}{RST}")
        for c in cs:
            print(f"    · {c['item']:<28} {DIM}{c.get('touches')}{RST}")
    return 0


# ── parallel-infra: commit fence ─────────────────────────────────────────────
# do_commit calls this AFTER render+check, on the staged diff. STRICTLY OPT-IN:
# if the current branch holds no claim, it returns 0 in silence and the serial
# path is byte-identical. When the branch DOES hold claims, every staged path
# must fall inside (union of claimed footprints) + a fixed always-allowed set,
# and planning/ledger.toml is policed BLOCK-LEVEL: only [[item]] blocks the
# branch has claimed may change, and direct appends are refused (use fragments).

LEDGER_REL = "planning/ledger.toml"
CLAIMS_REL = "planning/claims.toml"
TODO_REL = "planning/TODO.md"


def _git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)


def file_matches(f, glob):
    """Is repo-relative path f covered by a footprint glob (file / dir / pattern)?"""
    g = glob.rstrip("/")
    if f == g or f.startswith(g + "/"):
        return True
    return fnmatch.fnmatchcase(f, glob)


def _split_item_blocks(text):
    """(preamble, {id: body}) — body is the text after each '[[item]]' marker
    line up to the next marker/EOF, so any field change shows as a body diff."""
    parts = re.split(r"(?m)^\[\[item\]\][ \t]*\n", text)
    preamble = parts[0].rstrip()
    blocks = {}
    for chunk in parts[1:]:
        m = re.search(r'(?m)^id\s*=\s*"([^"]+)"', chunk)
        # rstrip the body so an append/remove elsewhere (which shifts the trailing
        # blank line of the neighbouring block) never reads as a spurious change.
        blocks[m.group(1) if m else f"<no-id:{len(blocks)}>"] = chunk.rstrip()
    return preamble, blocks


def _check_ledger_blocks(claimed_ids, branch):
    r = _git("show", f"HEAD:{LEDGER_REL}")
    old = r.stdout if r.returncode == 0 else ""
    new = LEDGER.read_text()
    old_pre, ob = _split_item_blocks(old)
    new_pre, nb = _split_item_blocks(new)
    viol = []
    if old_pre != new_pre:
        viol.append(f"{LEDGER_REL}: preamble (text before the first [[item]]) changed "
                    f"— only claimed [[item]] blocks may change")
    for iid in sorted(set(nb) - set(ob)):
        viol.append(f"{LEDGER_REL}: item {iid!r} appended directly — use a fragment + ledger-append")
    for iid in sorted(set(ob) - set(nb)):
        viol.append(f"{LEDGER_REL}: item {iid!r} removed — the fence forbids deletions")
    for iid in sorted(set(ob) & set(nb)):
        if ob[iid] != nb[iid] and iid not in claimed_ids:
            viol.append(f"{LEDGER_REL}: item {iid!r} changed but branch {branch!r} did not claim it")
    return viol


def _check_claims_ownership(branch):
    r = _git("show", f"HEAD:{CLAIMS_REL}")
    old_text = r.stdout if r.returncode == 0 else ""
    new_text = CLAIMS.read_text() if CLAIMS.exists() else ""

    def others(text):
        try:
            data = tomllib.loads(text)
        except Exception:
            return None
        return sorted((c.get("branch"), c.get("item"), tuple(c.get("touches", [])))
                      for c in data.get("claim", []) if c.get("branch") != branch)

    o, n = others(old_text), others(new_text)
    if o is None or n is None:
        return [f"{CLAIMS_REL}: could not parse to verify own-branch-only edits"]
    if o != n:
        return [f"{CLAIMS_REL}: edits touch OTHER branches' claims "
                f"(only branch {branch!r}'s own entries may change)"]
    return []


def cmd_fence(_args):
    branch = _git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    branch_claims = [c for c in load_claims() if c.get("branch") == branch]
    if not branch_claims:
        return 0  # OPT-OUT: no claim on this branch => today's behavior, exactly.

    footprint = list(dict.fromkeys(g for c in branch_claims for g in c.get("touches", [])))
    claimed_ids = {c["item"] for c in branch_claims}
    slug = branch.replace("/", "-")
    frag_glob = f"planning/fragments/{slug}-*.toml"
    staged = [f for f in _git("diff", "--cached", "--name-only").stdout.splitlines() if f]

    viol = []
    for f in staged:
        if f == LEDGER_REL:
            viol += _check_ledger_blocks(claimed_ids, branch)
        elif f == CLAIMS_REL:
            viol += _check_claims_ownership(branch)
        elif f == TODO_REL or fnmatch.fnmatchcase(f, frag_glob):
            continue  # always-allowed: regenerated doc / this branch's fragments
        elif not any(file_matches(f, g) for g in footprint):
            viol.append(f"{f}: outside branch {branch!r}'s claimed footprint")

    if viol:
        print(f"{RED}{BOLD}commit fence: {len(viol)} violation(s) on {branch}{RST}")
        for v in viol:
            print(f"  {RED}✗{RST} {v}")
        print(f"{DIM}allowed = footprint {footprint or '[]'} + "
              f"[{TODO_REL}, {CLAIMS_REL} (own entries), {frag_glob}] + "
              f"claimed ledger blocks {sorted(claimed_ids)}{RST}")
        return 1
    print(f"{GRN}commit fence OK{RST} ({len(staged)} staged file(s) within {branch}'s footprint).")
    return 0


# ── pipeline timestamps ──────────────────────────────────────────────────────
# Humans (and agents) guess dates; the machine knows. `now` is the ONE blessed
# way to learn the current date/time (never write a date from memory — ask
# `scripts/dev now`), and `stamp` writes machine truth into the ledger at commit
# time: every [[item]] that is NEW or whose *status* changed vs HEAD gets a
# `stamped = "<now>"` field. Status transitions only — note/attested edits never
# restamp (no churn). Existing items without the field are simply unstamped
# (stamps go forward only; historical drift is not rewritten).

def _now_iso():
    """ISO-8601 local date-time with UTC offset, second precision."""
    return datetime.datetime.now().astimezone().replace(microsecond=0).isoformat()


def cmd_now(_args):
    print(_now_iso())
    return 0


STAMPED_LINE_RE = re.compile(r'(?m)^stamped\s*=\s*"[^"]*"[ \t]*\n')
STATUS_LINE_RE = re.compile(r"(?m)^status\s*=.*\n")


def _stamp_block(block, now):
    """Write/refresh the `stamped` line in one [[item]] block's text."""
    line = f'stamped = "{now}"\n'
    if STAMPED_LINE_RE.search(block):
        return STAMPED_LINE_RE.sub(line, block, count=1)
    m = STATUS_LINE_RE.search(block)
    if m:  # insert right under status — the field the stamp dates
        return block[: m.end()] + line + block[m.end():]
    return block.rstrip("\n") + "\n" + line


def _stamp_items_in_text(text, targets, now):
    """Stamp every [[item]] block in `text` whose id is in `targets`.
    Returns (new_text, stamped_ids); all other bytes are preserved verbatim."""
    marks = [m.start() for m in re.finditer(r"(?m)^\[\[item\]\][ \t]*\n", text)]
    if not marks:
        return text, []
    out, stamped = [text[: marks[0]]], []
    for s, e in zip(marks, marks[1:] + [len(text)]):
        chunk = text[s:e]
        m = re.search(r'(?m)^id\s*=\s*"([^"]+)"', chunk)
        iid = m.group(1) if m else None
        if iid in targets:
            chunk = _stamp_block(chunk, now)
            stamped.append(iid)
        out.append(chunk)
    return "".join(out), stamped


def cmd_stamp(_args):
    r = _git("show", f"HEAD:{LEDGER_REL}")
    try:
        old = tomllib.loads(r.stdout).get("item", []) if r.returncode == 0 else []
    except Exception:
        old = []
    old_status = {it.get("id"): it.get("status") for it in old}
    text = LEDGER.read_text()
    try:
        new_items = tomllib.loads(text).get("item", [])
    except Exception as e:
        print(f"{RED}FAIL{RST} ledger not parseable: {e}")
        return 1
    targets = {it["id"] for it in new_items if it.get("id")
               and (it["id"] not in old_status or old_status[it["id"]] != it.get("status"))}
    if not targets:
        return 0  # no new item, no status transition — zero churn
    now = _now_iso()
    new_text, stamped = _stamp_items_in_text(text, targets, now)
    if not stamped:
        return 0
    LEDGER.write_text(new_text)
    print(f"stamped {len(stamped)} item(s) @ {now}: {', '.join(sorted(stamped))}")
    return 0


def main():
    cmds = {"check": cmd_check, "render": cmd_render, "status": cmd_status,
            "append": cmd_append, "claim": cmd_claim, "release": cmd_release,
            "claims": cmd_claims, "fence": cmd_fence, "now": cmd_now,
            "stamp": cmd_stamp}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        print(f"usage: ledger.py {{{'|'.join(cmds)}}}", file=sys.stderr)
        return 2
    return cmds[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())

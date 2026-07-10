# Porting the ledger + BDG regime within the 301 ecosystem

*Repo-specific companion to Ligature's `planning/ledger-regime-portable.md`
(the canonical spec — read it first; this doc does not repeat it). Audience: a
session standing up the regime in another 301 repo — first target
`er-301-habitat`. er-301-stolmine is the first 301 implementation (commit
`c6b8253`, 2026-07-09); **copy the four pieces from THIS repo, not from
Ligature** — the 301 adaptations below are already applied here.*

The four pieces as implemented here:

| piece | stolmine file |
|---|---|
| ledger tool | `tools/ledger.py` |
| blessed entrypoint | `scripts/dev` |
| hooks | `tools/hooks/gate_bash.py`, `tools/hooks/stop_check.py`, wired in `.claude/settings.json` |
| the ledger | `planning/ledger.toml` (preamble = schema doc) + generated `planning/TODO.md` |

## 1. What stolmine changed vs Ligature (the applied delta)

- Env prefix `STOL_*`; tag `[stol:<id>]`; paths `planning/{ledger.toml,TODO.md,claims.toml}`.
- `AREAS = {ui, sequencer, scenes, i2c, dsp, emu, docs, infra}`.
- `SRC_DIRS = [od, xroot, emu, hal, mods]`, tag-scan extensions include `.lua`.
- `TEST_DIRS = [tests]` — intentionally nonexistent; see §2.2.
- Commit path is **stamp → render → check → add → fence → commit, with NO
  build step** (firmware builds are release-dance events, not per-commit
  events) and **commits on the default branch (develop) are allowed** —
  both deliberate departures from Ligature.
- `gate_bash.py` blocks only raw `git commit` / `git push` (no cmake/ctest
  here; `make` stays unblocked).
- Ligature-only `usage` / `new-unit` subcommands not ported.
- Trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## 2. 301-ecosystem facts the regime must respect

These are the things a fresh porter would get wrong by following only the
Ligature doc.

1. **The release dance stays OUTSIDE `scripts/dev`.** 301 repos derive their
   version from git tags via `scripts/env.mk` (`git describe --match
   'v*.*.*-*'`). The tagging protocol is strict and has burned us repeatedly:
   commit first THEN tag, never two version tags on one commit, clean rebuild
   after tagging. `scripts/dev commit` never creates tags and must never grow
   that ability — a release is: gated commit(s), then the manual tag + clean
   rebuild protocol. The dev-digit convention (`9.3.0.N`, `0.2.0.N` during
   development) is likewise orthogonal to ledger stamps; `attested` lines cite
   release tags/shas, item `stamped` timestamps are machine-written and mean
   nothing about firmware versions.

2. **No test harness exists anywhere in the ecosystem (2026-07).** All `done`
   items are `manual`/`screenshot` + `attested`. `TEST_DIRS` points at a
   nonexistent `tests/` so the orphan-test rule is vacuous, and the doctest
   regex is a placeholder. Do NOT point test discovery at `testing/` — in 301
   repos **`testing/` is build output** (object files), not tests. The tag
   scanner here skips any `testing/` path component defensively; keep that.

3. **The verification substrate that upgrades this is the headless emu**
   (stolmine ledger items `emu-headless-boot` … `emu-capture-deterministic`).
   Once the emulator can boot headless, take scripted control input, and dump
   pixel-exact framebuffer PNGs, `verify.kind="screenshot"` becomes a
   byte-diffable BDG gate (deterministic capture = golden baseline), and
   scripted scenarios become the ecosystem's first real `kind="test"`. This
   matters cross-repo: **package repos (habitat) run inside the stolmine
   emu**, so one headless emu serves every repo's verification. Plan
   ledgers accordingly — habitat items can name future emu-scripted checks
   as their intended verification without blocking on them today.

4. **Lua is a first-class source language.** Tag scanning covers `.lua`;
   anchor comments look like `-- [stol:some-id]` (or the target repo's
   prefix). Middle-layer behaviors usually seam in Lua, DSP behaviors in C++.

5. **Hardware-gated verification is a real category.** Some behaviors are
   only verifiable on the am335x bench (TXo needs a live I2C bus; NEON/AAPCS
   and package-trig issues do not reproduce in the emu; per
   `docs/KNOWLEDGE.md`, package `.so` trig miscomputes on hardware only).
   Convention: the `attested` line states WHERE it was verified —
   "bench-verified on hardware YYYY-MM-DD" vs "emu-verified" — so nobody
   mistakes an emu pass for a hardware pass.

6. **Root-TODO conventions differ per repo; audit before archiving.**
   stolmine's root `TODO.md` was a frozen posterity menu → consolidated into
   the ledger and archived with a stub (2026-07-09). habitat's `todo.md` is
   LIVE and actively worked. Porting there means **migrating** open items
   into ledger items (fragments), not blind archiving — see §3.

7. **Where errors surface** (for any future `dev test`/verify flow): Lua
   runtime errors land in `~/.od/front/crash.log` FIRST, not the emulator's
   stdout/`/tmp/emu.log`.

8. **Ledger-edit safety applies with extra force here** — these repos carry
   large hand-written planning docs, and the temptation to hand-edit the
   ledger tail is constant. Fragments + `scripts/dev ledger-append` is the
   only sanctioned way to add items. Never write a date from memory; use
   `scripts/dev now`.

## 3. Per-target notes

### er-301-habitat (next target)

- **Shape:** 11 packages under `mods/` (mi, kryos, peaks, scope, spreadsheet,
  biome, catchall, porcelain, house, anamnesis, stolmine), each built via
  `mods/<pkg>/mod.mk`, top-level `make` fans out. C++ DSP + Lua middle layer.
  Per-package version tags with the dev-digit convention.
- **Tag prefix:** `[hab:<id>]`. Env prefix `HAB_*`.
- **`do_build`:** `make -j4` (all packages) with the job cap; consider
  `dev build <pkg>` passthrough since per-package iteration is the norm.
  No build in the commit path (same reasoning as stolmine).
- **Areas:** prefer concern buckets over per-package buckets (11 packages
  would blow the 4–8 area budget and packages already namespace themselves in
  ids/titles). Suggested: `{dsp, units, ui, seq, tooling, docs, infra}` —
  e.g. `pecto-neon-gather` gets area `dsp`, `excel-playhead-wrap` gets `seq`.
  Encode the package in the item id prefix (`pecto-*`, `ballot-*`), which
  habitat's todo.md already does informally.
- **Backfill sources:** `todo.md` (live: checked boxes → recent `done` items,
  unchecked → `todo` items — this is a MIGRATION, then archive+stub like
  stolmine), `RELEASE-*.md` files (release-grain shipped behavior), and
  `planning/*.md` (design docs; reference from item `note` fields, do not
  ledger a doc as an item). The checked-box entries in todo.md are unusually
  good `attested` raw material — many already cite shas and dev versions.
- **Verification:** everything is `manual`+`attested` today; the stolmine
  headless emu (§2.3) is the intended future substrate. Hardware-gated items
  (NEON, trig-LUT, CPU-load behaviors) follow the §2.5 attestation
  convention — habitat has been burned by emu-vs-hardware divergence more
  than any other repo (see stolmine memory: mi swap-crash, package trig LUT).
- **Branch policy:** habitat commits to its default branch; keep the
  stolmine behavior (no default-branch refusal).

### Other 301 repos

- **er-301-units / er-301-custom-units / smaller package repos:** same shape
  as habitat, smaller. Same port, smaller area set, backfill from their
  READMEs/history.
- **er-301 vendored upstream mirror(s):** read-mostly; per the Ligature doc's
  guidance, the value is inventory/traceability (`manual`+`attested` pointer
  items), not a build gate. Port the tool + ledger, skip the hooks if the
  repo is never driven by an agent session.
- **bcdevices-platform / rp2350-audio-mvp / bcd_ui_301 (private hardware
  line):** viable targets later; their bench-bring-up logs are effectively
  attested items already. Tag prefixes `[bcd:]` etc. Not in scope until the
  CM4 work resumes a steady cadence.

## 4. Bootstrap sequence for a 301 repo

Same as the Ligature doc §8, with these substitutions: copy the four pieces
from **stolmine**; rename `STOL_`/`[stol:]`/areas/paths for the target; keep
the no-build commit path and default-branch-allowed behavior; do the root-TODO
audit (§2.6) BEFORE the backfill so migration and inventory are one pass; and
run the same first-stretch advisory-first discipline.

*When stolmine's copies and this doc drift, the code wins — update this doc.*

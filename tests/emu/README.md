# tests/emu — headless emulator test suite

Automated UI/behavior tests for the ER-301 headless emulator, run by
`tools/emu_test.py`. Each `*.test` file is a script of control-protocol commands
plus runner directives; the runner boots a fresh, hermetic emulator per test,
drives it over stdin/stdout, and reports TAP. See
`planning/headless-emu-plan.md` (§2 protocol, §6 determinacy, §7 harness) for the
design and `testing-assets/emu/ui-map.toml` for the UI graph the tests navigate.

## Running

```sh
scripts/dev test                     # whole suite (gated: skips if no emu binary)
python3 tools/emu_test.py            # whole suite, TAP to stdout, exit 0 iff all pass
python3 tools/emu_test.py 10-admin-nav   # one test by basename
python3 tools/emu_test.py --selftest # validate the RUNNER itself (no emu needed)
```

The emu binary defaults to `testing/linux-x86_64/emu/emu.elf`; override with
`STOL_EMU_BIN`. A per-test watchdog defaults to 60 s (`STOL_EMU_TEST_TIMEOUT`).
Sandboxes are deleted on pass and **kept on fail** (the path is printed) — set
`STOL_KEEP_SANDBOX=1` to keep them all.

> These tests need the new `--headless` emu core (control channel, `lua`/`cap`,
> `--seed`). Until that lands they will fail to boot; the runner reports a clean
> watchdog failure and `scripts/dev test` only invokes it once the binary exists.

## File format

One directive per line. Blank lines and `#` comments are ignored.

**Control-protocol commands** (passed to the emu verbatim, planning §2): each
must reply `ok …`; an `err …` reply fails the test.

| command | meaning |
|---|---|
| `down B` / `up B` | press / release button B (MAIN1-6, DIAL1-3, SUB1-3, ENTER, UP, SHIFT, SELECT1-4) |
| `press B [ms]` | down, hold, up |
| `turn N` | encoder delta (signed) |
| `mode P` / `storage P` | toggle switch to absolute position P = up / center / down |
| `wait MS` | delay (loop-timed) |
| `frames N` | wait N rendered frames — the settle primitive (use this, not `wait`) |
| `stable N [timeout]` | resolve when N consecutive frames are byte-identical |
| `cap PATH` | screenshot both displays to PATH (PNG) |
| `lua CODE` | run CODE on the app Lua thread; reply carries the result |
| `quit` | clean shutdown |

**Runner directives** (interpreted by `tools/emu_test.py`, never sent verbatim):

| directive | meaning |
|---|---|
| `!packages NAME` | before boot, copy `NAME-*.pkg` into the sandbox front package repo (see below). Header directive — position-independent. |
| `!golden NAME` | `cap` to `<sandbox>/NAME.png`, then byte-compare against `testing-assets/emu/goldens/<test>/NAME.png`. Missing golden fails with an instruction to re-run with `STOL_UPDATE_GOLDEN=1`; that env overwrites/creates it and reports `# updated`. |
| `!assert LUA` | send `lua LUA`; require the reply value to be `true`, else fail showing the reply. Recognize predicates from `ui-map.toml` go here. |
| `!expect REGEX` | require the reply of the **preceding** command to match REGEX (an escape hatch for asserting on a raw reply). |

## Goldens & determinism

- Goldens live in `testing-assets/emu/goldens/<test>/<name>.png` (NOT under
  `testing/`, which is build output). Byte-compared, so they must be
  **deterministic**: capture only after a `frames N` (or `stable`) settle, and
  only on **static** screens.
- The settings fixture disables GUI animation and sets the screensaver to its
  max, which removes most motion. The one thing it does **not** freeze is the
  global "breathing cursor" tween (phase = frames-since-boot, never settles):
  screens showing it are out of golden scope in v1 — assert state with `!assert`
  instead. See planning §6.
- Gate on **frames, not milliseconds**. Host load changes wallclock but not the
  frame-indexed tween/render sequence, so `frames`/`stable` keep runs identical.
- Regenerate goldens only deliberately (`STOL_UPDATE_GOLDEN=1`), and say why in
  the commit message — a golden change is a behavior-diff-gate (BDG) accept.

## `!packages` and the sandbox

Fixtures ship **without** packages (`.pkg` files are build products). A test that
needs units declares `!packages core` (or any package name). At sandbox assembly
the runner copies the matching archive into the sandbox's front package
repository — `front/ER-301/packages/`, which is where
`xroot/Package/Manager.lua:51` scans — sourced from, in order:
`$STOL_EMU_PKG_DIR`, `testing/linux-x86_64/mods/`,
`~/.od/front/ER-301/packages/`, `~/.od/rear/`. A requested package that is found
in none of these fails the test with a clear message.

Everything else about the hermetic sandbox (front/rear roots, generated
`emu.config`, disabled confirmations) is documented in
`testing-assets/emu/fixtures/README.md`.

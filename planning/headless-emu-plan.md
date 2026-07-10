# Headless scriptable emulator — implementation plan

*Spec for the ledger items `emu-headless-boot`, `emu-control-channel`,
`emu-cmd-buttons`, `emu-cmd-encoder`, `emu-cmd-toggles`, `emu-capture-fb`,
`emu-capture-deterministic`, `emu-lua-eval`. Ledger notes point here; when
plan and code drift, update both.*

## 0. Discoveries that shaped the design (verified 2026-07-09)

1. **Capture already exists.** `UIThread::saveScreenShotTo(filename)`
   (`od/UIThread.cpp:199-273`) composites BOTH displays (main 256x64 4bpp +
   sub 128x64 1bpp) into one grayscale PNG via vendored lodepng, and is
   SWIG-exposed to Lua (`app.UIThread.saveScreenShotTo`, used by the existing
   screenshot hotkey in `xroot/Application.lua:113`). We reuse it verbatim —
   no new decode code. Its sanctioned calling context is the Lua thread.
2. **The `emu` SWIG module is the bridge surface.** `emu/emu.cpp.swig` +
   `emu/emu.h` already expose emu-side C++ to Lua (`emu.*`); adding control
   queue accessors there is the established pattern (same surface the HCI
   overlay uses).
3. **The Lua app loop is an event pump.** `xroot/Application.lua` waits on
   `app.Events_wait`/`Events_pull` and has an `EVENT_DISPLAY_READY` branch
   (line ~506) that runs once per UI frame — the natural place to drain a
   control-command queue (guarded by `app.EMULATION` + a cheap
   `emu.hasControlInput()` check; no new HAL event id needed).
4. **Input is two primitives.** All buttons/toggles are `Gpio_write()` and
   the encoder is an integer accumulator (`emu/Emulator.cpp:71-161`).
   Button GPIO is INVERTED: pressed = `false`.
5. **DSP pacing = SDL audio callback** (`emu/hal/audio.c` `playCallback` →
   `Audio_callback`). Headless does NOT change this. For a machine with no
   audio device, `SDL_AUDIODRIVER=dummy` is the intended escape hatch —
   **verify in Phase A that SDL's dummy driver still invokes the callback
   at simulated-realtime pace**; if it doesn't, Phase A adds a fallback
   pacer thread that calls `Audio_callback` on a timer. This is the plan's
   only open technical risk.

## 1. Architecture

```
              stdin (default) or FIFO (--control PATH)
                        │ line protocol
            ┌───────────▼────────────┐
            │ C++ control reader     │  emu/Control.cpp (new), thread or
            │ parse + dispatch       │  polled non-blocking in Emulator::loop
            └───┬───────────────┬────┘
   input cmds   │               │  lua / cap cmds
   (GPIO-level, │               │  (queued, LockFreeQueue)
   C++ direct)  │               │
        ┌───────▼──────┐   ┌────▼─────────────────────────┐
        │ Gpio_write / │   │ emu.popControlLine() drained │
        │ encoderValue │   │ per frame by Application.lua │
        └──────────────┘   │ under app.EMULATION; load()  │
                           │ + pcall; reply via           │
                           │ emu.pushControlReply(s)      │
                           └──────────────────────────────┘
```

- **Input commands run at GPIO level in C++** — they exercise the same
  polling/debounce path as real key input, so scripted gestures are faithful.
- **Lua commands run on the Lua thread** — queued through the emu module,
  drained once per UI frame. No cross-thread interpreter calls, no new
  locking (reuse `od::LockFreeQueue`).
- **Capture is Lua sugar**: `cap PATH` enqueues
  `return app.UIThread.saveScreenShotTo("PATH")` — proven code path, correct
  thread, deterministic PNG.
- **Replies** are written back to the control channel (stdout by default) as
  one line per command: `ok [detail]` / `err <msg>`. Lua replies carry the
  pcall result (tostring'd) so introspection assertions read as text.

## 2. Command grammar (line protocol, one command per line)

| command | effect |
|---|---|
| `down B` / `up B` | press / release button `B` = MAIN1-6, DIAL1-3, SUB1-3, ENTER, UP, SHIFT, SELECT1-4 (Gpio inverted-logic handled inside) |
| `press B [ms]` | down, hold (default 60 ms, ≥2 UI frames), up — timed via loop scheduler, not sleep |
| `turn N` | encoder: `encoderValue += N` (signed, raw detent units as SDL arrows use) |
| `mode P` / `storage P` | absolute toggle position `P` = up, center, down (drive `switchUp`/`switchDown` from read state) |
| `wait MS` | delay next command dispatch (loop-timed) |
| `frames N` | wait N display frames (settle convention for capture) |
| `cap PATH` | screenshot both displays to PATH (PNG, via saveScreenShotTo) |
| `lua CODE` | run CODE on the Lua thread; reply = pcall result |
| `quit` | clean shutdown (same path as SDL_QUIT) |

Commands execute strictly in order; `wait`/`frames`/`stable`/`press`/`lua` gate
the queue, so a script is deterministic without host-side sleeps.

**Reply sigil (as built 2026-07-09).** The firmware logs to *stdout* unprefixed
(`emu/hal/log.c` → `Uart_write` → `fwrite(stdout)`), so control replies are
prefixed with `@` and terminated by a newline, letting a harness filter them
with a `^@` match. Replies:

- `@ready` — unsolicited, pushed once by `Application.lua` the first time the
  drain runs (boot-complete handshake; scripts wait for it).
- `@ok` / `@ok <detail>` — command succeeded. `lua`/`cap` carry the tostring'd
  pcall result (`@ok 2`, `@ok true`); `stable` carries the resolving frame index.
- `@err <msg>` — parse error, bad/missing argument, unknown command or button,
  or `@err timeout` when a `stable` gate expires.

`press` replies `@ok` only after its scheduled release fires (it gates the
queue for the hold). Toggle positions accept `up|center|down` (`middle` aliases
`center`). `turn N` adds raw detent units to the encoder accumulator (no scale
factor), matching the SDL arrow-key path. Under `--headless`, EOF on stdin with
nothing pending and no active gate exits cleanly, so a trailing `quit` is
optional.

## 3. Phases → ledger items

**A. `emu-headless-boot`** — `--headless` flag: `SDL_VIDEODRIVER=dummy`, no
`Window` construction (null-guard the ~6 `window->` touches in
`Emulator.cpp`; skip window state in save/restoreState), loop pacing and
display queues unchanged. Verify: boots to the menu, runs 10 s, `quit`
exits 0, no X/Wayland connection. Also settle risk 0.5 (dummy audio pacing).

**B. `emu-control-channel`** — reader (stdin default; `--control PATH` FIFO
optional), parser, ordered dispatch queue, `wait`/`frames`/`quit`, `ok`/`err`
replies. New file `emu/Control.{h,cpp}`; hooks in `Emulator::loop`. Works in
windowed mode too (SDL input and scripted input coexist).

**C. `emu-cmd-buttons` / `emu-cmd-encoder` / `emu-cmd-toggles`** — the input
command set on the primitives from §0.4. Includes measuring the minimum
reliable hold (instrument the firmware's GPIO poll cadence; default `press`
hold = 60 ms unless measurement says otherwise; document in the reply to
`press` when a hold was shorter than the safe minimum).

**D. `emu-lua-eval`** — the bridge (§1): `emu.h` gains
`hasControlInput()/popControlLine()/pushControlReply()`; `Application.lua`
EVENT_DISPLAY_READY branch drains under `app.EMULATION`. SWIG char-handling
per repo lore: C strings only. This lands BEFORE capture (capture rides it).

**E. `emu-capture-fb`** — `cap` sugar + verify a captured PNG of a known
static screen (admin menu) opens and matches the on-screen content.

**F. `emu-capture-deterministic`** — same scripted sequence twice from clean
boot → byte-identical PNGs on a static screen (`cmp` exit 0). Establish the
golden-baseline convention: scripts + baselines under `testing-assets/emu/`
(NOT `testing/`, which is build output); animated screens need `frames N`
settle or are out of golden scope. This is the item that turns
`verify.kind="screenshot"` into a real BDG gate.

## 4. File touch list (as built 2026-07-09)

- `emu/Emulator.{h,cpp}` — `--headless`/`--control`/`--seed` parsing, window
  null-guards, control read+dispatch+gate state machine, timed `press`
  scheduler, `@`-reply helper. Also registers the `emu` Lua module via a local
  `EmuInterpreter : AppInterpreter` subclass (the base's `L` is `protected`, so
  the subclass calls `luaL_requiref(L, "emu", luaopen_emu, 1)`) — this avoids
  touching `od/glue/AppInterpreter.cpp`, keeping kernel.bin untouched.
- `emu/Control.{h,cpp}` (new) — non-blocking fd (stdin/FIFO) line reader plus
  the two SPSC `LockFreeQueue<char*>` bridges (loop→lua, lua→loop). Auto-globbed
  into the build by `emu.mk`'s recursive `*.cpp` wildcard (no manual listing).
- `emu/emu.h` + `emu/emu.cpp` — the three Lua-bridge free functions (appended,
  ABI-safe), delegating to the process-wide `controlChannel()`.
- `emu/hal/rng.c` — `--seed` splitmix64 deterministic mode; `Rng_seed(uint32_t)`
  is defined here and forward-declared in `Emulator.cpp` (NOT added to
  `hal/rng.h`, so the firmware header is untouched). Unseeded path unchanged.
- `xroot/Application.lua` — `drainControl()` helper (defined before
  `onDisplayReady` to avoid a nil forward-binding) called from `onDisplayReady`
  under `app.EMULATION`.
- `scripts/emu.mk` — add `emu/emu_swig.o` (the SWIG `emu` module, previously
  built only into `libemu.so`) to the `emu.elf` object list.
- No firmware-side (`od/`, `hal/`) changes at all; kernel.bin unaffected.

## 5. Risks and conventions

- **SDL dummy audio callback pacing** — RESOLVED 2026-07-09. Measured with a
  temporary counter in `playCallback` under `SDL_AUDIODRIVER=dummy`: the dummy
  driver fires the callback at simulated-realtime pace (~400 calls over ~90 UI
  frames). No fallback pacer thread needed; probe removed after measurement.
- **GPIO poll cadence / min hold** — measured 2026-07-09. The emulator is NOT
  polled: `emu/hal/gpio.c` `Gpio_write` pushes the PRESS/RELEASE event
  synchronously at the edge (no debounce), so any hold ≥0 registers a tap. The
  only frame-quantized step is `hal/events.cpp` `check()` (button-repeat +
  encoder delta), run once per `Events_wait()` ≈ once per UI frame (~14–18 ms).
  REPEAT needs the button held ~`REPEAT_DELAY+REPEAT_PERIOD` = 28 frames
  (~0.4 s). So the 60 ms `press` default (~3–4 frames) is a safe tap that spans
  ≥1 frame yet never trips repeat; kept at 60 ms.
- **Boot-time commands**: the C++ queue accepts input before Lua is up;
  Application.lua pushes an unsolicited `ready` line when the drain starts —
  scripts begin with waiting for `ready`.
- **Animated UI** (cursor blink, meters, screensavers): goldens target
  static screens after `frames` settle; no masking in v1.
- **Windowed + scripted simultaneously** is supported (useful for demos and
  for watching a script drive the UI); `--headless` only controls the window.
- **`[stol:<id>]` anchors**: each phase's implementation seam gets its item's
  anchor tag; flip `anchor = true` on the item in the same commit.

## 6. Determinacy threat model (added 2026-07-09, pre-implementation)

Verified code facts: UI tweens are FRAME-INDEXED (`od/graphics/Graphic.cpp`
TWEENSTEP per rendered frame), not wallclock — so all test gating is in frames.
The global tween (cursor breath) phase = frames-since-boot and never settles;
goldens avoid breath regions in v1 (option later: a tween-reset helper).
`od::Random::init` seeds from `Rng_read32()` entropy — headless adds `--seed N`
(emu/hal/rng.c only, no firmware change). Screensaver idle timer is a setting —
the harness fixture disables it.

Threats + countermeasures:
1. Card-state bleed (recents/favorites/settings/boot count in ~/.od) →
   hermetic per-run sandbox from committed fixtures, generated emu.config.
2. RNG entropy → --seed.
3. Breath phase varies with boot wallclock → frame gating post-`ready`;
   goldens avoid breathing cursors.
4. Wallclock UI (toasts, hold thresholds, screensaver) → press durations far
   from gesture thresholds; `stable` primitive; fixture disables screensaver.
5. Audio-reactive regions (meters/scope/VU) → silent/static fixture patches.
6. Boot variance → `ready` line + lua-predicate waits, never fixed sleeps.
7. Host-load pacing → frames not ms.
8. Version/boot-count text → goldens avoid; release regen is a BDG accept.
9. Cross-test contamination → one process + fresh sandbox per test.
10. UI↔audio handshake timing → `!assert` lua predicates for state waits.

New control primitive: `stable N [timeoutFrames]` — resolve when N consecutive
rendered frames are byte-identical (fails to `err timeout` otherwise).

## 7. Harness layer

- `tools/emu_test.py` (stdlib-only runner): discovers `tests/emu/*.test`
  (control-protocol scripts + runner directives `!golden NAME` / `!assert LUA`),
  per test: build sandbox from `testing-assets/emu/fixtures/`, write emu.config,
  spawn `emu.elf --headless --seed 301`, drive stdin/stdout with a watchdog
  timeout, compare captures against `testing-assets/emu/goldens/`, TAP output,
  nonzero exit on any fail. `STOL_UPDATE_GOLDEN=1` regenerates (deliberate only,
  reason in commit message).
- `scripts/dev test` runs the harness when `tests/emu/` exists.
- Ledger: when the harness lands, test names (script basenames) become
  claimable test cases — the orphan-test rule flips live (adapt TESTCASE
  discovery in ledger.py to scan tests/emu/*.test).

## 8. UI map

`testing-assets/emu/ui-map.toml`: nodes = UI contexts (home, admin, picker,
settings, sequencer takeover, ...) each with a `recognize` lua predicate and
the fixture assumptions it needs; edges = gesture sequences (control-protocol
lines) between nodes. Scripts/agents plot courses through the graph instead of
hand-guessing button sequences; the runner can assert arrival via the node
predicate. Derived from xroot sources + GETTING_STARTED.md + SEQUENCER.md;
maintained as code changes (it is itself BDG-checkable later via a
reachability smoke test).

## 9. Harness-layer implementation notes (added 2026-07-09, tools/emu_test.py)

Built alongside the emu core. Where the harness's realized design differs from
the sketch above, this section is authoritative; reconcile the two when they drift.

- **`!packages NAME` targets the FRONT package repo, not "rear root".** §7 called
  the sandbox package destination the rear root, but the emu reads its `.pkg`
  repository from `0:/ER-301/packages` on the FRONT card (`xroot/Package/
  Manager.lua:51`) and installs into rear libs. The runner therefore copies
  `NAME-*.pkg` into `<sandbox>/front/ER-301/packages/`. Sources, in order:
  `$STOL_EMU_PKG_DIR`, `testing/linux-x86_64/mods/`, `~/.od/front/ER-301/
  packages/`, `~/.od/rear/`. OPEN for integration: whether the emu auto-installs
  a repo archive on boot, or whether a pre-install step / rear-meta `packages` db
  entry is also needed for units to appear in the picker.

- **Determinism lever beyond §6:** the settings fixture also sets
  `animation = "disabled"` (freezes GUI tweens so screens settle at once) and
  `restoreLastSlotAction = "no"` (the default `prompt` pops a boot dialog that
  would block scripted boot). Screensaver is set to its max ("1 day") since there
  is no "off". The breathing-cursor tween is still not frozen — goldens avoid it.

- **`!expect REGEX` asserts on the PRECEDING command's reply**, not a freshly read
  line — every control command already consumes exactly one reply in lockstep, so
  "the next reply" is stored as `last_reply` and `!expect` matches it. Escape
  hatch for pattern-matching a raw reply (e.g. after a `lua`).

- **Reply parsing tolerates two framings.** The runner treats a stdout line
  starting with `REPLY_SIGIL` (`@`) as a reply and normalizes both `@ok true`
  and bare `@true` for `!assert` (strips a leading `ok `). Recognize predicates in
  `ui-map.toml` are written as bare Lua expressions (no `return`/`local`) so they
  work whether the core evals `lua CODE` as `load("return "..CODE)` or with a
  return-prefix-then-fallback. The sigil + `READY_TOKEN` are single constants at
  the top of `tools/emu_test.py` — the integration seam.

- **emu.session hermeticity caveat.** `Emulator::loadConfiguration` overrides
  XROOT/FRONT_ROOT/REAR_ROOT but NOT `sessionFilename`, which stays
  `~/.od/emu.session` (window geometry). Harmless for headless app-state
  determinism (card state is fully sandboxed), but if headless ever persists
  meaningful state there, route it through the sandbox too.

- **Verified at bench (pre-core):** the current emu boots cleanly on the hermetic
  fixtures to "Application.loop: entering event loop" with fresh card state (boot
  count 1, last slot -1) and no `~/.od` bleed; it does not yet emit `@ready`
  (control channel unlanded), so the watchdog fails the test cleanly with a log
  tail — the exact expected integration boundary.

## 10. Integration findings (2026-07-09, verified live)

Both agent workstreams integrated and driven against the real emu.elf:

- **Session-bleed determinism bug found + fixed.** `~/.od/emu.session` is NOT
  sandboxed, and `restoreState`/`saveState` round-trip the STORAGE + MODE toggle
  GPIO through it. A prior run's toggle state therefore bled into every later
  boot, changing the boot context (MODE bled → ScopeView vs Chain.Root; STORAGE
  bled → admin vs user). Fix: headless mode skips restoreState/saveState
  entirely and sets a fixed default (STORAGE=user, MODE=0 → boots on
  `user`/`Chain.Root`). This was invisible until live driving — it masked the
  true boot default in BOTH directions. Lesson for the fixture model: state can
  leak through paths outside FRONT_ROOT/REAR_ROOT.
- **Verified boot default:** clean headless boot lands on context `Admin`? no —
  top window `Chain.Root`, storage state `user`. `animation="disabled"` in the
  settings fixture freezes tweens, so static screens are golden-stable (admin
  golden generated and re-matched byte-identical).
- **Toggle map (verified):** `storage up`→user (Chain.Root), `storage center`→
  admin (Menu / instance Admin), `storage down`→eject (Card.StatusViewer).
- **Picker nav still open:** the unit chooser opens from a focused empty insert
  section only; the chain-cursor gesture to reach it at boot is undiscovered.
  Parked as tests/emu/20-picker-open.test.todo, owned by emu-ui-map.
- **Suite status:** 00-boot + 10-admin-nav green against real emu; runner,
  sandbox, seed, capture, determinism, stable all confirmed on hardware paths.

## 11. Next phase: UI trace hooks → map completion → picker nav (plan 2026-07-09)

Ordering insight: build the trace hooks FIRST, because they are the tool that
makes UI-map discovery and the parked picker-nav problem tractable (drive a
gesture, watch the @trace stream name the context transition instead of guessing).

### 11a. emu-ui-trace-hooks (mostly Lua)
- New EMULATION-only module (e.g. `xroot/emu/Trace.lua`) that, when enabled,
  wraps the verified seams and emits `@trace <frame> <kind> <detail>`:
  - `Application.setVisibleContext` (xroot/Application.lua:78) → `context show/hide`
  - `Context:add` / `Context:remove` (xroot/Base/Context.lua:107,126; both funnel
    through the internal `topChanged` at :6 — wrap the public methods, not the
    local) → `window push/pop <className>`
  - `Window:show` / `Window:hide` (xroot/Base/Window.lua:23,33) → optional, lower
    priority; context+stack events are the load-bearing set.
- Emission is async via `emu.pushControlReply("@trace ...")` — already callable
  from the Lua thread; NO new C++ bridge needed for output.
- Frame stamp: reuse/extend the per-frame counter in the onDisplayReady path
  (xroot/Application.lua:172) so trace frames align with the harness `frames`
  gate. Deterministic per the §6 clock model.
- Control command `trace on [filter] | off | mark LABEL`: add to the C++ command
  parser as sugar that enqueues the corresponding `lua require('emu.Trace')...`
  call (keeps scripts readable; `mark` injects a `@trace <frame> mark LABEL` line
  for correlating trace regions with test phases). Default filter = context+stack
  only (Signal.emit is too chatty; leave it opt-in behind a filter token).
- Guard: all wrapping installed only under `app.EMULATION` and only while
  enabled — zero hardware impact, zero cost when off.

### 11b. emu-trace-golden (Python runner)
- New directive `!trace-golden NAME`: the runner enables trace at the point of
  the directive (or the test opts in at top), captures the @trace stream for the
  test, normalizes it (decide: strip frame numbers for a route-only golden, or
  keep them bucketed — raw frames are deterministic but brittle to unrelated
  timing edits; default to STRIPPING frames, keeping kind+detail order), and
  byte-compares against `testing-assets/emu/goldens/<test>/<NAME>.trace`.
  STOL_UPDATE_GOLDEN=1 regenerates; mismatch prints a unified diff naming the
  first divergent transition.
- This is the middle verification tier (route correctness) between `!assert`
  (state) and `!golden` (pixels).

### 11c. Picker nav discovery + UI-map completion (uses 11a)
- With trace on, probe chain-cursor gestures from the boot Chain.Root focus to
  find the route onto an empty insert section (the chooser opens from
  EmptyControl/InsertControl:activateChooser, xroot/Chain/EmptySection.lua:56, via
  ENTER/spot/SUB3 once that ply is focused). The unknown is purely the cursor-move
  gesture; the trace stream will show when Unit.Chooser.Dense is pushed.
- Verify every edge in testing-assets/emu/ui-map.toml live; correct gestures and
  confidence levels; add an `arrival` event field per edge (the expected @trace
  line) so the reachability smoke test can cross-check map vs observed trace.
- Restore `tests/emu/20-picker-open.test.todo` → `.test` once the route is known;
  add a `!trace-golden picker-route` to it as the first trace-golden in the suite.
- Add a reachability smoke test (`tests/emu/30-ui-map-reachability.test` or a
  runner mode) that walks each map edge and asserts arrival.

Ledger items: emu-ui-trace-hooks, emu-trace-golden, emu-ui-map. Do NOT self-flip;
verification + flip happens after review against the running emu.

### 11d. As-built (2026-07-09, verified live) — authoritative where it differs above

- **Trace module = `xroot/emu/Trace.lua`** (require name `emu.Trace`), loaded
  lazily in Application.lua only under `app.EMULATION`. Wraps
  `Application.setVisibleContext` (context show/hide) and `Context:add`/`:remove`
  (window push/pop); Window:show/hide were NOT wrapped (redundant — add/remove
  already capture every stack change). Emits `trace <frame> <kind> <detail>`
  (the C++ `ctlReply` adds the `@` sigil). Idempotent on/off; default filter =
  `context,stack`. Frame stamp is a module counter advanced by `Trace.tick()`
  called once per frame from `onDisplayReady`.
- **C++ command `trace on [filter] | off | mark LABEL`** added to
  `Emulator::handleControlLine` — sugar that enqueues `require('emu.Trace').on/off/mark`
  on the Lua thread. The reply-drain gate now ignores `@trace ...` lines (like
  `@ready`) so async trace emission never closes a Lua gate mid-command.
- **Runner: `!trace-golden NAME`** frame-strips the collected `@trace` stream to a
  `<kind> <detail>` route signature vs `goldens/<test>/<NAME>.trace` (unified diff
  on mismatch, `STOL_UPDATE_GOLDEN=1` regen). Auto-enables `trace on` at boot when
  a test declares any `!trace-golden`. The runner now reads stdout via a raw-fd
  line buffer (not `TextIOWrapper.readline`, whose read-ahead dropped the reply
  that follows a siphoned trace line). Selftest extended with trace-golden
  create/match/mismatch/missing cases (all green).
- **Reachability = a runner directive `!reachability [map]`** (the "runner mode"
  option), driven by `tests/emu/30-ui-map-reachability.test`. It BFS-paths to each
  edge's `from` via the map, applies the gesture, and asserts the destination
  `recognize` predicate + the edge's new `arrival` field. Needs `tomllib` (3.11+).

- **PICKER-NAV HEADLINE:** the route from boot (`user/Chain.Root`) to
  `Unit.Chooser.Dense` is **`press MAIN3`**, NOT ENTER. On the empty boot chain the
  cursor sits on the header; the empty insert section spans MAIN3–MAIN5, and a
  MAIN-button press selects that spot so its `mainReleased`→`spotReleased` fires
  `EmptyControl:activateChooser` directly — no cursor-move gesture is needed. This
  supersedes the §11c guess that a cursor-move + ENTER was required, and the
  earlier "20-picker-open parked" note in §10.
- **UI-map corrections from live verification:** `node.hold` recognizes
  `SceneView.Performance` (scene mode defaults ON in the fixture), not `PinView`;
  the `admin → sample_pool` gesture is `press MAIN2` (MAIN1 is the header spot),
  not MAIN1. Every edge now carries a live-verified `arrival` trace line and a
  `high (verified live)` confidence tag; `node.unit_picker_classic` is documented
  but unreachable under the dense fixture (no inbound edge, so unwalked).

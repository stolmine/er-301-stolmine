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

Commands execute strictly in order; `wait`/`frames` gate the queue, so a
script is deterministic without host-side sleeps.

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

## 4. File touch list

- `emu/Emulator.{h,cpp}` — flag parsing, window null-guards, loop hooks,
  timed press scheduler
- `emu/Control.{h,cpp}` (new) — channel, parser, queues
- `emu/emu.h` + `emu/emu.cpp` — the three Lua-bridge functions (appended;
  free functions, ABI-safe per repo rules)
- `xroot/Application.lua` — drain branch (~10 lines, `app.EMULATION`-guarded)
- `scripts/emu.mk` — add Control.cpp to the emu source list
- No firmware-side (`od/`, `hal/`) changes at all; kernel.bin unaffected.

## 5. Risks and conventions

- **SDL dummy audio callback pacing** — the Phase A gate; fallback pacer
  thread if needed.
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

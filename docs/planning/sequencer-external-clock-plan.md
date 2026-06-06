# Sequencer external clock + reset — implementation plan

Phase 6 of the stolmine sequencer work. Adds external clock and
reset to the existing 4-slot sequencer, plus per-slot dividers,
fronted by a single 6-ply SpottedStrip Window under AdminMode.

Supersedes the older "External clock + reset (v2 spec)" section
in `sequencer-implementation-plan.md` lines 692-818, which
described a separate Sequencer admin section with a Clock
settings sub-page. The new single-screen approach is simpler
and reuses patterns from the v1.1 scenes work.

Status: bench-validated 2026-06-05. Phases 6.1-6.5 shipped on
`feature/sequencer-external-clock`; 6.6 (persistence) and 6.7
(deeper hardware sweep) pending. See "What shipped" section at
the bottom for the as-built record.

---

## Goal

Let users drive the sequencer from an external gate-clock source
(and optionally a reset source), with global pre-division and
per-slot post-division. Internal-BPM mode remains the default.
All four slots share the same clock source (matches the existing
shared-BPM model).

---

## Layout: 6-ply SpottedStrip Window

Accessed from AdminMode menu → "Sequencer Clock" (separate from
System Settings; sits alongside Sample Pool, Global Chains, etc.).
Single `SpottedStrip` Window with one Section holding 6 Controls
left to right:

```
| ext clock | reset |  seq 1  |  seq 2  |  seq 3  |  seq 4  |
|    div    |       |   div   |   div   |   div   |   div   |
```

| Ply | Class | Main display | Sub display |
|---|---|---|---|
| 1 | larets-pattern `GainBias` Control | global div fader (int 1..16) | source toggle (int/ext SubButton) • Source picker (Source.ExternalChooser) • bias readout • scope |
| 2 | `Gate`-style Control | gate indicator (rising-edge) | Source picker (Source.ExternalChooser) only |
| 3 | top-level int fader Control | seq 1 div (int 1..16) | none |
| 4 | top-level int fader Control | seq 2 div (int 1..16) | none |
| 5 | top-level int fader Control | seq 3 div (int 1..16) | none |
| 6 | top-level int fader Control | seq 4 div (int 1..16) | none |

Plies 1 and 2 use a **Source picker** (the same `Source.ExternalChooser`
pattern as the scene-CV M2/M3 plies), not a full subchain dive.
A picker-selected Source.External outlet binds directly to the
SequencerTask's extClock / extReset Inlet via `od::connect`. No
host chain, no branch lifecycle, no per-branch persistence wiring.
Trade-off: can't insert effects (Schmitt, rate-mult, etc.) between
the modular jack and the sequencer; the globalDiv / per-slot div
faders cover the rate-shaping need for v1. If a future bench
requires processing, hoist to a host-chain branch model in v2.

The SpottedStrip pattern is the same one Performance view uses:
single Section, controls panned through the viewport by the
camera as the cursor moves.

---

## Engine reality (sanity-check, 2026-06-05)

Each `Slot` owns its own `samplesUntilTick`. `Slot::processFrame()`
runs a per-sample countdown and calls its own (private) `fireTick()`
when it reaches zero. `Slot::fireTick()` returns the next interval
from the just-emitted stepLen column row, giving the existing
**per-slot polymetric stepLen feature**: each slot can run at an
independent rate driven by its own stepLen lane.

`SequencerTask::process()` just loops over slots calling
`processFrame(bpm, sampleRate)`. There is no central master-event
distributor today.

Implications for this feature:

- **Internal mode = unchanged.** Slots keep their per-slot
  polymetric stepLen-driven scheduling. We do NOT hoist tick
  scheduling up to SequencerTask in internal mode.
- **External mode = SequencerTask drives slot ticks directly.**
  When `clockSource == EXTERNAL`, each slot's
  `samplesUntilTick` countdown is suspended. SequencerTask
  edge-detects ext clock, applies globalDiv, then per-slot div
  counters, and on each surviving tick calls a new public
  `Slot::externalTick()` entry point. In external mode the per-slot
  stepLen column has no effect on tick spacing (the divider takes
  over); it still feeds the stepLen output buffer for any
  consumers but its row value no longer schedules the next tick.
- **`Slot::fireTick()` exposure.** Add a public
  `Slot::externalTick()` that runs the same body as `fireTick()`
  but discards the returned next-tick-interval (the
  externally-clocked slot ignores stepLen for scheduling).
  Internal mode keeps its existing private `fireTick()` call.

## Event flow

```
                       (clockSource flag on SequencerTask)
                       /                                  \
        CLOCK_INTERNAL                                 CLOCK_EXTERNAL
              |                                              |
   per-slot.samplesUntilTick               extClockInlet rising-edge per-sample
   ticks autonomously                                       |
   from its stepLen column                            ÷ globalDiv
   (existing behaviour)                                     |
                                                       master_tick
                                                            |
                                       +--------+-----+-----+--------+
                                       |        |     |     |        |
                                     ÷ d1     ÷ d2  ÷ d3  ÷ d4
                                   slot 1   slot 2 slot 3 slot 4
                                   (Slot::externalTick() per surviving tick)
```

- **External master event** = ext clock rising edge (per-sample
  detect in `SequencerTask::process`).
- **`globalDiv`** divides the master-event stream BEFORE per-slot
  distribution. globalDiv = 1 passes every event; globalDiv = 4
  fires one master tick per 4 events.
- **Per-slot `dN`** divides the master-tick stream individually per
  slot. Each `Slot::externalTick()` fires every dN master ticks.
- **Reset** = `extResetInlet` rising edge calls `Slot::reset()` on
  every slot. Sample-accurate, no queueing. Works in both internal
  AND external clock modes (reset is independent of clock source —
  the modular reset jack is still useful when the sequencer is
  internally clocked but synced to an external transport).

---

## Locked decisions

From the 2026-06-05 design conversation:

1. **Reset = hard-reset on rising edge.** Sample-accurate. Mid-
   envelope clicks are the user's clock pattern problem, not
   ours — that's the modular contract.
2. **Clock jitter = as-is, no PLL.** Sequencer follows the
   source faithfully. PLL is its own engineering project and
   lands as a v2.1+ refinement if bench demands it.
3. **Global div range = 1..16.** Matches the larets clockDiv
   convention.
4. **Per-slot div range = 1..16.** Same as global div for
   consistency. Saves users learning two ranges.
5. **Source toggle UX = SubButton on ply 1 sub.** Small "int /
   ext" status label. Single press flips.
6. **BPM in ext mode = greyed out** in the main BPM Setting
   display, and **sequencer views display a derived ext BPM**
   computed from inter-edge intervals when source = ext. Internal
   mode unchanged.

---

## Engine deliverable

### New fields on `SequencerTask`

```cpp
enum ClockSource : uint8_t {
  CLOCK_INTERNAL = 0,
  CLOCK_EXTERNAL = 1,
};
ClockSource clockSource = CLOCK_INTERNAL;

// External clock input. Lua hands us an Inlet pointer; processFrame
// per-sample rising-edge detect (prev < 0.5 && cur >= 0.5).
od::Inlet* extClockInlet = nullptr;
float      extClockLastSample = 0.0f;

// Global pre-divider (ply 1 main fader). Master event stream
// divided by this before distribution.
int globalDiv = 1;
int globalDivCounter = 0;

// Per-slot dividers (plies 3-6).
int slotDiv[4]      = {1, 1, 1, 1};
int slotDivCounter[4] = {0, 0, 0, 0};

// External reset input.
od::Inlet* extResetInlet = nullptr;
float      extResetLastSample = 0.0f;

// Derived external BPM. Updated each master event from inter-
// arrival time. Exposed as a Parameter so views can read it
// when clockSource == EXTERNAL. Smoothed via a simple EMA so
// jitter doesn't make the display dance.
Parameter mExtBpm{"ExtBpm", 0.0f};
float     extEventLastTime = 0.0f;
float     extBpmEma = 0.0f;
```

### `SequencerTask::process` extension

Internal mode keeps the existing behaviour: loop over slots, call
`Slot::processFrame(bpm, sampleRate)`, slots autonomously tick from
their own stepLen lanes.

External mode replaces the slot's internal countdown with
externally-driven ticks. Pseudocode:

```
process(inputs, outputs):
  if clockSource == EXTERNAL:
    # 1) Per-sample reset edge detect (works in BOTH modes, gate
    #    below moves outside).
    for i in 0..frameLen:
      cur = extClockInlet.buffer()[i]
      if extClockLastSample < 0.5 and cur >= 0.5:
        master_event_received(slotSampleIdx = i)
      extClockLastSample = cur

    # 2) Drive each slot in 'externally-clocked' mode for this
    #    frame: processFrameExternal(frameLen) emits output buffers
    #    (held S&H + gate envelopes ticking down) but skips its own
    #    samplesUntilTick countdown. fireTick() side effects ride
    #    the externalTick() calls scheduled above.
    for slot in slots:
      slot.processFrameExternal(frameLen, ...)
  else:
    # Existing path unchanged.
    for slot in slots:
      slot.processFrame(frameLen, ..., bpm, sampleRate)

  # Reset edge detect runs in BOTH modes (a modular reset is still
  # meaningful for an internally-clocked sequencer).
  for i in 0..frameLen:
    cur = extResetInlet.buffer()[i]
    if extResetLastSample < 0.5 and cur >= 0.5:
      for each slot: slot.reset()
    extResetLastSample = cur

master_event_received(slotSampleIdx):
  globalDivCounter++
  if globalDivCounter >= globalDiv:
    globalDivCounter = 0
    for slot i in 0..3:
      slotDivCounter[i]++
      if slotDivCounter[i] >= slotDiv[i]:
        slotDivCounter[i] = 0
        slots[i].externalTick()  # public; same body as fireTick(),
                                 # discards next-interval return.
  update_ext_bpm()  # EMA on inter-arrival time
```

The actual implementation will fuse the two per-sample loops into
one pass for cache friendliness; the pseudocode separates them for
clarity. `slotSampleIdx` is captured so a future "sample-accurate
external ticks" refinement can split the audio frame at the tick
boundary; for v1 we tick at the start of the frame.

### `Slot::externalTick()` (new public)

```cpp
// Public entry point for externally-clocked ticks. Same body as
// fireTick() (sample-and-hold, L2 eval, advance playheads, set
// firedThisTick flags, etc.). Returns void: the slot's
// samplesUntilTick is not touched because the external clock owns
// scheduling.
void externalTick();
```

`fireTick()` stays private. The new method shares the
implementation (refactor the body into a private
`fireTickImpl(bool returnSpt)` helper if compiler can't inline both
cleanly, or just call fireTick() and discard the return; the
discarded int is harmless because external-mode `processFrameExternal`
doesn't reference `samplesUntilTick`).

### `Slot::processFrameExternal()` (new public)

```cpp
// Audio-thread per-frame work when the slot is externally
// clocked. Fills the same six output buffers as processFrame()
// (S&H + gate envelopes) but DOES NOT decrement samplesUntilTick
// or call fireTick() internally. externalTick() is called from
// SequencerTask on tick boundaries instead.
void processFrameExternal(int frameLen,
                          float* cv1, float* cv2,
                          float* gate1Amp, float* gate2Amp,
                          float* stepLen, float* transpose);
```

Refactor: the inner sample-emission loop of `processFrame` (lines
270-291 in current `Sequencer.cpp`, after the `while
(samplesUntilTick <= 0) fireTick()` block) can be hoisted into a
private `emitSamples(filled, n, buffers)` helper called by both
processFrame paths.

### Derived ext BPM

```
update_ext_bpm():
  now = current_sample_time_seconds()
  delta = now - extEventLastTime
  extEventLastTime = now
  if delta > 0:
    instantBpm = 60.0 / delta  // assumes 1 master event = 1 beat
    extBpmEma = alpha * instantBpm + (1 - alpha) * extBpmEma
    mExtBpm.hardSet(extBpmEma)
```

EMA constant `alpha` tuned so the display settles in ~1 second
of clock activity. The Parameter is single-writer (audio) /
single-reader (UI), plain float — same pattern as the arbiter
`mLastFiredIndex` UI-poll convention from v1.1 scenes.

### SequencerTask SWIG-bound surface

- `setClockSource(int)` / `clockSource()` — int, not enum
- `getExtClockInlet()` / `getExtResetInlet()` — return `od::Inlet*`
  for Lua to pass to `app.connect(srcOutlet, dstInlet)`.
- `setGlobalDiv(int)` / `globalDiv()`
- `setSlotDiv(int slot, int div)` / `slotDiv(int slot)`
- `extBpm()` returns the Parameter's value

Lua wiring (parallel to InputTask outlets in `app-setup.lua`):
when a Source picker on ply 1 or 2 commits a selection, the picker
calls `app.connect(srcOutlet, seqTask:getExtClockInlet())` /
`getExtResetInlet()`. Disconnect path: `app.disconnect(seqTask:
getExtClockInlet())` (matches existing Inlet binding patterns
elsewhere in the codebase). Source picker stores the picked source
NAME for persistence; on deserialize, look up the name in
`externalSources[]` and reconnect.

---

## Lua deliverable

### New files

- **`xroot/Sequencer/ClockView.lua`** — the SpottedStrip Window
  containing the 6 plies. Mirrors `SceneView/Performance.lua`
  structure.

### Reuse

- **`Unit.ViewControl.GainBias`** for ply 1 (`biasMap = intMap(1, 16)`,
  `biasUnits = app.unitNone`, `biasPrecision = 0`) — the
  larets-clockDiv pattern verbatim.
- **`Unit.ViewControl.Gate`** for ply 2.
- **Plies 3-6** can either reuse `GainBias` or use a lighter
  top-level-only Fader (no branch dive, no scope). Decided in
  6.4; the spec leaves it open.

### AdminMode wiring

In `xroot/AdminMode/init.lua`, add:

```lua
local sequencerClock = require "Sequencer.ClockView"
menu:add("Sequencer Clock", sequencerClock)
```

Under the "Global Audio:" header alongside Sample Pool, Global
Chains, etc. (it's a sequencer-wide setting, not maintenance).

### BPM display switch

Wherever sequencer views currently display BPM (transport
readout, etc.), check `seqTask:clockSource()`. If
`CLOCK_INTERNAL` → standard BPM Setting; if `CLOCK_EXTERNAL` →
`seqTask:extBpm()`. Internal-BPM display in the Settings menu
gets a "(ext)" badge or is dimmed when ext is active.

---

## Persistence

Lua-side serialize schema (held alongside other sequencer-global
state in `Sequencer/Persist.lua`):

```lua
{
  clockSource = "internal" | "external",
  globalDiv   = N,                  -- int 1..16
  slotDiv     = { d1, d2, d3, d4 }, -- ints 1..16
  extClockSource = "G1",            -- nil or external-source name
  extResetSource = "G2",            -- nil or external-source name
}
```

On deserialize:
1. `seqTask:setClockSource(...)`, `setGlobalDiv(...)`,
   `setSlotDiv(slot, d)`.
2. If `extClockSource` non-nil: look up `externalSources[name]`,
   `app.connect(source:getOutlet(), seqTask:getExtClockInlet())`.
   Same for reset.
3. No branch tree to restore. No `hardSet` ramp-dynamics concern
   (everything is a plain int or a connect call). The boot-time
   relatch contract from v1.1 scenes ([[project_release_9_4_0]])
   does NOT apply here — `globalDivCounter` / `slotDivCounter` are
   pure counters with no baseline state; restoring them at 0
   simply means the first post-boot tick after a clock pulse fires
   normally.

---

## Phases

- **6.1** (this doc): plan + locked decisions + engine-reality
  sanity check.
- **6.2**: engine — `Slot::externalTick()` + `processFrameExternal()`,
  `SequencerTask` extClockInlet / extResetInlet / dividers / source
  select / derived ext BPM. Internal mode unchanged. SWIG bindings.
  Isolation bench.
- **6.3**: extClock + reset Source-picker wiring on SequencerTask.
  `app.connect` plumbing from a Source.ExternalChooser-style picker
  into `getExtClockInlet()` / `getExtResetInlet()`. No branches.
- **6.4**: `Sequencer.ClockView` Lua Window (6-ply SpottedStrip).
- **6.5**: AdminMode entry + sequencer-view BPM display switch.
- **6.6**: persistence — clockSource + dividers + picked source
  names survive reboot. Boot-time reconnect from saved names.
- **6.7**: hardware bench sweep — modular gate at 1/16, 1/8, 1/4;
  reset interop; drift under heavy DSP load; derived BPM accuracy.

---

## Open items deferred to implementation

- **Plies 3-6 control class**: reuse `Unit.ViewControl.GainBias`
  (with branch/range/scope unused) or strip down to a
  top-level-only int Fader subclass? Decided in 6.4 based on
  visual fit.
- **EMA constant for derived BPM**: pick during 6.2 isolation
  bench based on real-world feel.
- **PLL / jitter smoothing**: explicitly deferred to v2.1+.
- **Per-slot divider visibility when slot's UI source is the
  picker**: the divider lives on `SequencerTask`, picker output
  units are per-slot — does the picker show the post-divided
  rate, or do we need a separate visual cue? Decided in 6.4.

---

## Reusable lessons from v1.1 scenes that apply here

From [[project_release_9_4_0]]:

- **Multi-role branch map pattern**: DOES NOT apply here. We
  intentionally took the lighter Source-picker path on plies 1 + 2
  (user direction 2026-06-05: "we don't need a full on subchain,
  just a way to grab a source"). The valueSource alias pattern
  remains a tool for future work that needs branch hosting on a
  Task-level object.
- **Audio-thread autonomy**: keep all event distribution + divider
  counting in `SequencerTask::process` / `Slot::processFrameExternal`.
  UI starvation must not stall clock advancement.
- **Boot-time relatch**: N/A. `globalDivCounter` / `slotDivCounter`
  are pure counters with no baseline state. Initialize to 0 on
  deserialize. No `mGainAtEntry`-style baseline to capture.
- **Forward-reference hazard** ([[feedback_lua_forward_reference]]):
  any new Lua-side helper called from `Sequencer.ClockView` or
  `Sequencer/Persist.lua` must be defined AFTER its callers.
- **Crash hook coverage** ([[feedback_crash_hook_install_order]]):
  the existing Crash.init covers `Application.init`. Adding
  AdminMode entry + ClockView Window does not change install order.
  No new initialization paths to wrap.

---

## What shipped (as-built, 2026-06-05)

Bench-validated on emu and hardware. Tag-derived dev versions
`.9.4.0.5` through `.9.4.0.11` carry the full feature.

### Engine — Comparator-based (revised from Inlet-direct plan)

`SequencerTask` owns two `od::Comparator` member objects rather
than raw Inlets. They expose:

- Built-in threshold + hysteresis edge detection (trigger-on-rise).
- `simulateRisingEdge` / `simulateFallingEdge` for manual fire from
  the UI (S2 press/release on SourceControl, S3 press/release on
  ResetControl).
- `getRateInBPM` for rate measurement (consumed by the windowed
  BPM cache, not directly).

`SequencerTask::process` calls `mExtClockComp.process()` /
`mExtResetComp.process()` directly each audio frame. Comparators
are NOT part of any Chain — they're not scheduled by the graph
compiler. `Comparator::process` is self-contained and audio-thread
safe, so manual invocation works.

Edge detection on `comparator->getOutput("Out")->buffer()` drives
the global divider + per-slot dividers (clock path) and the slot
reset (reset path, both modes).

`Slot::externalTick(bpm, sampleRate)` and
`Slot::processFrameExternal(...)` are the public hooks added to the
sequencer engine. Internal mode is bit-identical to pre-phase-6.

### Adaptive BPM readout

`SequencerTask` maintains a windowed + EMA-smoothed `mCachedExtBpm`:

1. Each audio frame, if the comparator has accumulated ≥8 edges
   AND ≥0.5s elapsed since the last counter reset, take a rate
   sample: `getRateInBPM() / 4.0` (the divide-by-4 is the 4 PPQN
   assumption — 1/16-note pulses, matching the analog-modular
   convention and the existing `Slot::stepLen=0.25` "tick = 1/16"
   semantic).
2. EMA-blend the sample: `mCachedExtBpm = 0.3 * sample + 0.7 *
   mCachedExtBpm`. First valid sample snaps so the display doesn't
   visibly climb from 0.
3. Reset the comparator counter for the next window.

`getExtBpm()` returns the cached float (no const_cast gymnastics).

The windowed + EMA pattern was driven by user feedback: an earlier
narrow-window implementation (>2 edges / >0.25s) produced ±1 BPM
wobble. Bench-validated 2026-06-05: 5 Hz clock settles at 150 BPM
in ~10 seconds, then holds.

### Mode select — moved to System Settings

`Settings/init.lua` exposes `sequencerClockSource` (choices
"internal" / "external", category "Sequencer") with an `onSet`
callback that pushes the value into `seqTask:setClockSource`.
`Settings/Interface.lua` puts the entry under a new "Sequencer"
category. The in-view shifted-S1 toggle was removed -- this is the
standard ER-301 settings pattern and avoids cluttering the
ClockView with mode state.

### GridView BPM display switch

`GridView` reads `seq:getClockSource()` each refresh:

- Internal mode (default): `BPM N` / `BPM N.M` -- unchanged.
- External mode: `BPM ext N` / `BPM ext N.M` / `BPM ext --` (last
  case = derived value is 0, i.e. no pulses yet).

The shift+S2 BPM-edit latch is silently inert in external mode
(editing internal sBpm has no audible effect when externally
clocked, so bailing is cleaner than fake-editor confusion).

### UI conformance — focus model

After user feedback, SlotDivControl now follows standard ER-301
convention:

- `onCursorEnter`: selection-only, no auto-grab. Scrolling past a
  ply never steals encoder focus.
- M-tap (`spotPressed`) auto-focuses the fader on first tap;
  subsequent taps toggle.
- `upReleased` / `cancelReleased`: focused → unfocus + return true
  (consume); unfocused → return false (bubble up to Window's
  egress for admin-menu return).

ClockView Window itself has `upReleased` / `homeReleased` /
`cancelReleased` that `:hide()` + emit "done", matching the
Sample.Pool.Interface / GlobalChains.Interface convention.

SourceControl + ResetControl were already correct (they only grab
encoder inside `_setFocusedReadout` via explicit S-button gestures).

### Source-picker wiring

`xroot/Sequencer/ClockBinding.lua` connects picker selections
directly to `comparator:getInput("In")` via
`app.AudioThread.connect`. Held source NAMES (for both clock and
reset) for UI + persistence (6.6).

### Open items / known notes

- **2x rate observation**: bench shows 5 Hz square source reads as
  150 BPM (raw 600 / 4). Either the source is internally 10 Hz or
  the PPQN should be 8 (rather than 4). User accepted 150 for v1
  as the absolute number matters less than tracking proportionally
  in a relative-timing system. Revisit at 6.7 hardware sweep with
  a known-precise clock reference.
- **Phase 6.6 persistence**: clockSource + globalDiv + per-slot
  divs + picked source names all need to survive reboot. Not yet
  wired into `Sequencer/Persist.lua`. Default state is internal +
  div=1 everywhere + no sources bound, which already works on a
  fresh boot.

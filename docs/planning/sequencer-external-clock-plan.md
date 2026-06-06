# Sequencer external clock + reset — implementation plan

Phase 6 of the stolmine sequencer work. Adds external clock and
reset to the existing 4-slot sequencer, plus per-slot dividers,
fronted by a single 6-ply SpottedStrip Window under AdminMode.

Supersedes the older "External clock + reset (v2 spec)" section
in `sequencer-implementation-plan.md` lines 692-818, which
described a separate Sequencer admin section with a Clock
settings sub-page. The new single-screen approach is simpler
and reuses patterns from the v1.1 scenes work.

Status: design locked 2026-06-05. Phase 6.1 (this doc) is the
deliverable.

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
| 1 | larets-pattern `GainBias` Control | global div fader (int 1..16) | source toggle (int/ext SubButton) • subchain dive • bias readout • scope |
| 2 | `Gate`-style Control | gate indicator (rising-edge) | subchain dive only |
| 3 | top-level int fader Control | seq 1 div (int 1..16) | none |
| 4 | top-level int fader Control | seq 2 div (int 1..16) | none |
| 5 | top-level int fader Control | seq 3 div (int 1..16) | none |
| 6 | top-level int fader Control | seq 4 div (int 1..16) | none |

The SpottedStrip pattern is the same one Performance view uses:
single Section, controls panned through the viewport by the
camera as the cursor moves.

---

## Event flow

```
            (source toggle on ply 1 sub)
             /                       \
   internal_BPM_tick           ext_clock_rising_edge
             \                       /
              \                     /
               \                   /
                \                 /
                 master_event
                       |
                  ÷ globalDiv (ply 1 main fader)
                       |
                 master_tick
                       |
        +--------------+--------------+--------------+
        |              |              |              |
      ÷ d1           ÷ d2           ÷ d3           ÷ d4
      slot 1         slot 2         slot 3         slot 4
                                   (each fires its existing fireTick)
```

- **Master event** = whichever source's pulse (internal BPM
  countdown or external rising edge).
- **`globalDiv`** divides the master-event stream before
  distribution. globalDiv = 1 passes every event; globalDiv = 4
  fires one master tick per 4 events. Lives on ply 1's main
  fader.
- **Per-slot `dN`** divides the master-tick stream individually
  per slot. Each `Slot::fireTick()` fires every dN master ticks.
- **Reset** on ply 2's rising edge calls `reset()` on every slot
  (hard-reset playhead to loop-min). Sample-accurate, no queueing.

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

### `processFrame` extension

Adds a per-sample edge detector branch when `clockSource ==
CLOCK_EXTERNAL`. Internal mode keeps the existing
`samplesUntilTick` countdown driver. Pseudocode:

```
on each sample i in frame:
  if clockSource == EXTERNAL and extClockInlet:
    cur = extClockInlet.buffer()[i]
    if extClockLastSample < 0.5 and cur >= 0.5:
      master_event_received()
    extClockLastSample = cur

  if extResetInlet:
    cur = extResetInlet.buffer()[i]
    if extResetLastSample < 0.5 and cur >= 0.5:
      for each slot: slot.reset()
    extResetLastSample = cur

  if clockSource == INTERNAL:
    samplesUntilTick--
    if samplesUntilTick <= 0:
      master_event_received()
      samplesUntilTick += samplesPerTick

master_event_received():
  globalDivCounter++
  if globalDivCounter >= globalDiv:
    globalDivCounter = 0
    for slot i in 0..3:
      slotDivCounter[i]++
      if slotDivCounter[i] >= slotDiv[i]:
        slotDivCounter[i] = 0
        slots[i].fireTick()
  if clockSource == EXTERNAL:
    update_ext_bpm()  // EMA on inter-arrival time
```

The existing sample-accurate processFrame loop already iterates
per sample at tick boundaries; this just adds two more
edge-detect predicates and an event distribution step.

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

- `setClockSource(int)` / `clockSource()`
- `setExtClockInlet(od::Inlet*)` / `setExtResetInlet(od::Inlet*)`
- `setGlobalDiv(int)` / `globalDiv()`
- `setSlotDiv(int slot, int div)` / `slotDiv(int slot)`
- `extBpm()` returns the Parameter's value

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

Multi-role serialize schema on `SequencerTask`:

```
t.clockSource = CLOCK_INTERNAL | CLOCK_EXTERNAL  -- enum int
t.globalDiv   = N
t.slotDiv     = { d1, d2, d3, d4 }
t.extClockBranch = extClockBranch:serialize()
t.resetBranch    = resetBranch:serialize()
```

Pattern parallels `Chain.Root._sceneCVBranches`: branches held
directly on the SequencerTask, serialized inline. On deserialize,
restore via the same hardSet-not-softSet convention used for
scenes (no ramp dynamics on boot).

---

## Phases

- **6.1** (this doc): plan + locked decisions.
- **6.2**: engine — source select, edge detection, global +
  per-slot dividers, reset, derived ext BPM. Internal still
  default. SWIG bindings. Isolation bench.
- **6.3**: extClock + reset top-level branches on SequencerTask.
  Branch serialize/deserialize.
- **6.4**: `Sequencer.ClockView` Lua Window (6-ply SpottedStrip).
- **6.5**: AdminMode entry + sequencer-view BPM display switch.
- **6.6**: full persistence — clock source + dividers + branches
  survive reboot. Boot-time restore.
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

- **Multi-role branch map pattern**: `entry.valueSource` alias
  works for any role whose value-source-object exposes Parameters
  the engage loop wants to touch uniformly. Applies here for
  extClock + reset.
- **Audio-thread autonomy**: keep all event distribution +
  divider counting in `processFrame`. UI starvation under heavy
  DSP must not stall scene switching, and the same must hold for
  external clock advancement.
- **Boot-time relatch**: any state that depends on baseline
  capture (like the arbiter's mGainAtEntry) needs an explicit
  post-deserialize touch. Likely doesn't apply here since
  dividers are pure counters with no baseline state, but worth
  checking in 6.6 if any new C++ field accumulates pre-event
  context.
- **Bank-drift / state-drift detection on UI tick**: the
  Performance view's `_rebuildBank` self-correction pattern
  handles external state changes elegantly. May apply if the
  ClockView's plies need to reflect changes from elsewhere
  (e.g., the picker auto-routing the clock subchain).
- **Forward-reference hazard**: any new Lua-side helper called
  from `Chain.Root` (or `SequencerTask` Lua bindings) must be
  defined AFTER its callers in the file.

# Sequencer: external clock honors stL (9.5.1)

## Problem

A user testing 9.5.0 reported that the `stL` (step-length) column is
ignored when the external clock is engaged. Each external pulse that
survives the master divider plus the per-slot divider advances every
column by one row, regardless of the row's `stL` value.

Symptom under external clock: a sequence with mixed `stL` values
plays as if every row were the same length. Rhythmic shape collapses.

Root cause: `Slot::externalTick()` in `od/sequencer/Sequencer.cpp`
calls `fireTick()` and discards the returned samples-per-tick. The
comment at the call site reads "external clock owns scheduling," which
is true for slot tick spacing but skips `stL` consultation entirely.
Each surviving pulse fires exactly one slot tick.

## Scope of the fix

`stL` is already semantically an integer tick count from the user's
perspective:

- The encoder fine step is 1 tick (0.25 beats), coarse step is 4 ticks
  (1 beat).
- `clampForColumn(stL, newV)` floors at 0.0625 beats (one tick at
  PPQN=4); writes outside that clamp to the nearest snap.
- The random pool `kRandomStepTicks = {1, 2, 4, 8, 16, 32}` is in
  ticks, multiplied by 0.25 for storage.
- Display formatters render whatever-the-number-of-ticks is.

Storage is float beats by historical column-uniformity; the value is
always `0.25 * integer_ticks`. No data model change is needed.

Gate-length columns (`g1L`, `g2L`) and other beats-valued state stay
exactly as they are.

The fix is local to `Slot::externalTick()`.

## Model

The flow stays as designed:

```
ext_clock_source -> master_divider -> per_slot_divider -> slot tick
```

Atomic tick semantics in the slot:

- Each surviving slot tick increments an integer counter
  `externalTickCount`.
- When `externalTickCount >= heldStLTicks` (the current step's
  `stL`, converted to ticks), the slot advances every column's
  playhead by one row and resets the counter to 0.
- A tick is always a tick. No fractional accumulator.

This matches the internal-mode invariant that `stL=N` means "this row
holds for N base ticks before advancing," now extended to externally-
driven ticks.

## Implementation

### `od/sequencer/Sequencer.h`

Add one int to `Slot`:

```cpp
int externalTickCount = 0;  // counts surviving ext ticks within current row
```

### `od/sequencer/Sequencer.cpp`

`Slot::init()` (line ~110) and `Slot::reset()` (line ~409) zero
`externalTickCount`.

`Slot::externalTick()` (line ~342) becomes:

```cpp
void Slot::externalTick(float bpm, float sampleRate) {
  if (!running) return;
  cachedBpm = bpm;
  cachedSampleRate = sampleRate;

  ++externalTickCount;

  // Convert current stL (float beats stored as 0.25 * integer ticks)
  // to integer tick count via the PPQN=4 base step. Floor at 1 so a
  // pathological 0 doesn't deadlock the slot.
  Column& stC = columns[kColStepLen];
  float stLBeats = stC.l1[stC.playhead].value;
  if (stLBeats <= 0.0f) stLBeats = 0.25f;
  int stLTicks = static_cast<int>(stLBeats / 0.25f + 0.5f);
  if (stLTicks < 1) stLTicks = 1;

  if (externalTickCount >= stLTicks) {
    externalTickCount = 0;
    (void)fireTick();
  }
}
```

`fireTick()` is unchanged. It captures the new row's stL into
`heldStepLen` after the advance, just like in internal mode. The
external-tick counter operates independently of `samplesUntilTick`
which stays at 0 in external mode (no internal scheduling).

The reset path: `mSlots[s].reset()` already clears playhead and
related state per slot. We just need `externalTickCount = 0` added in
the reset body. An external reset edge therefore yields an immediate
fresh row-0 hold from the next surviving pulse.

### What about the per-slot divider?

Unchanged. The per-slot divider in `SequencerTask.cpp` reduces the
ext-pulse rate BEFORE calling `Slot::externalTick()`. So `divider=2 +
stL=1` and `divider=1 + stL=2` produce the same audible rate:

- Case A (`divider=2, stL=1`): 2 pulses arrive at SequencerTask, 1
  survives the divider and calls `externalTick()`, counter goes 1,
  matches stL=1, fire. One row advance per 2 pulses.
- Case B (`divider=1, stL=2`): 2 pulses arrive at SequencerTask, both
  survive and call `externalTick()`, counter goes 1 then 2, matches
  stL=2, fire on the second. One row advance per 2 pulses.

Both produce one playhead advance per two pulses, as expected. The
two knobs compose naturally.

## Test matrix

10 rows. Bench against a known-precise external clock.

| # | Mode | stL pattern | Pulse rate | Expected |
|---|---|---|---|---|
| 1 | Internal | all 1 tick | sBpm = 120 | one row per 1/16 note (baseline) |
| 2 | Internal | all 4 ticks | sBpm = 120 | one row per quarter note (baseline) |
| 3 | Internal | {1, 2, 4, 8} repeating | sBpm = 120 | row holds 1/16, 1/8, 1/4, 1/2 in sequence |
| 4 | External | all 1 tick | 2 Hz | matches internal #1 (advance every pulse) |
| 5 | External | all 4 ticks | 2 Hz | matches internal #2 (advance every 4 pulses) |
| 6 | External | {1, 2, 4, 8} | 2 Hz | matches internal #3 |
| 7 | External | per-slot divider=2, stL=1 | 2 Hz | one row per 2 pulses |
| 8 | External | per-slot divider=1, stL=2 | 2 Hz | one row per 2 pulses (= #7) |
| 9 | External | external reset edge mid-row | 2 Hz | row 0 holds for stL[0] starting next pulse |
| 10 | Internal -> external mid-run | mixed stL | sBpm=120 -> 2 Hz | rhythmic shape preserved across switch |

Tests 4 and 5 are the headline regressions. Test 8 verifies the
divider-vs-stL composition. Test 9 verifies reset clears the counter.

## Risk callouts

- **Per-row stL changes mid-hold**: `fireTick()` captures `heldStepLen`
  at advance time. The external-tick path reads `stC.l1[playhead]`
  directly each tick. If the user edits the current row's stL value
  during a hold, the new value takes effect immediately for the
  remaining ticks of the hold. This is acceptable behavior; matches
  internal mode where mid-hold edits don't extend the in-flight tick
  interval (sample-accurate) but do affect comparison semantics.
- **First-pulse-after-start**: `externalTickCount` starts at 0. First
  pulse increments to 1 and compares against the current row's stL.
  If stL is at least 1 tick (always true given the floor), the first
  pulse fires only if stL=1. For stL>=2, the slot holds the first
  pulse without firing, matching expected behavior.
- **External reset mid-hold**: the reset call zeros playhead state. We
  add `externalTickCount = 0` to the reset path so the next pulse
  starts a fresh hold count against row 0's stL.

## Out of scope

- Skip-step (stL=0). Floor at 1 stays.
- ER-101-style per-track PPQN multiplier (synthetic sub-clock). We
  already have the per-slot divider for the rate-divide direction.
- TIE on stL (gate lengths handle TIE; stL doesn't).
- Variable PPQN: stays locked at 4.

## Release vehicle

- Cut `feature/seq-stl-external-clock` off develop.
- Implement: ~20 lines in Sequencer.{h,cpp}, no other files.
- Parse-check, emu smoke, hardware build.
- Bench against the 10-row matrix.
- Tag `v0.7.0-stolmine.9.5.1`. Patch release of the AM335x fork.
- Merge develop, then rpidev. Push tag. GitHub release.

Critical regression patch for the headline 9.5.0 feature. Single-file
change. Scope is tight: external mode now honors what internal mode
already honored.

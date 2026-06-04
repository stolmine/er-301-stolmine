# SceneIndexArbiter interface spec

Phase 5.1 deliverable. C++ header sketch + state machine table +
threading model for the per-role A/B selector primitive introduced
in `hold-mode-scenes-v1-1-plan.md`.

## Header sketch

Lands at `od/objects/control/SceneIndexArbiter.{h,cpp}` and is
SWIG-registered alongside `ParamSetMorph`.

```cpp
#pragma once

#include <od/objects/Object.h>
#include <od/objects/Inlet.h>
#include <od/objects/Parameter.h>

namespace od
{

  // Per-role selector for the v1.1 hold-mode scenes A/B faders.
  // Arbitrates among three writers (CV input, encoder via mBias,
  // chip tap via mBias hardSet) using a 2-state machine.
  //
  // Output (mOutput) is the effective scene index as a float
  // (post-round, clipped to [0, mSceneCount]). The morpher reads
  // round(mOutput.value()) on rebuild; the fader's "line" reads
  // mOutput continuously for animation.
  //
  // Integer-transition signaling is via mTransitionPending flag.
  // Lua-side Chain.Root polls this each UI frame and, when set,
  // clears it and schedules _buildSceneMorphItems(). Threading
  // model details in the spec doc.
  class SceneIndexArbiter : public Object
  {
  public:
    SceneIndexArbiter();
    virtual ~SceneIndexArbiter();

#ifndef SWIGLUA
    virtual void process();

    // CV input. Scaled internally by mGain to produce candidate
    // index = round(mGain * cvIn). When unpatched, buffer is
    // ZeroOutput and arbiter sits in Tracking-Manual at startup.
    Inlet mInput{"In"};
    // Output as float for fader animation; round() to int for
    // morpher consumption.
    Outlet mOutput{"Out"};
#endif

    // User-facing Parameters. Both saved.
    Parameter mGain{"Gain", 1.0f};   // range +-32, default 1.0
    Parameter mBias{"Bias", 0.0f};   // range [0, mSceneCount], default 0

    // Bank size in scenes. Clips mBias and mOutput. Set by
    // Chain.Root after SceneView add/delete.
    void setSceneCount(int n);
    int getSceneCount() const { return mSceneCount; }

    // Manual-write entry point. Called by Lua chip-tap and encoder
    // handlers. Hard-sets mBias, forces Tracking-Manual, latches
    // CV-at-entry baseline. Triggers an integer transition signal
    // if the effective output index changes.
    void hardSetBias(float value);

    // Lua polls this per UI frame. Returns true once when a
    // transition has fired since the last poll, then auto-clears.
    bool consumeTransitionFlag();

    // Diagnostics / introspection for views.
    enum State { kTrackingManual, kTrackingCV };
    State getState() const { return mState; }
    int getCurrentIndex() const { return mLastFiredIndex; }

  protected:
    int mSceneCount = 0;
    State mState = kTrackingManual;

    // Input-space baseline + frozen Gain captured on Manual entry.
    // Schmitt comparison uses frozen Gain so a live Gain change
    // doesn't spuriously trip the state transition.
    float mCVInputAtEntry = 0.0f;
    float mGainAtEntry = 1.0f;

    // Last integer output we fired a transition for. Compared
    // against current round(effective) each frame to detect edges.
    int mLastFiredIndex = 0;

    // Set true when an integer-transition edge is detected.
    // Audio-thread write, Lua-thread read+clear via
    // consumeTransitionFlag. Single-writer / single-reader on a
    // bool: tearing-safe on all target architectures.
    bool mTransitionPending = false;

    // Recompute effective index from current inputs + state.
    // Returns clipped integer in [0, mSceneCount].
    int computeEffectiveIndex(float cvIn, float gain, float bias) const;

    // Detect Manual->CV transition (Schmitt on CV in output space
    // with frozen entry Gain). Returns true if state should flip.
    bool shouldYieldToCV(float cvIn) const;
  };

} /* namespace od */
```

## State machine

| State            | Output formula              | Exits to                  | Condition                                                    |
|------------------|-----------------------------|---------------------------|--------------------------------------------------------------|
| Tracking-Manual  | `clip(round(bias))`         | Tracking-CV               | `\|gain_at_entry * (cvIn - cv_at_entry)\| > 0.5`             |
| Tracking-CV      | `clip(round(gain * cvIn))`  | Tracking-Manual           | `hardSetBias()` called (encoder, chip tap, decimal kb)       |

- **Cold start:** Tracking-Manual.
- **Schmitt threshold:** 0.5 in output space. Locked.
- **Schmitt baseline freeze:** input value and Gain are both captured at the moment of entering Tracking-Manual. Live Gain changes during Manual do not rescale the baseline; the user dialing Gain while parked won't spuriously yield to CV.
- **No idle decay.** Tracking-Manual only yields when CV crosses the Schmitt. Time alone doesn't release.
- **Clip:** `clip(x) = max(0, min(x, mSceneCount))`. Bank shrink calls `setSceneCount()` which re-clips current output and `mBias`.

## Process loop (per audio frame)

```
on process():
  cvIn = mInput.buffer()[FRAMELENGTH - 1]   // last sample of frame
  gain = mGain.value()
  bias = mBias.value()

  if mState == kTrackingManual and shouldYieldToCV(cvIn):
    mState = kTrackingCV

  index = computeEffectiveIndex(cvIn, gain, bias)
  if index != mLastFiredIndex:
    mLastFiredIndex = index
    mTransitionPending = true   // audio-thread write, Lua read

  // Fill output buffer with float index for fader animation.
  simd_set(mOutput.buffer(), FRAMELENGTH, (float)index)
  mOutput.mIsConstant = true
```

Sampling only the last frame sample is sufficient: scene transitions are deliberate gestures, not per-sample modulation. Saves the per-sample arithmetic and the buffer scan.

## Manual-write fast path (Lua-direct)

```
SceneIndexArbiter::hardSetBias(value):
  mBias.hardSet(clip(value, 0, mSceneCount))
  mCVInputAtEntry = last_known_cvIn   // see note below
  mGainAtEntry = mGain.value()
  mState = kTrackingManual
  new_index = computeEffectiveIndex(mCVInputAtEntry, mGainAtEntry, mBias.value())
  if new_index != mLastFiredIndex:
    mLastFiredIndex = new_index
    mTransitionPending = true
```

Lua chip-tap handler also calls `Chain.Root:_buildSceneMorphItems()` synchronously on the same Lua call, so the audio thread sees both new mBias and new morpher items on its next frame. No polling latency for manual gestures.

Note on `last_known_cvIn`: arbiter caches `mInput.buffer()[FRAMELENGTH - 1]` into a member each `process()` call so `hardSetBias()` (which runs on Lua thread without an Inlet buffer guarantee) has a stable value for the Schmitt baseline.

## Threading model

| Operation                       | Thread       | Mechanism                            |
|---------------------------------|--------------|--------------------------------------|
| `process()`                     | Audio        | Standard Object process              |
| `mGain.value()`, `mBias.value()`| Audio (read) | Parameter is lock-free               |
| `mBias.hardSet()` from Lua      | Lua          | Parameter::hardSet is lock-free      |
| `mTransitionPending = true`     | Audio (write)| Plain bool, single writer            |
| `consumeTransitionFlag()`       | Lua (read+clear) | Plain bool, single reader        |
| `setSceneCount()`               | Lua          | Plain int write                      |
| `hardSetBias()`                 | Lua          | Touches mState + members; see below  |

`hardSetBias()` mutates `mState`, `mCVInputAtEntry`, `mGainAtEntry`, `mLastFiredIndex`, `mTransitionPending` from Lua thread while audio thread also reads/writes those fields in `process()`. This is a real race window but the consequences are bounded:

- Worst case: audio process() reads stale state for one frame, transitions or fails to transition. Self-correcting on next frame because both threads converge on the same input values.
- No memory-safety violation: all fields are plain scalars, no allocations, no container resizes.
- Acceptable for v1.1. Revisit with proper atomic<bool> + memory ordering if bench shows visible glitching.

Same model as the existing `ParamSetMorph` engage path: Lua mutates structural state outside the audio thread's lock; thread interleaving is "first-class messiness" that the system has tolerated for the v1.0 lifetime.

## Bank-shrink behavior

```
setSceneCount(n):
  mSceneCount = n
  current_bias = mBias.value()
  if current_bias > n:
    mBias.hardSet((float)n)
    mTransitionPending = true   // morpher may need rebuild for clipped index
```

`mLastFiredIndex` is clipped on next `process()` via the normal `computeEffectiveIndex` clip.

## Schmitt threshold derivation

```
shouldYieldToCV(cvIn):
  delta_in_input_space = cvIn - mCVInputAtEntry
  delta_in_output_space = mGainAtEntry * delta_in_input_space
  return fabs(delta_in_output_space) > 0.5
```

0.5 output-space units = ½ a scene step. With Gain = 1 and a CV source delivering values in scene-index units directly, this is "CV moved by half a scene." With Gain = 16 (1V source covering 16 scenes), input-space threshold is 0.03125V; tiny CV jitter won't trip it but a deliberate sweep will.

## Lua wiring (Chain.Root side)

`Chain.Root` owns one arbiter per role A/B. Per UI frame:

```lua
function Root:_pollSceneArbiters()
  if not self._sceneCVBranches then return end
  local rebuild = false
  for _, role in ipairs({"A", "B"}) do
    local arb = self._sceneArbiters and self._sceneArbiters[role]
    if arb and arb:consumeTransitionFlag() then
      rebuild = true
    end
  end
  if rebuild then
    self:_buildSceneMorphItems()
  end
end
```

Hook point: the existing per-frame UI handler that already runs for Performance view animation. Adding one bool-read per role per frame is negligible.

## Open implementation items deferred to 5.3

- Choice of poll hook (Performance view's frame handler vs Chain.Root direct vs UIThread global tick). Cheapest is whichever already runs at UI frame rate without adding a new loop.
- Whether `mTransitionPending` needs `std::atomic<bool>` or plain bool suffices on AM335x + Pi targets. Plain bool is correct on ARMv7+ with appropriate compiler ordering; lean plain until profiling says otherwise.
- Whether the audio-thread `mTransitionPending = true` write should be moved inside `simd_set` so the compiler can't reorder the store ahead of the index update. Probably not necessary at -O2 but worth a glance at the generated asm.
- Whether `hardSetBias()` should immediately call `Chain.Root:_buildSceneMorphItems()` from C++ side (callback) or whether the Lua caller does it explicitly. Lean Lua-caller-explicit so the C++ object stays UI-agnostic.

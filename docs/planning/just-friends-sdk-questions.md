# Just Friends — SDK-side gating questions

Status: **scoping**, 2026-04-30. Written from the habitat side
(`er-301-habitat/planning/just-friends.md`) to surface the
framework-side unknowns before a single line of voice DSP gets
written. JF is being scoped as the v1 flagship multi-output unit
(framework shipped 2026-04-21; see
`docs/planning/redesign/07-multi-output-units.md`).

The DSP/UI side of the JF spec is resolved enough to start on. The
load-bearing unknowns are all framework-side. This doc inventories
them, records what an initial probe of `xroot/` and `od/objects/`
turned up, and lists the experiments that would close each item.

## Why JF in particular pressures the framework

JF is the first multi-out unit candidate that:

1. Has **6 sub-outputs**, plus a candidate MIX → 7 total. QuadLFO
   shipped as the framework reference at 4. Nothing in the spec
   forbids 7, but nothing has exercised it either.
2. Has **N parallel trigger sub-chains with right-to-left normalling**
   — each voice's trigger input is normalled to its right neighbor's,
   broken by patching a cable. This is *the* reason JF was picked over
   Stages or Tides 2 (smallest legible exercise of presence
   detection), but it depends on a primitive habitat hasn't used
   before.
3. Has **continuous coupling** (INTONE morph, shared CURVE/RAMP/FM,
   SHIFT phase-receptivity) that breaks derivability — passes the
   "derivable at destination" gate cleanly, but only if the framework
   doesn't quietly leak shared-state through sub-out routing in a way
   that decomposes worse than expected.

Items 1 and 2 are SDK-shaped questions. Item 3 is a DSP-side concern
for the habitat-side voice engine and not a framework ask.

## Q1 — sub-chain presence detection (right-to-left cascade)

**The need.** For each voice N ∈ {1..6}, JF needs to know whether
voice N's trigger sub-chain has a patched source. If empty, cascade
from the nearest patched neighbor to the right. Cascade changes
rarely (only on user patch/unpatch), not at audio rate, so this is a
frame-boundary Lua read + a C++-side mask consumption.

**Probe results.**

- `xroot/Chain/Base.lua:521` — `ChainBase:length()` returns
  `self.pChain:size()`. Read on a `ControlBranch` returns the unit
  count of that sub-chain. `length() == 0` is the natural
  "no units patched in" check.
- `xroot/Chain/init.lua:179` — `Chain:getInputSource(i)` returns the
  `leftInputSource` / `rightInputSource` ref. Non-nil ⇔ the user has
  bound a Source (a cable from the local picker). This is closer to
  "is anything patched into the sub-chain inputs" than `length()`,
  and is what `Branch:isSerializationNeeded()` already uses
  (`Chain/Branch.lua:84`).
- `od/objects/Inlet.h:29` exports `Inlet::isConnected()`; `Outlet.h:28`
  exports `Outlet::isConnected()`. Author-guide pattern already gates
  sub-out compute on `Outlet::isConnected()` from C++.

**Verdict.** The primitive *does* exist Lua-side. Either
`branch:length() > 0` or `branch:getInputSource(1) ~= nil` will work.
The right answer for JF is probably **`getInputSource(1) ~= nil`**:
JF's trigger sub-chains semantically expect a source binding, not
just any unit added to the sub-chain.

**Open verification items.**

1. Cost of polling 6 sub-chains' input-source state per frame.
   Expected to be trivial (Lua field reads), but confirm.
2. Signal/mechanism for "cascade just changed" — is there a `Source`
   or `Branch` event we can hook (analogous to `contentChanged` in
   `Chain/Base.lua:518`), or do we just poll on every frame?
3. Whether re-binding cell N's input source via `Chain:setInputSource`
   under the cascade is the right consumption pattern, or whether C++
   should read all 6 inlets and dispatch through a mask.

**Recommended approach (proposed).** **Mask-based, not rebinding.**
Compute a `cascadeMask: u8[6]` Lua-side from the 6 sub-chains'
`getInputSource(1)` state, push it to C++ as a parameter; C++ reads
all 6 trigger inlets per block and uses `cascadeMask[N]` to select
the effective source for voice N. Keeps the audio thread free of
input-source mutation and avoids any inlet-buffer aliasing concerns.

Whether this needs framework support or is purely a habitat-side
implementation pattern is the actual question. **No framework change
expected to be required**, but flagging it here so it's a deliberate
"yes this is in-bounds" rather than a discovered surprise.

## Q2 — `subOutLabels` length 7

**The need.** JF has 6 voice outputs (1N…6N) plus a likely-separate
MIX output (sub-out 7). The framework's reference implementation is
QuadLFO at 4. Author guide
(`er-301-habitat/docs/multi-output-units-author-guide.md`) doesn't
declare a max length, but the picker overlay geometry might.

**Probe results.** Author guide line 53 (in
`07-multi-output-units.md`):

> Keep labels short (≤6 chars renders cleanly in the 42px ply at
> 10pt).

That's a per-label length cap, not a label-count cap. The M6 cycler
and the `X/Y` position indicator both scale with sub-out count. The
9-cap mentioned in habitat-side
(`Why JF for habitat's v1 multi-output unit`) comes from the
framework's "single-digit fan-out" wording — 7 is well under that.

**Open verification items.**

1. Confirm the M6 cycler renders cleanly at 7. Likely fine — it's
   modulo the count — but flag any visual regression.
2. Confirm the indicator's `X/Y` fits at 2 digits (`7/7` is the same
   width as `4/4`, so this is almost certainly a non-issue).
3. Confirm the picker presence-glyph (TODO from
   `07-multi-output-units.md` open follow-ups) doesn't bake in
   ≤6 fan-out.

**Recommended approach.** Build a 7-sub-out test unit (extension of
QuadLFO sample, 7 sine phases) before JF voice DSP starts — burns
half a day, validates the framework geometry, surfaces any cap
issues early instead of mid-port.

## Q3 — bipolar RAMP CV under GainBias

**The need.** JF's RAMP CV is bipolar (the technical map specifies
±5V at the jack). habitat's standard sub-control pattern is GainBias
+ CV inlet, which biases against the unit-side bias parameter. For
true bipolar CV through GainBias the user has to either use an
offsetting bias, or the unit needs a uni/bi shift-toggle (D8
pattern) to declare polarity.

**Probe results.** This is a habitat-side question, not a fw repo
question — the GainBias adapter and ParameterAdapter live in
`od/objects/`, but the uni/bi convention is a habitat UI decision
(see `feedback_parammode_convention` memory; D8). Logging here only
because it's listed in the JF planning doc's "open questions" and
might intersect framework if it surfaces a need to reshape the
GainBias contract.

**Verdict.** No framework ask expected. Resolve in habitat with a D8
shift-toggle on the RAMP control. Removing from the framework-side
question list.

## Q4 — through-zero linear FM precedent

**The need.** JF's Sound range applies TZ-linear FM to the slope
engines' phase accumulator. habitat has lin/expo FM (Helicase) but
not TZ-linear anywhere in the framework or shipped voices.

**Verdict.** Not a framework concern — TZ-linear FM is a per-voice
DSP concern. The phase accumulator implementation lives in the
voice's own code. Flagged here for completeness but resolved as
habitat-side.

## Q5 — 6 slope engines @ 48 kHz on Cortex-A8

**The need.** CPU budget concern. 6 phase accumulators + polyBLEP
morph + per-voice phase-receptivity state machine. Worst case is all
6 voices in Sound range with continuous CV mod on every global.

**Verdict.** Not a framework concern; profile early on hardware
during habitat-side voice engine work. The
`feedback_neon_intrinsics_drumvoice` and
`feedback_neon_hint_surfaces` memories cover the
am335x-codegen traps that will likely matter here. Resolved as
habitat-side.

## Summary of asks on the firmware repo

After probing, **only Q1's verification items are arguably
framework-side**, and even those lean toward "no change needed,
document the pattern":

1. **Confirm cascade poll cadence has a clean signal.** Is there a
   `branch:contentChanged` event the cascade-mask computer can hook,
   or is per-frame polling the recommended pattern?
2. **Confirm 7 sub-outs render cleanly** — picker overlay geometry,
   M6 cycler, presence glyph (when it ships). Validation could be a
   small extension of the QuadLFO reference unit; doesn't need any
   framework change unless a regression surfaces.

Q3, Q4, Q5 from the JF planning doc are **resolved as habitat-side**
on second read, not framework asks.

## Suggested next step (firmware-side)

Adding a `Branch:onContentChanged` hook (or surfacing
`Chain/Base.lua:518`'s existing `contentChanged` signal cleanly to
ControlBranch consumers) would let JF — and any future cascade-using
unit — react to patch/unpatch events without polling. **Low priority
work-item; only worth doing if Q1 verification finds polling cost
non-trivial.** Logging it here so a future cascade-using unit
doesn't have to rediscover the ergonomics.

Otherwise: no firmware-side changes are blocking JF. Authors can
proceed against the framework as-shipped.

# 13 — Stolmine Core Package (Multi-Output Core Units)

Dedicated stolmine-branded Core package that replaces vanilla Core as the
default install on stolmine firmware while bundling vanilla Core alongside
(built but not auto-installed). Purpose: bring multi-output capability into
the core DSP library — for existing units that gain real composability from
fan-out, and for new units whose design is native to multi-output.

Dependencies: multi-output framework shipped 2026-04-21 (file 07, commits
`7d99be1` + `a9cc47d`). No C++ ABI work expected; all fan-out affordances
already live in Lua + LocalChooser.

## Install policy

- Firmware build produces **both** packages: stolmine-core and vanilla-core.
- Firmware installer activates stolmine-core on fresh install and upgrade.
- Vanilla-core lives in the package staging area (same place third-party
  packages do) so a user can opt into it manually from the package manager.
- Coexistence strategy: either (a) stolmine-core takes a distinct package
  namespace (e.g. `core2.*`) so both can load without picker duplicates, or
  (b) the two are mutually exclusive and the installer enforces that only
  one is enabled at a time. **Open decision**.

## Retrofit Audit — Existing Core Units

Rubric: what does fan-out buy the user vs. what does the same result cost to
build from chain primitives today? Tier 1 = non-optional composability win.
Tier 2 = useful, workaroundable. Tier 3 = skip.

### Tier 1 — High value, clear win

| Unit | Sub-outs | Why |
|------|----------|-----|
| **ADSR / SkewedSine / Sine envelope** | env, inverted env, EOA, EOR/EOC, stage-active gate | EOC alone saves a comparator in every patch. |
| **Looper (Dub / Feedback / Pedal)** | audio, **loop-position phase**, start-of-loop trigger, recording/playing/overdubbing gates | Phase tap is the killer feature — phase-locked FX over a looper is a whole subgraph today. |
| **Players (VariSpeed, GrainStretch, Raw, Card)** | audio, **play-position phase**, EOF trigger, playing gate | Same phase-tap argument. Currently needs a phase-estimator downstream. |
| **Delays (Delay, Doppler, Clocked, Micro)** | delayed signal, **pre-feedback tap** (insertable feedback path), per-tap audio for multi-tap variants | Pre-feedback tap is a long-standing modular wish. Multi-tap is its own redesign but could live inside one delay core. |
| **Ladder filter (LadderFilter, LadderHPF, stereo variants)** | primary (LP4/HP4), **LP1 / LP2 / LP3 pole taps**, resonance feedback tap | Pole states already exist internally; exposes Moog-style multi-mode without a new unit. |
| **Clocks (Clock, ClockInBPM, InHertz, InSeconds, TapTempo)** | main gate, /2, /4, /8, /16 taps, phase-shifted taps (+90/180/270°) | Replaces the "clock into four dividers" pattern every patch has. |
| **ScaleQuantizer / GridQuantizer** | quantized, **note-changed trigger**, delta-from-quantized (cents / grid-steps) | Note-changed alone drives arp/chord workflows; currently built from ZCD over delta. |
| **Counter** | count, **rollover trigger**, direction gate, reset echo | Rollover-to-next-counter is the canonical multi-count chain. |
| **Limiter / Clipper** | output, **gain-reduction signal**, over-threshold gate | Standard compressor tap trio. Enables sidechain/ducking off one unit. |
| **ZeroCrossingDetector** | trigger, **direction (rising/falling)**, period / frequency estimate | Direction is a free byproduct; period takes one extra counter. |
| **RoundRobin** | audio, **per-voice gates**, active-voice index | Polyphonic voice-alloc workflows are currently chain-heavy. |

### Tier 2 — Nice wins, moderate cost

| Unit | Sub-outs | Why |
|------|----------|-----|
| **EnvelopeFollower** | magnitude, peak-hold companion, attack/release-active gates | Useful but workaroundable. |
| **Rectifier** | full-wave, half-wave+, half-wave−, sign | Cheap to expose; modest savings. |
| **SlewLimiter / DeadbandFilter / Stress** | output, slew-saturated gate, rate-hit trigger | Diagnostic/shaping sub-outs. |
| **Equalizer3** | summed, low-only, mid-only, high-only | Enables per-band processing without a 3-way split. |
| **MultiBand containers (2/3/4/5/6 Bands)** | each band as a sub-out | Reframes topology; currently spawns sub-chains. Bigger refactor. |
| **TrackAndHold / SampleHold** | held, triggered-gate, delta from prior hold | Small but essentially free. |
| **ManualGrains / GrainStretch** | audio, **grain-start trigger**, grain-phase | Grain triggers drive polyrhythmic work. |
| **Freeverb / SchroederAllPass** | wet, dry tap, **early reflections vs late reverb** split | Early/late split is the real win; dry tap is redundant with a mixer. |
| **PulseToFrequency / PulseToSeconds** | freq, period, detected-pulse count | Cheap to include. |

### Tier 3 — Skip (leave for vanilla)

VCAs (LinearBipolar/Unipolar/Rational), Noise (White/Pink/Velvet),
Convolution, Fold, Spread, Offset, SnapToZero, RationalMultiply — single-
purpose, no obvious sibling signals. Heads (RawHead, LoopHead, etc.) are
building blocks, not user-facing.

## Framework caveats surfaced by the audit

1. **SlicedWaveForm per-slice gates are N-variable.** A sample has 1–256
   slices. Multi-output framework today assumes a fixed sub-out count
   declared at Unit init (`args.subOutLabels` is a static list). Per-slice
   gates would need the framework to support **dynamic sub-out count bound
   to unit state**. Two paths:
   - Extend the framework to support dynamic sub-out count that rebuilds
     when unit state changes. Non-trivial — LocalChooser caches, preset
     serialization, connection queue all assume fixed shape.
   - Model per-slice-gate workflows as `current-slice-index (CV)` +
     `slice-boundary trigger` (2 sub-outs, static). Users reconstruct per-
     slice gates downstream with addressed switches / comparators.
   - Recommend path 2 for v1 of the stolmine-core package; revisit dynamic
     sub-out count if real workflows demand it.

2. **Ladder tap retrofit needs the DSP layer to expose pole states.**
   `LadderFilter.cpp` currently runs the chain and writes only the final
   output. Exposing per-pole taps means writing intermediate states to
   additional output buffers — cheap CPU but requires `Outlet::connected()`
   gating so unused taps don't pay the cost. Confirms the broader
   opt-in-compute principle.

## New Unit Candidates (multi-out native)

### Proposed set

| Unit | Viability | Notes |
|------|-----------|-------|
| **1→X clocked switch** | Strong | Fan-out is the point. Add: current-index readout, wrap/bounce/random mode, "new channel" trigger. |
| **Shift register** | Strong | N-stage by definition. Add: CV-determined stage length, direction flip, feedback-to-input tap. |
| **Mid-side encoder/decoder** | Moderate | Core encode/decode are 2-out (fits vanilla). Win is a combined unit with M/S-only passthrough + L/R reconstruction simultaneously for parallel processing. |
| **1→X scanning crossfader** | Strong | Smooth version of clocked switch. Add: adjustable crossfade width per boundary, linear vs equal-power curves. |
| **1→X addressed switch** | Strong | CV-addressed hard switch. Complements the crossfader. |
| **Multishape osc** | Strong | Classic multi-out. Sin/tri/saw/pulse + sync output + hard-sync input gate. Per-shape bandlimiting strategy is a design decision. |
| **Multimode filter (SVF)** | Strong | LP/HP/BP/notch from one state-variable core is free. Add: allpass out if topology supports it cheaply. |

### Additional candidates

| Unit | Notes |
|------|-------|
| **Clock divider** | Standalone, no internal clock. Clock in → /2, /3, /4, /5, /7, /8, /16 outs. Pairs with retrofitted Clock unit for users who want dividers off external clock. |
| **Logic gate bank** | A, B in → AND, OR, XOR, NAND, NOR, XNOR out on one unit. Saves massive chain real estate for trigger-logic patches. |
| **Bernoulli / weighted router** | 1 in → N outs, CV-weighted random routing. Complement to the addressed switch. |
| **Comparator with hysteresis** | In → over, under, in-window, exit-window triggers. Pattern-detection primitive. |
| **Euclidean generator** | N-pattern Euclidean with main + rotation variants as sub-outs. |
| **Multi-phase LFO** | User-configurable phase offsets per output (up to 4 or 6). Generalizes the QuadLFO test fixture into a real unit. |
| **VCA + follower** | Signal out + envelope-of-signal out. Universal compression/ducking primitive. |
| **Slice addresser** | Sample + slice-index CV → audio + slice-trigger + slice-active gate. Sidesteps the N-variable-sub-outs problem by decoupling "which slice" from "gate per slice." |

## V1 Scope Recommendation

Ship a focused subset — don't land all Tier-1 retrofits at once.

**Retrofit in v1 (~8 high-signal units):**

- Envelopes: ADSR, SkewedSine, Sine
- Loopers: DubLooper, FeedbackLooper, PedalLooper
- Players: VariSpeed, GrainStretch, CardPlayer
- Ladder filters: LP + HP variants, mono + stereo
- Clocks: Clock, ClockInBPM, ClockInHertz, ClockInSeconds, TapTempo
- Quantizers: Scale, Grid
- Counter
- Limiter, Clipper

**New units in v1 (3–4 to demonstrate multi-out-native design):**

- Multishape oscillator
- Multimode filter (SVF)
- 1→X addressed switch
- Logic gate bank

First two are the "oh *that's* what this firmware is for" units new users
would notice. Second two showcase fan-out for control/logic workflows and
fill gaps vanilla has always had.

## Open Questions

- **Package ID / namespace.** `core2.*` for coexistence vs. mutually-exclusive
  installation via installer enforcement. Coexistence has better UX but
  doubles the picker footprint when both are enabled.
- **In-tree strategy.** Fork `mods/core/` in full (easier to modify, big
  duplication) vs. start fresh under `mods/stolmine-core/` importing DSP
  objects by reference (cleaner tree, harder diff-tracking when vanilla core
  changes upstream).
- **Opt-in compute scope.** Use `Outlet::connected()` gating everywhere, or
  reserve it for the heavier retrofits (pole taps, early/late reverb splits).
  Principle is same either way; question is whether to enforce as a package
  convention or case-by-case.
- **Preset portability UX.** On vanilla-core load, sub-out indices ≥2 snap to
  primary (same as existing multi-out framework). Document in user guide; no
  code change needed beyond the existing fallback.
- **Per-shape bandlimiting for multishape osc.** Aliasing story differs per
  waveform — polyBLEP, wavetable, naive. Decide before implementation.

## Dependencies and Sequence

1. Multi-output framework — **done** (file 07).
2. Package infrastructure — decide namespace + installer staging.
3. Retrofit audit — **this document** sets the v1 subset.
4. Per-unit implementation — one PR per unit or per category, each with
   preset-migration test (stolmine preset round-trips; vanilla-core load
   degrades cleanly).
5. QuadLFO (file 07 test fixture) generalizes into Multi-phase LFO as one
   of the new units.

# 14 — Multi-Output CPU Cost Model

Grounded estimate of what it costs to add a sub-output to a unit. Reference
for the stolmine-core retrofit audit (file 13) and for habitat unit authors
deciding how aggressively to fan out.

Derived from inspection of `od/objects/Outlet.cpp`, the pre-allocated frame
pool in `od/AudioThread.cpp`, and the audio-rate contract in `hal/constants.h`.

## Framework overhead (per outlet, per frame)

Measured against the Outlet lifecycle:

| Scenario | Cost |
|---|---|
| Declared Outlet, never written | ~16 bytes metadata + one `std::vector` entry. No buffer allocation (lazy via `Outlet::buffer()` at `Outlet.cpp:63-78`). Effectively zero. |
| Active Outlet, first frame | One `AudioThread::getFrame()` pool draw + `memset` of FRAMELENGTH floats. ~1 µs one-shot. |
| Active Outlet, subsequent frames | `buffer()` returns cached `mBuffer` pointer. One branch + pointer return, ~5–10 ns. |

At 96 kHz / 64-sample frame (~1500 Hz frame rate), the steady-state framework
overhead per active outlet is **~15 µs/sec**, or **≈0.0015% of one Pi4
core**. Negligible.

**There is no automatic "skip if no consumers" gate.** `Object::process()`
runs unconditionally; the unit author decides whether to check
`Outlet::isConnected()` before computing into the sub-out buffer. This is the
load-bearing convention for keeping fanout cheap.

Memory: FRAMELENGTH × 4 bytes per active outlet (512 bytes at 128-frame),
drawn from a 512 KB pre-allocated pool (`AudioThread.cpp:40`). Not CPU-relevant.

## DSP cost — three categories

The actual compute behind a sub-out varies by orders of magnitude. Classify
each before estimating.

### Category A — free byproducts
Signals already computed as internal state; the sub-out is a write-through.

Examples:
- Inverted envelope
- EOC / EOR / EOA triggers
- Play-position phase on a sample player
- Gain-reduction signal on a limiter
- Ladder-filter pole taps (LP1 / LP2 / LP3)
- SVF LP/HP/BP/notch from one state-variable core
- Rectifier half-wave and sign splits

Cost: **<0.1% of parent unit's CPU** per sub-out. A NEON-vectorized 64-sample
write is ~16 SIMD stores ≈ 50 ns per frame.

### Category B — derived outputs
Signals requiring trivial additional computation.

Examples:
- Pre-divided clock taps (one counter per division)
- ZCD direction (one branch beyond the main trigger)
- Counter rollover / wrap
- ScaleQuantizer "note-changed" trigger
- PulseToFrequency / PulseToSeconds companions
- Per-slice boundary trigger on a sliced player

Cost: **1–5% of parent unit's CPU** per sub-out. A handful of extra
branches / compares per sample, cheap but measurable.

### Category C — genuinely new signal paths
Signals requiring independent computation that wasn't happening before.

Examples:
- Early-reflections vs late-reverb split in Freeverb
- Pre-feedback delay tap (restructures the feedback path)
- Per-band outputs on a multiband split
- Additional read-heads at different positions in a sample player

Cost: **highly variable** — from negligible (if the work was already being
done and only exposure changes) to doubling the unit's CPU (if the sub-out
duplicates a pipeline). Not a "retrofit" in the cheap sense — these are unit
redesigns. Benchmark individually.

## Typical Tier-1 retrofit envelope

Most high-value retrofits land at 3–4 sub-outs, mostly Category A plus one
Category B:

| Unit | Sub-outs | Mix | ΔCPU on that unit |
|------|----------|-----|-------------------|
| ADSR | inverted, EOA, EOC, stage-gate | 3A + 1B | ~1–2% |
| Ladder filter | 3 pole taps | 3A | <0.5% |
| Clock | /2, /4, /8, /16 taps | 4B | ~2–4% |
| Looper | phase, start trigger, state gates | 2A + 1B | ~1–2% |
| Limiter | GR signal, over-threshold gate | 2A | <0.5% |
| ScaleQuantizer | note-changed, delta | 2B | ~2–3% |
| Counter | rollover, direction, reset echo | 3B | ~3–5% |

Plus ~0.01% framework overhead regardless. **Average retrofit: ~1–3% of the
parent unit's own CPU budget.**

Absolute terms on Pi4: a typical ADSR at 0.5% of one core becomes ~0.51%
after a 4-outlet retrofit. Rounding error.

## Where cost actually matters

1. **Sub-outs on heavy parents.** Granular stretcher at 15% of core × 3%
   retrofit = 0.45% absolute. Convolution reverb at 40% × 3% = 1.2%.
   Worth monitoring. Audit on measured not estimated cost for parents >10%
   of core.

2. **Category C outlets.** Rule-of-thumb collapses; benchmark individually.

3. **N-scaling sub-outs.** Per-slice gates or per-voice outputs where count
   scales with state. 32 slices × Category B cost each can add up. File 13
   recommends avoiding this pattern in favor of (index CV + boundary
   trigger) two-outlet designs.

4. **Worst-case fanout across a full patch.** If a user patch has 50 units
   and each ships 3 retrofit sub-outs, worst-case (all connected, all
   Category B) is 50 × 3 × 3% × parent-avg = ~5% of a core on top of the
   patch's baseline. Usually far less in practice because most sub-outs
   aren't consumed.

## Opt-in compute pattern — load-bearing best practice

The `Outlet::isConnected()` gate eliminates unused-sub-out cost entirely.
Pattern for C++ DSP:

```cpp
void MyMultiOut::process() {
  float *primary = getOutput(0);
  float *sub1    = getOutput(1);
  float *sub2    = getOutput(2);

  // Unconditional: primary is almost always consumed and gating it
  // adds a branch for no win.
  computePrimary(primary);

  // Gated: skip the math when nobody's listening.
  if (mSub1Outlet.isConnected()) {
    computeSub1(sub1);
  }
  if (mSub2Outlet.isConnected()) {
    computeSub2(sub2);
  }
}
```

With gating:
- Unused sub-out cost drops to **~1 ns/frame** (one branch). Effectively zero.
- Cost-when-used is unchanged.
- Memory cost-when-used is unchanged (buffer still allocated when someone
  connects).

Rule of thumb for stolmine-core authors:
- **Primary out: don't gate.** It's almost always consumed; the branch is
  waste.
- **Category A sub-outs (free byproducts): gating optional.** The compute
  is cheap enough that gating sometimes costs more than it saves on a
  hot path. Prefer gating if the parent unit is a tight loop (oscillators,
  filters); skip gating on envelopes and clocks.
- **Category B and C sub-outs: gate.** These have real compute cost worth
  avoiding when unused.

## Where this lives in the author experience

- Habitat authors: see `er-301-habitat/docs/multi-output-units-author-guide.md`
  § "CPU cost and opt-in compute" for the practitioner version of this
  document.
- Stolmine-core retrofits: file 13 v1 subset assumes opt-in compute is the
  default convention for the package.

## Open items

- **Measured validation.** Above is inspection-plus-estimation, not measured.
  Build a micro-benchmark once the v1 retrofit subset lands: sum of per-unit
  ΔCPU against a baseline vanilla-core patch with the same topology. File 12
  (RP2040 latency jig) is for round-trip latency, not per-unit CPU;
  on-device CPU profiling wants `od::extras::Profiler` hooks.
- **Automatic gating.** The framework could in principle skip Outlet writes
  when `!isConnected()` by replacing the returned buffer with a write-to-
  nowhere stub. Would eliminate the per-author gating burden. Requires a
  framework extension: `Outlet::getWriteTarget()` returning either the real
  buffer or a shared scratch, with the author writing unconditionally. Not
  committed; flag for future consideration if opt-in gating becomes a
  compliance headache.

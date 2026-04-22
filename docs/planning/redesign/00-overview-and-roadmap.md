# ER-301 Standalone Redesign — Overview & Roadmap

## Project framing

A standalone redesign of the Orthogonal Devices ER-301 sound computer, repackaged as a desktop device (not Eurorack-first) intended to functionally replace a modular case at lower cost. Long-horizon R&D, ~24–36 months (median ~30mo), five-figure materials/tooling budget.

**Primary audience:** existing ER-301 users — the chain paradigm and muscle memory continuity are non-negotiable.
**Secondary audience:** broader users brought in by standard I/O (USB-C, 1/4" jacks, class-compliant audio/MIDI).

A shared mainboard serves both a desktop variant and a Eurorack variant; variant-specific behavior lives on the daughterboard.

## Phase roadmap

| Phase | Months | Work |
|-------|--------|------|
| 0 | 0–6 | Electronics ramp |
| 1 | 3–9 | Firmware port to CM4 |
| 2 | 6–12 | USB stack + dual i2c implementation (parallel) |
| 3 | 6–14 | Hardware design + Rev A PCB layout (parallel) |
| 4–5 | 14–22 | Bring-up, Rev B, firmware on real hardware |
| 6 | 20–26 | Closed alpha (5–10 units) |
| 7 | 24–30 | Open beta (50–100 units) |
| 8 | 28–36 | Production prep |

Phases are deliberately overlapped where dependencies allow.

## Cross-cutting principles

- **Muscle memory continuity is a hard constraint.** UI conventions from the original 301 (1D chain paradigm, encoder + soft keys, physical output buttons spatially mapped to DAC 1–4) carry over unchanged.
- **Scope containment is a feature.** The device deliberately does *not* absorb adjacent products' scope (notably Crow's scripting and USB-to-i2c bridge). Keeping v1 tight avoids duplicating someone else's product and reduces long-term maintenance.
- **Clean ownership beats arbitration.** Where a system has a choice between negotiating between roles or splitting roles cleanly, split them. (See i2c architecture.)
- **Coupling belongs to producers, never consumers.** A unit may declare its outputs semantically bound (it owns the shared internal state). Inputs are always independent subscription slots — binding them would assert a relationship the unit didn't produce.
- **Decisions are locked early and explicitly** to constrain scope and reduce rework over a multi-year timeline.
- **Shared mainboard across variants** to reduce divergence risk over the long timeline.

## Compute / I/O target headlines

- CM4 or RPi5; sub-3ms latency target at 96kHz
- Dual i2c (one leader-out bus, one follower-in bus) — both exposed on rear as 3.5mm TRS
- 8 onboard CV/gate outputs (TXo-derived), audio-rate, ±10V swing
- USB-C with USB-PD; ±12V generated onboard (TPS65131-class) for desktop variant
- USB UAC2 audio: 4-in / 4-out, async (device is master)
- MIDI 1-in / 1-out: clock + 7-bit CC only, no note management in v1

See domain-specific files for detail.

# Latency Test Jig (RP2040-based)

**Status:** proposed. Applies during bring-up, after the audio path is functional on the target hardware (CM4/CM5).

## Purpose

Produce repeatable, quantitative latency numbers for the redesigned device — per-path, with distribution (median + tail), not a single "RTL" number that hides where the time goes.

The sub-3 ms at 96 kHz target in `00-overview-and-roadmap.md` is unfalsifiable without a measurement rig that is tighter than the thing under test. A host DAW loopback isn't: OS scheduling jitter and host driver buffering are in the same order of magnitude as the numbers we're trying to resolve.

## Why RP2040

- **Deterministic.** Bare metal, no OS; no scheduler jitter on the measurement side.
- **PIO = cycle-accurate timestamps.** 125 MHz, 8 ns resolution. Stimulus edge and response edge are timestamped on the same clock domain and subtracted directly.
- **Dual core.** Core 0 drives stimulus and I/O; core 1 runs stats and USB-CDC reporting. No contention with the timing path.
- **Cheap enough to dedicate one per rig** (~$4 + analog front-end). One jig lives at the bench, a second can ship with any external reviewer.

## Measurements

Separate the paths — a combined RTL number hides the contributors:

| # | Path | What it isolates |
|---|------|------------------|
| 1 | Audio RTL | Pico DAC → device IN1 → identity chain → device OUT1 → Pico ADC | Engine + codec floor (block size × 2 + group delay) |
| 2 | Trigger → audio | Pico GPIO edge → gate input → min env/VCA → audio out | What a player feels on a trigger |
| 3 | CV → audio | Pico DAC ramp → CV input → VCA → audio out | CV-path smoothing / ramp cost |
| 4 | I2C command → CV | Pico as i2c leader, timed write → onboard CV output moves | Direct relevance to TXo-follower path (file 02) |
| 5 | MIDI → audio | Pico USB-MIDI note-on → audio onset | 7-bit CC + clock path (file 05); note path only if v1 scope expands |
| 6 | USB audio RTL (future) | Device-side USB-in → internal chain → USB-out, triggered by Pico GPIO reference edge | Device-side USB audio contribution, isolated from host buffering |

Report median and 99th percentile per path. Tail latency is what bites on stage; mean hides it.

### USB audio — measurement note

Path #6 is a provision for when the UAC2 stack (file 04) is alive on real hardware. It is deliberately scoped to the device-side contribution only — the Pico sends a GPIO timing reference and the device does a USB-in → chain → USB-out loopback against it. This isolates:

- Device-side async resync ring buffer (we own this and want to tune it)
- Microframe scheduling on the device side
- Engine block latency (shared with path #1, useful as a cross-check)

It does **not** measure host-side buffering (DAW buffer size, OS audio stack, driver). Full host-in-the-loop USB RTL is a separate release-notes exercise — report as "device-side + host@buffer-size-N" with buffer size as an explicit axis, because the host term typically dominates and varies per OS / DAW / buffer setting.

Running path #6 requires a USB host for the device. Options, in order of preference: (a) the final product's CM4/CM5 already is the device — pair it with a separate Linux host dedicated to the jig; (b) drive it from a known-good USB host with a tight, measured baseline; (c) RP2040 as UAC2 host — possible on Pico 2 but the class driver is non-trivial and not justified unless (a)/(b) prove insufficient.

## Minimum viable jig

- RP2040 (Pico or Pico 2) + one op-amp front-end: ±10 V ↔ 0–3.3 V, clamped. Device I/O is ±10 V; Pico ADC is 0–3.3 V — the scaler is not optional.
- Stimulus DAC: PWM-as-DAC adequate for step/gate; PCM5102A over I²S-PIO for clean audio stimulus.
- Capture: on-board 12-bit ADC (~500 ksps) is sufficient for timing — the job is edge/onset detection, not audio-quality capture.
- Host link: USB-CDC, CSV dump of N trials.

## What counts as "passing"

- Audio RTL at 96 kHz: ≤ 3 ms median, ≤ 4 ms 99p (matches roadmap headline).
- Trigger → audio: ≤ 5 ms 99p with a minimal env/VCA chain.
- I2C command → CV: ≤ 1 ms 99p on the leader bus (budget the TXo-follower round-trip against this).
- MIDI CC → audio-rate parameter: ≤ 8 ms 99p (USB-MIDI + 7-bit smoothing).
- USB audio device-side RTL: target TBD — the jig exists partly to establish what's achievable with the chosen UAC2 descriptors and ring-buffer depth.

Numbers are provisional — the jig exists to establish real ones, not to confirm these.

## When this runs

During the bring-up phase (roadmap phases 4–5) once the audio path is alive on the target hardware. Re-run as a regression check:

- After any change to block size, sample rate handling, or engine scheduling.
- After RT_PREEMPT tuning on Linux-based compute.
- Before each closed-alpha / open-beta cut.

## Non-goals

- Measuring audio *quality* (THD+N, dynamic range). That's a separate bench setup with a proper audio analyzer; the Pico ADC is not the tool.
- Measuring UI-to-audio latency. Encoder/fader-to-audio latency is worth measuring but requires a mechanical actuator; out of scope for v1.
- Full host-in-the-loop USB audio RTL. The jig characterizes device-side USB contribution; the host-side term varies per OS/DAW/buffer and belongs in release-notes characterization, not bring-up validation.

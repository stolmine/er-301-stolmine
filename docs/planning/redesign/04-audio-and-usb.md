# USB Audio

**Status:** locked.

## Spec

- **Class:** UAC2 (USB Audio Class 2 — class-compliant, no driver needed on macOS/Linux/iOS; standard driver on Windows).
- **Channel count:** 4-in / 4-out, fixed.
- **Clock mode:** async, **device is master**.
- **Sample rate:** tied to the engine rate.
  - Default: 48 kHz
  - 96 kHz available in admin mode only.
- **Host-side disable:** supported.

## Mapping to the unit model

USB audio is integrated through the existing source/destination unit paradigm — there is no new routing page or virtual-patch abstraction:

- **USB audio out** maps to **4 existing audio chain termini**.
- **USB audio in** presents as **4 virtual source units**.

This means a USB audio channel is selected exactly the way a hardware input or output is selected — through the existing source picker / destination picker. See the I/O unit model file for the broader pattern.

## Why fixed channel count

Variable channel count would require dynamic UAC2 descriptors, host re-enumeration, and additional source/destination unit lifecycle logic. None of that buys anything for the v1 audience. 4×4 covers the realistic use cases (DAW return pair + utility pair in each direction) and matches the existing spatially-mapped output button layout.

## Why device-master clock

The 301 engine is the source of truth for timing. Letting the host clock the device would either force resampling (latency + quality cost) or force the engine to chase the host (jitter + complexity). Device-master is the correct topology for an instrument.

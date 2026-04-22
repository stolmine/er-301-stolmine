# Controller Section

**Status:** fader spec locked. Knob count, knob layout, and prefix naming open.

## Hardware

- **4 × ALPS 60mm faders** in a 12HP band (60mm = 16n standard, fits within 3U for the Eurorack variant).
- **4–8 full-size knobs** (premium feel is the priority — full-size only, no knoblettes).
- **4 buttons.**

## Layout (open)

Knobs likely **right of the faders** as a 1×4 or 2×4 grid. **Not above the faders** — full-size knobs in-column would break the fader pitch and make the band visually inconsistent.

Encoders with LED rings are favored for the freely-assignable paradigm but not yet committed.

**Note:** the 16n itself is *just* 16 faders — no knoblettes or buttons on it. The combined fader + knob + button form is original to this device, not a clone of 16n.

## Integration with the unit model

Controls plug into the **existing 301 unit model** — no new abstractions, no bind/learn UI. Physical faders, knobs, and buttons present as **source units** in the source picker, parallel to existing hardware-input source units like `sc.cv` and `sc.tr`.

**New prefix TBD.** Candidates: `lc.*` (local controls) or `pc.*` (panel controls). Naming open.

Implementation: reuse existing source-unit code; just add new entries to the source picker.

## Electronics

- **Carrier board does direct ADC read** — no i2c latency in the control path.
- Dedicated **multi-channel ADC**, ~12–14 bit.
- **Smoothing on fader reads** is required to prevent zipper noise on assigned destinations. (Standard low-pass / hysteresis treatment; tune empirically.)

## Why direct ADC, not i2c

i2c adds latency (poll cycle + bus contention with whatever else is on the leader bus). Faders are performance controls — sub-frame response matters. A dedicated ADC with DMA into the engine gives the same latency profile as the existing 301's CV inputs.

## BOM note

Estimated cost for the controller section: ~$53–85, depending on knob count (4 vs 8) and quality tier. See BOM file.

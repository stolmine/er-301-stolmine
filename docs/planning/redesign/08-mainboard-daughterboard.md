# Mainboard / Daughterboard Architecture

**Status:** locked.

## Topology

A **shared mainboard** serves both the desktop and Eurorack variants. Variant-specific behavior lives on a **daughterboard**, connected via a **mezzanine connector** (no ribbon cable).

## What lives on the mainboard

- Compute (CM4/CM5 carrier)
- Audio I/O (codec, op-amps)
- 8 CV/gate output channels (TXo-derived)
- Front-panel UI (encoder, soft keys, OLEDs, output buttons, controller section)
- Front-panel 3.5mm Eurorack I/O jacks (populated on both variants — see form factor file)

## What lives on the desktop daughterboard

- Rear 1/4" output jacks
- Rear 3.5mm TRS jacks for the dual i2c buses
- USB-C input
- USB-PD negotiation
- ±12V rail generation (TPS65131-class boost/inverter)

## What lives on the Eurorack daughterboard

- Eurorack power header (takes ±12V from the bus instead of generating it)
- (Likely no rear jacks — Eurorack variant exposes everything on the front)

## Why this split

The mainboard is the high-cost, design-intensive board. Sharing it across variants:
- Reduces divergence risk over a 24–36 month timeline (one schematic, one BOM, one bring-up effort for the hard parts).
- Lets variant-specific power and connectivity live in cheap, easy-to-respin daughterboards.
- Means firmware sees one hardware target.

## Why mezzanine, not ribbon

Ribbon cables introduce mechanical failure modes, signal integrity issues, and assembly inconsistency. A mezzanine connector gives a known geometry, easier QA, and a cleaner enclosure stack-up.

## Implications for layout

- All jack footprints and routing for the front-panel Eurorack I/O are committed on the mainboard regardless of variant — this is the basis for the "keep front jacks populated on desktop" decision (see form factor file).
- The mezzanine connector pinout is itself a long-lived interface contract — it needs to anticipate any plausible future daughterboard before Rev A locks.

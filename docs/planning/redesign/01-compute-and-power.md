# Compute & Power

**Status:** core decisions locked; CM5 forward-compat strategy locked.

## Compute

- **Target SoC:** CM4 (primary) with forward-compatible carrier for CM5.
- **Latency target:** sub-3ms at 96kHz.
- **Firmware port to the new compute is the Phase 1 deliverable.**

### CM4/CM5 silicon strategy

Design the carrier for forward compatibility from day one:
- CM5 (released late 2024) is mostly pin-compatible with CM4 but ~23 pins differ.
- Avoid the two 2-lane MIPI interfaces removed in CM5 (unused for our purposes anyway).
- Route PCIe with landing pads for CM5's `nWAKE` / `PWR_EN` signals.
- Goal: the CM5 port becomes a **Rev C** spin, not a redesign.

CM4 is in production through January 2035, so the timeline is comfortable. Hedge supply via third-party CM4-pin-compatible modules (Radxa, Pine64). All firmware uses Linux abstractions — no SoC-specific code paths.

## Thermal

- Aluminum baseplate acts as a passive heatsink.
- CM4 thermally bonded to baseplate via a gap pad.
- No active cooling — silent operation is a requirement.

## Power

- **Input:** USB-C with USB-PD negotiation.
- **Onboard rails:** ±12V generated via boost/inverter (TPS65131-class).
- **Power topology lives on the daughterboard** — see mainboard/daughterboard architecture file.

The Eurorack variant takes ±12V from the bus instead of generating it; the desktop daughterboard provides the USB-PD + ±12V generation block.

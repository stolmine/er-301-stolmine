# MIDI

**Status:** v1 scope locked deliberately tight.

## Spec

- **Ports:** 1 in / 1 out.
- **Message types in v1:** clock + CC only.
- **CC resolution:** 7-bit only (no 14-bit / NRPN).
- **Channel selection:** per-unit.

## Explicitly out of scope for v1

- Note management (note on/off, polyphony, voice allocation)
- 14-bit CC and NRPN
- Sequencing
- SysEx
- MPE

## Rationale

7-bit CC and clock are well-known, well-tested, and have no edge cases worth worrying about. Adding note management or 14-bit CC drags in a long tail of design decisions (channel modes, note-stealing, per-note pressure, RPN coordination) that don't serve the v1 audience and would block more important work.

The device's primary control surface is its own controller section, faders, encoder, and i2c — MIDI is a connectivity feature, not the primary interaction model. Keeping v1 narrow leaves room to add note management cleanly in a later release if real demand surfaces.

## Mapping to the unit model

MIDI CC integrates through the existing source/destination unit paradigm:
- **CC in** presents as source units (per-channel).
- **CC out** is a destination unit type.
- Last-writer-wins arbitration on outputs (consistent with the rest of the I/O model).

No bind/learn UI; no separate MIDI mapping page.

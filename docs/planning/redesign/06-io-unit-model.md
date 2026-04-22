# I/O Unit Model

**Status:** locked. Defines how every new I/O type integrates.

## Core principle

**Every I/O is a unit.** The redesigned 301 does not introduce a routing page, a virtual patch-cable graph, or any second mental model on top of the existing chain paradigm. New I/O (USB audio, MIDI CC, CV/gate, controller surface) is added by adding new entries to the existing source picker and destination picker — nothing more.

## Sources and destinations

- **Source units** represent inputs. Examples: `sc.cv` (sample chain CV in), `sc.tr` (sample chain trigger in), USB audio in (4 virtual sources), MIDI CC in (per-channel), controller faders/knobs/buttons (new prefix TBD, candidates `lc.*` or `pc.*`).
- **Destination units** represent outputs. Examples: audio chain termini (4 of them, mapped to the physical output buttons), USB audio out (mapped to those same 4 termini), CV/gate outs (8 of them), MIDI CC out.

A source is selected by picking it in the source picker on a chain. A destination is, well, the chain itself.

## Arbitration rules

- **Audio outputs:** implicit-sum at the accumulator. Multiple chains can write the same audio terminus; they sum.
- **CC outputs:** last-writer-wins.
- **Clock:** single-source.

These rules are the existing 301 behavior carried forward — no change.

## Why no routing page

A routing page would:
1. Introduce a second authoritative location for "what is connected to what" (the chain *and* the routing page).
2. Force users to context-switch between two paradigms during a performance.
3. Break the muscle memory of existing 301 users, which is the project's hard constraint.

Pushing every new I/O through the unit picker means the chain remains the single source of truth, and the existing 301 cognitive model scales to all the new I/O without modification.

## Multi-output unit handling

Some new units (Just Friends Geode, quadrature LFO, CV+gate pair, multichannel sequencer) produce coupled outputs that cannot be reconstructed downstream. These need a sub-view mechanism — see the multi-output units file for the full design.

## Controller integration

Physical faders, knobs, and buttons on the controller section appear as source units alongside other hardware inputs. No bind/learn step. See controller section file for details.

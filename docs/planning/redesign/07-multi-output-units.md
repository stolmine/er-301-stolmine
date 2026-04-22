# Multi-Output Units

**Status:** **shipped 2026-04-21** in stolmine (commits `7d99be1` framework, `a9cc47d` multiout package). Validated end-to-end: stolmine emu, stolmine hardware, vanilla firmware (graceful fallback to primary). Picker grammar revised April 2026 — Rolodex stack dropped in favor of edge-indicator overlay on the existing 1-ply scope + M6 sub-out cycler (see Local picker section). Author guide for downstream package authors lives in `er-301-habitat/docs/multi-output-units-author-guide.md`. Open follow-ups (none blocking): unit-picker fan-out glyph, unit-focused-view sub-out topology, optional stolmine→vanilla preset rewriter — see TODO.md.

## The problem

Some units produce multiple outputs that are semantically bound — a Just Friends Geode's taps, a quadrature LFO's four phases, a paired CV+gate envelope, a multichannel sequencer. These cannot be cleanly decomposed into parallel chains because the relationship between the outputs *is* the unit's contribution.

Other units have outputs that look multiple but are really independent and *should* decompose to parallel chains — e.g. a stereo-out effect could just as easily be two mono effects in parallel.

## The "derivable at destination" gating test

Whether a multi-output unit belongs in the library is decided by one question: **can the relationship between its outputs be reconstructed downstream?**

- **Phase offset between two oscillators.** Fails the test only superficially — a delay at the destination reconstructs phase relationship trivially. → decompose to parallel chains.
- **Quadrature LFO (four phases locked at 0°/90°/180°/270°).** Passes — reconstructing exact phase lock at the destination requires the same internal state. → multi-out unit.
- **Just Friends Geode (sympathetic taps).** Passes — the taps' relationship is the unit's whole point. → multi-out unit.
- **Paired CV+gate envelope.** Passes — gate timing is internal to the envelope's evolution. → multi-out unit.
- **Multichannel sequencer.** Passes — channels share a step pointer. → multi-out unit.

The unit author declares whether a unit is multi-out — not the user.

## Coupling principle (generalized)

**Coupling belongs to producers, never consumers.** Outputs can be declared semantically bound because the unit owns the shared internal state. Inputs are always independent subscription slots — binding two inputs from one source would assert a relationship the unit didn't produce.

In practical terms: the friction of subscribing two inputs separately from one source *is* the choice to couple them. Removing that friction removes the point — the modular paradigm collapses into MIDI's "everything is a number, route it where you like" mental model.

## UI grammar

### Chain view

A multi-out unit occupies a single chain position — its **primary output**. The primary output is author-declared and **not reassignable by the user**. Sub-outs **never** occupy chain positions.

The main chain view looks identical for single-output and multi-output units. No special icon clutters the primary read.

### Sub-out access

Sub-outs are reached **only** via deliberate subscription in the local input picker (scope view). To wire a sub-out somewhere downstream, the user opens the local picker on the consuming chain and finds the sub-out there.

### Local picker — edge indicator overlay

The local picker keeps its **vanilla layout intact**: chain overview occupies the leftmost ~5 plies, miniscope occupies the rightmost 1 ply. When a multi-out unit is focused, two small Labels (sub-out label on top, `X/Y` position on bottom) are overlaid on top of the scope's waveform. They're hidden when the focused source is single-out — vanilla scope layout is fully preserved for the common case.

### M6 — sub-out cycler

When a multi-out unit is focused, **M6 cycles through the unit's sub-outs** in author-declared order. M6 sits under the scope ply and was unbound in the picker, so this is free real estate with no muscle-memory collision. The indicator updates in step; the scope re-targets to whichever sub-out is currently selected so audition follows the cycle. The currently focused sub-out is what `enter` selects.

When the focused source is single-out, M6 is a no-op (matches vanilla picker behavior).

### Author labels

Sub-outs require **meaningful author labels**. Generic "out 1 / out 2" is not acceptable — the indicator overlay shows the label in-place, and "out 1" is uninformative there. Labels are declared by the unit author as `args.subOutLabels` passed into `Unit.init` (e.g. `args.subOutLabels = {"main", "aux", "cv", "gate"}`). Vanilla firmware ignores this field as an unknown args key — harmless.

Keep labels short (≤6 chars renders cleanly in the 42px ply at 10pt).

### Why not Rolodex?

An earlier iteration of this spec called for a Rolodex stack with edge-peek. Rejected for two reasons:
1. **Space.** The picker has limited real estate, especially in deeply nested chains. A 4–6 card stack would be too large for the available cell budget and not legibly different from a flat list.
2. **Display vs. selection conflated.** The Rolodex tried to do both discoverability and selection in one mechanism. Edge-indicator + M6 separates them: the indicator always shows the current state, M6 is the dedicated cycle action.

The "current sub-out only" approach is intentionally lossy in the surface (you can't see all sub-outs at once) — but progressive disclosure via M6 is fast and zero-clutter.

### Controls

A multi-out unit's controls live **only at the top level**, macro-style — they affect all sub-outs. There is no per-sub-out control depth, by design (it would multiply UI depth without earning anything).

## Sub-view motion grammar

The local-picker grammar above (M6 cycle + edge indicator overlay) handles sub-out *selection* without entering a separate navigational space. No sub-view "drill" is required for the picker case.

For the unit's own focused view (when the user is editing the multi-out unit, not picking it as a source elsewhere), surfacing sub-out topology is still desirable — see Discoverability below. Mechanism not committed; not blocking v1.

## Discoverability

The picker's edge indicator overlay is the discoverability mechanism in the local picker — the moment the user focuses a unit, the overlay either appears (multi-out, with `X/Y` showing fan-out count and label naming the current sub-out) or doesn't (single-out, scope renders normally). This conveys both *that* the unit is multi-out and *how many* sub-outs it has, without requiring a separate badge.

For unit-picker-time discoverability (when scrolling unit *types* before insertion), no glyph is currently shipped — the post-insertion edge overlay handles the common case. A small fan-out badge in the unit picker is a possible follow-on (TODO.md).

Surfacing sub-out topology in the unit's own focused view (when the user is editing the multi-out unit, not picking it as a source elsewhere) is still desirable but not committed; not blocking v1.

## Scope decision for v1

The sub-view mechanism does **not** need implementation for any currently-shipping 301 unit — the v1 audio library decomposes cleanly to parallel chains. The framework is a hook for control-domain expansion (Just Friends, quadrature LFO, multi-phase utilities).

**Original guidance (April 2026):** specify the UI grammar now so it's ready; do not build the implementation until a unit needs it; not a v1 blocker.

**Update (2026-04-21):** built ahead of demand to validate the design and lock the vanilla-compat story. Quad LFO ships in stolmine's `mods/multiout` package as the proving fixture. The v1 audio library is unaffected — multi-out is opt-in per unit, vanilla packages keep working unchanged.

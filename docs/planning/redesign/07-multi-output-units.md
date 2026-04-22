# Multi-Output Units

**Status:** principles and UI grammar specified. Implementation **deferred** — no v1 unit requires it. Picker grammar revised April 2026 — Rolodex stack dropped in favor of context-sensitive ply layout + S3 sub-out cycler (see Local picker section). Discoverability glyph still open in detail; sub-view motion deferred (no v1 unit needs a separate drill).

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

### Local picker — context-sensitive ply layout

The local picker keeps its existing main-display layout (chain overview + miniscope on the right), but reallocates space when a multi-out unit is focused:

- **Default (single-out focused):** miniscope occupies **3 plies** (126px) on the right edge of the main display. Chain overview takes the remaining ~130px on the left.
- **Multi-out focused:** miniscope shrinks to **2 plies** (84px). The freed rightmost ply (42px) shows a `[X/Y: label]` indicator for the currently selected sub-out — for example `[2/4: aux]` or `[3/4: cv]`. Chain overview width is unchanged between the two states; only the right-edge ply allocation toggles.

The transition is driven by the focused source's metadata — single decision point, two affordances (ply allocation + S3 binding visibility, see below).

### S3 — sub-out cycler

When a multi-out unit is focused, **S3 cycles through the unit's sub-outs** in author-declared order. The `[X/Y: label]` indicator updates in step. The currently focused sub-out is what `enter` selects.

When the focused source is single-out, S3 is unbound (current behavior preserved). No collision with main-chain muscle memory because S3 is currently free real estate in the picker.

### Author labels

Sub-outs require **meaningful author labels**. Generic "out 1 / out 2" is not acceptable — the rightmost-edge indicator shows the label in-place, and "out 1" is uninformative there. Labels are declared by the unit author as Lua-side metadata on the unit (e.g. `self.subOutLabels = {"main", "aux", "cv", "gate"}`).

### Why not Rolodex?

An earlier iteration of this spec called for a Rolodex stack with edge-peek. Rejected for two reasons:
1. **Space.** The picker has limited real estate, especially in deeply nested chains. A 4–6 card stack would be too large for the available cell budget and not legibly different from a flat list.
2. **Display vs. selection conflated.** The Rolodex tried to do both discoverability and selection in one mechanism. Edge-indicator + S3 separates them: the indicator always shows the current state, S3 is the dedicated cycle action.

The "current sub-out only" approach is intentionally lossy in the surface (you can't see all sub-outs at once) — but progressive disclosure via S3 is fast and zero-clutter, and the discoverability glyph (below) communicates fan-out count without showing every label.

### Controls

A multi-out unit's controls live **only at the top level**, macro-style — they affect all sub-outs. There is no per-sub-out control depth, by design (it would multiply UI depth without earning anything).

## Sub-view motion grammar

The local-picker grammar above (S3 cycle + edge indicator) handles sub-out *selection* without entering a separate navigational space. No sub-view "drill" is required for the picker case.

For the unit's own focused view (when the user is editing the multi-out unit, not picking it as a source elsewhere), surfacing sub-out topology is still desirable — see Discoverability below. Mechanism not committed; not blocking v1.

## Discoverability

Hiding sub-out details on the picker's edge indicator means the user can see *which* sub-out is currently selected but not at-a-glance how many a unit has, or what they all are. Two complementary affordances:

1. **Micro-indicator glyph** on multi-out units in the chain overview, showing fan-out count (e.g. small badge "×4"). Peripheral-readable, no interaction required. Visible always — distinct from the picker's `[X/Y: label]` which only appears when focused.
2. **Surface sub-out topology in the unit's focused view** (not the chain view), consistent with sub-chain detail depth.

Both are cheap. Probably ship both. The chain-overview glyph is the more important of the two — it's the cue that S3 will do something when you focus this unit in the picker.

## Scope decision for v1

The sub-view mechanism probably **does not need implementation for any currently-shipping 301 unit** — the v1 audio library decomposes cleanly to parallel chains. The framework is a hook for control-domain expansion (Just Friends, quadrature LFO, multi-phase utilities).

**Specify the UI grammar now so it's ready. Do not build the implementation until a unit needs it. Not a v1 blocker.**

# Multi-Output Units

**Status:** principles and UI grammar specified. Implementation **deferred** — no v1 unit requires it. Open items on discoverability and exact motion control.

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

### Local picker — Rolodex stack

The local picker uses a **Rolodex stack with offset visual** — a 2–3px peek of adjacent cards leaks at the edge, signalling depth without clutter (Tufte edge-peek). Two stack behaviors live in the same picker:

- **Unit-level stack** (top): orders by **LRU / recency**. Most recently used units near the top.
- **Within-unit sub-out stack** (when a multi-out unit is focused): orders by **author-declared order**, *not* recency. Phase 0°/90°/180°/270° is a semantic sibling relationship — recency-ordering it would scramble that meaning.

Sub-outs require **meaningful author labels**. Generic "out 1 / out 2" is not acceptable — the Rolodex stack makes the label the only disambiguator.

### Controls

A multi-out unit's controls live **only at the top level**, macro-style — they affect all sub-outs. There is no per-sub-out control depth, by design (it would multiply UI depth without earning anything).

## Sub-view motion grammar

**Open — direction set, exact mechanics TBD:**

- **Axis-distinct motion:** main chain navigation is horizontal; sub-view enters with a different axis (lift/drop) and different easing. Different kinesthetic trains peripheral awareness — the user can feel which space they're in without looking.
- **Entry/exit ritual:** long-press, or a dedicated soft key, with a visible commit. Breadcrumb appears: `[unit] · sub 2/3`.
- **Critical:** the sub-nav control must be *mechanically distinct* from main-chain nav. If they share a control, muscle memory fails mid-set — the worst possible failure mode for this audience.

Exact control assignment is not yet committed.

## Discoverability

**Open.** Hiding sub-outs in the local picker creates a discoverability cost — the user must already know a unit has them. Current lean:

1. **Micro-indicator glyph** on multi-out units in chain view, showing fan-out count. Peripheral-readable, no interaction required.
2. **Surface sub-out topology in the unit's focused view** (not the chain view), consistent with sub-chain detail depth.

Both are cheap. Probably ship both. Not yet committed.

## Scope decision for v1

The sub-view mechanism probably **does not need implementation for any currently-shipping 301 unit** — the v1 audio library decomposes cleanly to parallel chains. The framework is a hook for control-domain expansion (Just Friends, quadrature LFO, multi-phase utilities).

**Specify the UI grammar now so it's ready. Do not build the implementation until a unit needs it. Not a v1 blocker.**

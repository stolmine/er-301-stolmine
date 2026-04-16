# Feasibility Note: Recording Locals via Multitrack Recorder

## Context
The multitrack recorder (FileRecorder) currently lets each track's source come from **Jacks** (hardware I/O) or **Globals** (global chain outputs). A "Locals" tab exists in the shared `Source.Chooser` but is disabled in the recorder. This note evaluates whether it's feasible to let the recorder tap **unit outputs, branch outputs, and patch monitoring outputs from within a chain** — i.e., the same things `LocalChooser` already exposes elsewhere in the app.

## Verdict
**Feasible, with essentially zero engine-level work.** All DSP plumbing, source abstractions, and chooser UI already exist. The single reason the recorder doesn't offer locals today is that the FileRecorder instantiates `SourceChooser` without a chain argument, which gates off the Locals tab.

## Evidence

### What already works
- `Source.Chooser` supports three tabs: Jacks, Locals, Globals (`xroot/Source/Chooser.lua:22-42`).
- `Source.LocalChooser` already builds a `ChainOverview` that navigates chains → units → branches → patches depth-first and watches the selected outlet on a scope (`xroot/Source/LocalChooser.lua:98-132, 191-210`).
- `LocalChooser:enterReleased()` returns a proper source object whose `getOutlet()` yields a live `Outlet*` (`xroot/Source/LocalChooser.lua:141-157`).
- The recorder already connects any selected source's outlet to a `MonoFileSink`/`StereoFileSink` inlet via `app.connect(config.source:getOutlet(), sink:getInput(...))` (`xroot/FileRecorder/init.lua:113, 117, 125`). The connection path does not care whether the outlet is external or internal.
- Every `Unit`, `Branch`, `Patch`, and chain input source exposes an `Outlet` via the standard `getOutput(channel)` / `getOutlet()` accessors; the audio graph is a DAG of `Outlet*`↔`Inlet*` edges. No new primitives are required.

### Why it's disabled today
- `Source.Chooser:init` only paints the "Locals" panel label if a `chain` was passed (`xroot/Source/Chooser.lua:25-29`).
- `Source.Chooser:setChooser` explicitly blocks tab index 2 when `self.chain == nil` (`xroot/Source/Chooser.lua:142-144`).
- The FileRecorder creates the chooser as `SourceChooser()` — no chain — in two places:
  - `xroot/FileRecorder/init.lua:533`
  - `xroot/FileRecorder/ChannelControl.lua:77`
- The only other caller, `xroot/Chain/InputControl.lua:53`, passes the current chain and therefore gets the Locals tab working already. That call site is a working reference implementation.

### Design decision (user-confirmed)
The FileRecorder is a modal, app-level tool with no implicit current chain, so the implementation must supply one. The chosen approach:

1. **Initial entry point = the currently-focused chain at the moment the source picker opens.** Read whatever chain the user is viewing (main view / scope view focus) and pass it to `SourceChooser(chain, currentSource)`. `LocalChooser` normalises to `chain:getRootChain()` internally, so any chain in the hierarchy is a valid seed.
2. **While the Locals tab is open, the chain buttons re-focus the Locals tab's root chain live.** Pressing a chain button implicitly re-seats `LocalChooser` on that chain (analogous to how chain buttons switch focus in the main view) without leaving the picker. This means the user is not locked into the chain they happened to be viewing when the recorder opened — they can walk across chains from inside the picker.
   - Implementation hook: `LocalChooser` needs a method to rebuild its `ChainOverview` against a new root chain (tear down `self.nodes`, rebuild via `loadChainHelper`, reselect), plus a button handler that calls it. The event source for "chain button pressed" is whatever the main app uses for chain switching — likely a `Signal` already emitted globally.
   - Alternative considered and rejected: a chain picker inside the Locals tab (global chains + main OUT chains). Too much extra UI; chain-button re-focus is the natural gesture on this hardware.

## Critical Files (for the eventual implementation)
- `xroot/FileRecorder/init.lua:533` — create `SourceChooser` with a chain.
- `xroot/FileRecorder/ChannelControl.lua:77` — same, from the per-channel spot entry point.
- `xroot/Source/Chooser.lua:9, 25-29, 142-144` — unchanged; already gates correctly on `chain`.
- `xroot/Source/LocalChooser.lua` — unchanged for initial entry; needs a small `reseed(chain)` method + chain-button signal hook for live re-focus.
- `xroot/Chain/InputControl.lua:51-55` — reference call site that already passes a chain.

Entry-point discovery helpers to look at when implementing:
- `app.Application` / `root` window's current main-view chain accessor (how the scope view knows what to display).
- `Chain:getRootChain()` (already used by LocalChooser).
- `Chain:getXPathToSelection()` (LocalChooser uses this to restore selection state).
- Chain-button event source: grep for the signal emitted when the hardware chain buttons switch focus in the main view, and subscribe from `LocalChooser` while it is the active chooser panel.

## Verification Plan (once implemented)
1. Build emulator: `make emu`.
2. Open a patch in the main view with at least two units on the left channel chain; position the scope/cursor on one of those units.
3. Open the multitrack recorder; on a track's source assignment, verify the "Locals" panel label now renders and is selectable.
4. Select a local source (e.g., the output of a mid-chain unit); confirm `LocalChooser` shows the ChainOverview and the scope thumbnail of the selected outlet.
5. While the Locals tab is open, press a chain button to switch to another chain; confirm the ChainOverview re-roots to that chain and the scope thumbnail follows.
6. Start recording with one track assigned to a local source and one to a jack; stop; save the audio; verify both WAV files on disk contain the expected signals (mid-chain unit's output vs. hardware jack).
7. Regression: confirm Jacks and Globals tabs still work and that recordings with those sources are unchanged.
8. Edge cases to probe: tapping a patch monitoring output, tapping a stereo chain's left vs. right side via `Channels.getSide()`, and opening the recorder with no chain selected (the "Locals" tab should be gracefully absent, matching today's behavior).

## Summary
Nothing in the DSP, file-sink, or source-abstraction layers blocks this. The work is a small amount of Lua wiring: (a) pass the currently-focused chain as the initial entry point into `SourceChooser` from the recorder, and (b) add a live re-focus hook in `LocalChooser` so chain-button presses re-root its ChainOverview. Implementation and verification are both low-risk.

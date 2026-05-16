# TODO

## Favorites System in Unit Picker
Shift toggles favorites editing mode while browsing units by category. Sub-display shows three controls:
- **S1: Tag/untag** — toggle the currently highlighted unit as a favorite
- **S2: Clear all** — clear all favorites, guarded behind a confirmation dialog (with confirmation guard toggle in system settings confirmations section)
- **S3: Sort** — cycle favorites display order: recents, alphabetical, category

Favorites appear as their own category in the unit picker, below Recents and above Essentials. System settings toggle to show/hide the favorites category entirely.

Favorites persist across sessions (serialize alongside Recents in quicksave data).

## v0.6.16 Port
Port TXo I2C master mod to v0.6.16 stable firmware base. v0.7 breaks compatibility with all third-party packages (lojik, strike, sloop, polygon, etc.).

## Screensaver Polish
- Forest screensaver: full-screen coverage
- Rain screensaver: splash particles

## Slot Machine Text Input
Alternate text entry method using the 6 main buttons as column selectors:
- Display 6 character columns on screen, each aligned under M1-M6
- **Hold** a button to focus its column — encoder scrolls through symbols in that column
- **Release** to enter the selected character at the cursor position
- Cursor advances automatically after entry
- Sub-display unchanged from existing keyboard: S1 bksp, S2 cursor, S3 space
- Symbol set per column: A-Z, a-z, 0-9, common punctuation (-, _, ., /)

Advantages over single-cursor keyboard: up to 6 characters visible and selectable at once, no lateral cursor movement needed for sequential entry, encoder travel per character is minimal since columns can show contextual/frequent symbols.

## Intro Video
Produce a short video introducing stolmine firmware. See [video.md](video.md) for script outline.

## Crash Report: sc.cv insert at end of chain
Investigate crash with the following repro characteristics:
- Latest firmware release version
- Chain containing mutable units from habitats package
- TXo and Teletype packages enabled
- Crash triggered when inserting an `sc.cv` unit at the end of the chain

Collect: crashdump from device, exact unit list + order, whether link/unlink
state matters, whether removing TXo or Teletype changes reproducibility.

## Chain-Reference Invalidation on Stereo Link/Unlink (pre-v9.1.0)
Stereo link/unlink in user mode destroys and recreates chain objects, but only
`UserMode` subscribes to `channelsModified`. `LocalChooser` (and its wrapper
`Source/Chooser`) hold chain references that can dangle across a link/unlink.
Main channel view + `OUTX: No units` readout are fine — those rebuild via
`Channels.show()`. Fix: apply the stock `Signal.weakRegister` pattern
(as in `Source/Chooser.lua:41`, `GlobalChains/Interface.lua:315-317`, etc.) to
`LocalChooser` and `Source/Chooser`, with reseed-or-dismiss semantics.
See [docs/planning/chain_invalidation_on_link_unlink.md](docs/planning/chain_invalidation_on_link_unlink.md).

## Multi-Output Unit Framework — Follow-Ups
Framework shipped 2026-04-21 (commits `7d99be1` framework + `a9cc47d` multiout
package). Validated end-to-end on stolmine emu, stolmine hardware, and vanilla
firmware (graceful fallback to primary). Author guide in
`er-301-habitat/docs/multi-output-units-author-guide.md`.

Outstanding items, none blocking:

- **Stolmine→vanilla preset rewriter (optional).** Today, a stolmine preset
  wiring sub-out ≥3 of a multi-out unit drops that connection silently when
  loaded on vanilla. A stolmine-side save-time rewriter could snap any sub-out
  index >2 to 1 (primary) so cross-firmware presets degrade losslessly to
  stereo on vanilla. Only worth building if cross-firmware presets become a
  real workflow.
- **Discoverability glyph in unit picker.** When scrolling unit *types* before
  insertion, show a small fan-out count next to multi-out units. Pure Lua
  addition under `xroot/Unit/Chooser/`. Not blocking; the local-picker edge
  indicator already handles post-insertion discoverability.
- **Sub-out topology surfacing in unit's focused view.** When the user has the
  multi-out unit selected as the focused chain unit (not as a source), surface
  the sub-out list somewhere. Mechanism not committed; not blocking v1.
- **Hardware sinf/cosf LUT audit.** QuadLFO ships with scalar `sinf`. User
  reports it works correctly on hardware despite the known package trig bug,
  but a LUT swap is the documented mitigation for any future multi-out unit
  whose audio path shows the symptom.

## Stolmine Core Package (Multi-Output Core Units)
Ship a stolmine-branded Core package that replaces vanilla Core as the
default install on stolmine firmware, and bundle vanilla Core alongside
(built into the firmware zip but not auto-installed). Users who want the
original Core behavior or a lower CPU baseline can install vanilla Core
manually from the package manager. Purpose: bring multi-output capability
to core units that would naturally benefit from it (filters with
simultaneous LP/BP/HP outs, envelopes with EOC/inverted companions, clocks
with pre-divided taps, ladder filters in multi-mode, stereo samplers exposing
L/R/sum, LFOs as quad-phase, etc.).

Design goals:

- **Stolmine Core installs by default; vanilla Core ships but does not.**
  The firmware build produces both packages. Stolmine Core is the one the
  firmware installer activates on a fresh install or upgrade; vanilla Core
  lives in the package staging area (same place third-party packages do) so
  the user can opt into it via the package manager if they prefer. Decide
  the collision story: running both simultaneously means identical unit
  type IDs exist in both, so stolmine Core probably needs a distinct package
  ID / namespace (`core2.*` or similar) to let both load without the picker
  showing duplicates. Alternative: stolmine Core reuses `core.*` IDs and is
  mutually exclusive with vanilla Core — installer enforces that only one
  is enabled at a time. Pick one before implementation.
- **Multi-out where it earns its keep, not everywhere.** Audit candidate
  units individually — some gain real composability from fan-out (ladder,
  SVF, env, LFO, clock divider), others don't (gain, sum, mixer). Ship the
  fan-out on the subset that justifies it.
- **Opt-in sub-out compute.** CPU inflation is the key tradeoff. Where sub-
  outs compute into buffers that downstream chains may not read, wire up a
  connected-check so inactive sub-outs short-circuit. Stay deterministic —
  no dynamic allocation during audio — but skip the math when the outlet has
  no consumer. Matches the vanilla pattern for `Outlet::connected()`.
- **Author convention:** each stolmine-core unit declares `subOutLabels` and
  respects out-of-range-to-primary fallback so its preset files degrade on
  vanilla Core if a user swaps packages.
- **Preset portability:** document whether presets built on one core pack
  migrate to the other. At minimum, sub-out indices ≥2 snap to primary on
  vanilla-core load (same story as the existing multi-out framework).

Open questions (resolve before coding):

- Namespace strategy (package ID vs category tag vs suffix-in-name).
- Which core units get the fan-out treatment in v1 vs later.
- Whether to fork `mods/core/` in-tree or start fresh under `mods/stolmine-
  core/` importing the DSP objects by reference.
- Installer UX — is this default-installed alongside vanilla, or a toggle in
  the package manager?

Dependencies: multi-output framework is shipped (7d99be1). No C++ ABI work
expected — all fan-out affordances already live in Lua + LocalChooser.

## Chain UI: Replace Picker Opens in Favorites-Tagging Mode (pre-release fix)
Two related issues with the unit picker invoked from the chain UI's
**replace** facility. Fix both before next release.

1. **Replace lands in tagging mode instead of normal picker.** When
   the user invokes "replace" on an existing unit (currently it's
   shift+ENTER on the unit, then the picker is presented to choose
   the replacement), the picker comes up already in favorites-tagging
   mode -- shift-state appears to be sticky / carried through from
   the gesture that invoked replace. Should land in the normal
   browse mode; tagging is a separate operation gated by holding
   shift inside the picker, not on entry.
   Likely cause: the entry path through `xroot/Chain/ChainView.lua`
   (or similar) into the picker passes a state flag (or leaves the
   shift-pressed state observable to the picker on construction),
   and the picker honors it for the initial mode. Path to walk:
   `xroot/Unit/Browser/init.lua` or `xroot/UnitPicker/init.lua` ctor
   + the replace entry-point in chain view.

2. **Exiting favorites-tagging mode feels sluggish vs. entering.**
   Press shift -> instant tagging mode swap. Release shift -> there's
   a perceptible lag before the picker reverts to browse mode. Either
   the release handler is debounced harder than the press, or the
   picker is doing extra refresh work on the exit path (re-filtering
   the unit list, re-sorting recents, redraw of the full grid) that
   the entry path doesn't do.
   Worth a frame-time trace through `shiftReleased` in the picker
   view vs. `shiftPressed` to see what's asymmetric.

Both are quality-of-life bugs, neither blocks anything, but
they're cumulatively annoying enough that they belong on the
pre-release-fix list.

## Encoder Capture Under UI Saturation
In certain states the system reaches CPU saturation and encoder input becomes
effectively unresponsive — encoder movement is still *queued*, but so far
behind the event loop's schedule that the device is practically
uninteractable. The user either waits for the backlog to drain (seconds of
ghost motion) or power-cycles. Worst offenders tend to be complex Lua views,
heavy redraw paths, and interactions during transitions.

**Root cause observation:** only the audio thread's CPU is tracked. The UI
thread has no budget accounting, no watchdog, no degradation path. When UI
work exceeds its frame budget, events pile up unbounded while the render
loop continues servicing a stale backlog at full fidelity.

**Design investigation required** — this is not a spot fix. Candidate
approaches, any or all:

- **UI-thread budget instrumentation.** Analogous to `od::extras::Profiler`
  on the audio side: measure per-frame UI time, expose a readout, and surface
  saturation events in the log. Can't fix what isn't measured.
- **Input event aging / coalescing.** If an encoder event is older than some
  threshold (e.g. 100 ms), drop it or coalesce rapid successive events into
  one accumulated delta. User gets responsiveness back at the cost of
  fidelity during overload. Coalescing is probably always-on; aging kicks in
  under saturation.
- **Render-skip / frame-drop circuit breaker.** When the UI frame budget is
  blown for N consecutive frames, degrade: skip non-essential redraws, pause
  animations, render only the focused region. Restore full fidelity once
  budget is healthy again. Analogous to how game engines drop graphics
  fidelity under load to preserve input responsiveness.
- **Input fast-path that bypasses render.** Sample the encoder and apply its
  effect to parameter state on a tighter loop than the full UI render. The
  screen catches up when it can, but the underlying value change lands
  immediately. Requires careful separation of "what the value is" from "what
  the screen shows" — currently the two are often coupled in Lua view code.
- **Priority inversion on event drain.** When the event queue is over a
  threshold, drain it before rendering anything at all. Prevents the
  encoder-lag spiral where rendering the stale state delays reading the
  next event, which delays the render after that, compounding.

The architectural goal is: **under UI saturation, encoder should feel
sluggish but trackable — not captured.** Movement should always reach the
underlying parameter value within hundreds of milliseconds even if the
display is a frame or two behind.

First step before any fix: instrument the UI thread so we can characterize
*which* states cause saturation and how badly. Without that we're guessing
about what the circuit breaker should trigger on.

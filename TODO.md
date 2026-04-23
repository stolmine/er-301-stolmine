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

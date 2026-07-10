# TODO

## Status: stolmine fork on AM335x is feature-complete (2026-06-09, v0.7.0-stolmine.9.5.0)

The ER-301 stolmine fork on AM335x hardware is feature-complete as of the
**9.5.0** release. All forward firmware development moves to a
next-generation hardware platform tracked privately.

The items below are kept for posterity. Most will not be revisited on
AM335x; a small number have already shipped silently in the 9.2.1 /
9.4.x polish cycles but were not pruned from this list at the time. If
the fork ever takes one more pass, this list is the menu.

Items already shipped (would have been the next pass otherwise):

- Chain UI replace picker favorites-mode bug (9.2.1)
- Sequencer BPM latch exit gestures + onHide release (9.4.0.16)
- Sequencer mark mode vs edit mode collision (modal sweep, 9.4.x)
- TXo top-level passthrough toggle (9.2.1)
- Sequencer ext-clock phase 6.6 persistence (2026-06-08)
- Sequencer modal sweep follow-ups F4 / D1 / H6 / H8 (9.4.0.29)
- Sequencer terminal-edit + encoder coarse/fine LEDs (9.4.0.35)

Everything below is preserved as-of-2026-06-09 design intent. Some of
it overlaps with what's planned for the CM4 platform; refer back here
only if the AM335x fork ever needs another cycle.

---

## Favorites System in Unit Picker
Shift toggles favorites editing mode while browsing units by category. Sub-display shows three controls:
- **S1: Tag/untag** — toggle the currently highlighted unit as a favorite
- **S2: Clear all** — clear all favorites, guarded behind a confirmation dialog (with confirmation guard toggle in system settings confirmations section)
- **S3: Sort** — cycle favorites display order: recents, alphabetical, category

Favorites appear as their own category in the unit picker, below Recents and above Essentials. System settings toggle to show/hide the favorites category entirely.

Favorites persist across sessions (serialize alongside Recents in quicksave data).

## v0.6.16 Port
Port TXo I2C master mod to v0.6.16 stable firmware base. v0.7 breaks compatibility with all third-party packages (lojik, strike, sloop, polygon, etc.).

## Unit Picker Readability + Editability
Current picker (`xroot/Unit/Chooser/Default.lua` + `MondrianMenu`)
presents units as a flat scrolling list of similarly-styled rounded
rectangles. Differentiation is text-only, parsing is slow, and the
M keys are consumed by box-intersection picking, which forecloses
richer in-picker actions (sort, filter, hide). Cheap wins (type
glyphs, recency intensity) are worth doing standalone; the bigger
prize is a dense alternative layout, **selectable from the admin
menu** so it coexists with the classic Mondrian view.

### Cheap wins (no layout change, can ship alone)
- **Type glyphs.** One-character prefix on each row encoding unit
  family: `~` source, `>` processor, `$` modulator, `.` utility,
  `?` random. Pure `loadInfo.title` munging, zero new graphics
  primitives. Single biggest effort/payoff item.
- **Recency intensity.** Recently-used units render full-white,
  untouched-in-30-days render mid-gray. Reuses the existing
  recents table + `setBorderColor`.
- **Sub-display preview pane.** Replace the static help text with
  live info on the focused unit: 1-line description, I/O fan,
  CPU class, last-used time.

### Dense alternative view (the test-drive target)
Replace the Mondrian rectangle grid with a Tufte-style table laid
out as **2 dense columns + an alphabet jump bar + M-key actions**.
ASCII mock (256 x 64 main, 128 x 64 sub):

```
+-----------------------------------------------------+
|A B C D E F G H I J K L M[N]O P Q R S T U V W X Y Z  |  alphabet ribbon
|                                                     |  [] = encoder snap on shift+turn
|    ~ sine          ::: |   $ env-ar        :...     |
|  *[> filter]       ::. | [$ env-adsr]     :::..     |  * = row cursor
|    > vca           ::. |   . slew          ....     |  []   = live cells on row
|    > compressor    :.  |   ? rand         :::::     |  trailing ::. = recency sparkline
|                                                     |
| [pickL]  [sort]  [type]  [pickR]  [hide]  [fav]     |
+-----------------------------------------------------+
   ^M1     ^M2     ^M3     ^M4      ^M5     ^M6
```

After tapping M3 (type-filter, cycled to `~ source`):

```
+-----------------------------------------------------+
|A B C D E F G H I J K L M N O P[Q]R S T U V W X Y Z  |
|                                                     |
|    ~ noise         :::. |   ~ saw           ..      |
|  *[~ quad-osc]     :::: | [~ sine]         :::::    |
|    ~ ramp           .   |   ~ square        .       |
|    ~ s&h-osc        :.  |   ~ sub-osc      :::.     |
|                                                     |
| [pickL]  [sort]  <TYPE:~>  [pickR]  [hide]  [fav]   |
+-----------------------------------------------------+
```

Dim ribbon letters mark "no match." Angle brackets on the M3 chip
signal "filter active." Sub display surfaces filter state so the
user never wonders why the inventory shrank.

### Gestures
- Encoder: move row cursor up/down (advances both cells together).
- Shift + encoder: jump to next matching ribbon letter.
- **M1 / M4**: pick / insert the left / right cell on the focused row.
- **M2**: cycle sort order (see below).
- **M3**: cycle type-filter (off / ~ / > / $ / . / ?).
- **M5**: hidden-units visibility toggle (and shift+M5 in edit
  mode hides the focused cell).
- **M6**: toggle favorite on focused cell (shift cycles L vs R).
- ENTER: same as M1 (left pick), for one-handed continuity.

### Sort modes (the heavy lifter)
M2 cycles the sort key. The dense layout collapses the package
chrome the Mondrian view gave for free, so the sort key has to
restore equivalent organization when the user wants it. Unit
keywords already exist in `loadInfo` and should drive most of these:

1. **Recents** (default) -- most-recently-used first, then alpha.
2. **Alpha** -- pure A-Z, ribbon letter snapping is exact.
3. **Type** -- group by leading glyph (~ > $ . ?), then alpha
   within group. Mini section dividers between type blocks.
4. **Package** (classic) -- group by `loadInfo.libraryName`, then
   alpha. Section dividers reproduce the original Mondrian
   category headers. This is the "restore what we collapsed"
   mode and should be available for any user who prefers the
   classic browsing model inside the new dense layout.
5. **Keyword** -- group by primary `loadInfo.keywords[1]` (e.g.
   "stereo", "envelope", "delay"). Keywords are already attached
   to most units and are richer than libraryName. Pivot point:
   the same unit can appear under multiple keyword groups, or
   only its primary -- decide before shipping.
6. **Favorites-first** -- favorited units at top, rest below in
   the secondary sort (recents / alpha).
7. **I/O fan** -- sort by input/output count. Useful when filling
   a specific socket ("I need a 1-in / 1-out").

Each mode shows its name in the M2 chip when active. Cycle order
configurable in admin so users can skip modes they don't use.

### Admin menu (the togglable axis)
A new admin section "Unit Picker" with:
- **Style**: `Classic (Mondrian)` / `Dense (2-col table)`.
  Per-user preference, persisted alongside `favorites.lua` as
  `picker_prefs.lua`. Default = Classic so existing users see no
  change; new users get Dense.
- **Sort cycle order**: checkbox list of which sort modes to
  include in the M2 cycle, in what order. Default: Recents,
  Alpha, Type, Package, Keyword, Favorites-first. I/O fan
  off-by-default since it's a power-user mode.
- **Type-filter cycle order**: same idea for M3 (`~ > $ . ?`).
- **Hidden units**: list of unit titles currently hidden, with
  per-row restore. Hide state persists in `hidden.lua`.
- **Show row sparklines**: on/off. Recency sparkline adds visual
  noise; users who don't care can suppress it for cleaner rows.

### Implementation order
1. Cheap wins (type glyphs + recency intensity + sub preview)
   inside the existing Mondrian view. Ships standalone.
2. Build the dense view as a parallel implementation behind an
   admin toggle. Default off. Test-drive it against the classic
   view on real picker tasks ("find sc.cv among the core units").
3. If dense wins, promote it to default for fresh installs;
   keep classic available indefinitely for users who prefer it.

### Tufte angle (for the dense view specifically)
The Tufte table chapter ("Visual Display" Ch. 6) and the
sparklines in "Beautiful Evidence" map directly: each row carries
3 visible bits (type glyph, name, recency sparkline) instead of
one (text-in-rectangle), and the chrome that signified nothing
in the Mondrian view (uniform borders, padding, rounded corners)
becomes ink the eye spends parsing real data. The 2-column dense
layout is plain prior art from Norton Commander / zsh tab
completion / NetHack inventory; the alphabet jump bar is iPhone
contacts / Cirklon pattern selection. None of these are novel
individually -- the bet is that combining them with sort-as-
primary-organizer fixes scan time on a 200+ unit inventory.

### Out of scope for v1
- Drag-reorder within a category (no good gesture).
- Fuzzy text search (gated on the Slot Machine Text Input entry).
- Stolmine→vanilla preset rewriter for picker prefs (prefs are
  per-install, no preset rewrite needed).

## Core Package Keyword + Type Revamp
The dense picker's type-glyph dispatch and the sort-by-keyword
mode both consume `loadInfo.keywords` from each package's `toc.lua`.
Coverage of the core package is uneven (some units are tagged with
2 keywords, others none) and the existing keyword set predates the
6-class type taxonomy (~ source / > effect / $ modulate / * timing
/ . utility / ? unknown).

Tasks:
- **Add `sampling` as a first-class type** (7th glyph). Today
  sampling-related units fall under `>` effect (because their first
  keyword is usually "effect, sampling" or "sampling, effect"), but
  sampling is a distinct conceptual class: file/sample-based units
  with their own performance profile (disk I/O, RAM buffers, slice
  state). Pick a glyph (`%` candidate; visually distinct, not used
  elsewhere) and add to xroot/Unit/Chooser/Glyph.lua's cycleOrder +
  kClassLabel + kKeywordToGlyph mapping.
- **Audit every core unit's keywords** for consistency. Make sure
  the FIRST keyword reflects the primary type for the glyph
  dispatch. Drop redundant keywords. Standardize on the canonical
  forms (`modulate` not `modulation`, `cv` not `CV`, `oscillator`
  not `generator`). Edit `mods/core/assets/toc.lua`.
- **Backfill missing keywords** on units currently rendering as
  `?` unknown.
- **Apply to all in-house packages** (multiout, txo, teletype) for
  consistency.

Out of scope: editing third-party packages (mi, biome, kryos, etc.)
since those have their own release cadences. Authors of those
packages can normalize on their own schedule; the dispatch table
in `Glyph.lua` already accepts the variants they currently use.

## Hold-Mode Scenes
Consolidated tracker lives at
[docs/planning/hold-mode-scenes-todos.md](docs/planning/hold-mode-scenes-todos.md).
Open work and the shipped log both live there; do not duplicate
entries in this file.

## Settings Menu: Picker + Scene Mode Categorization
`xroot/Settings/Interface.lua` currently lumps every unit-picker
setting under the catch-all "Units" category alongside unrelated
entries (`unitDisableOnBypass`, `unitControlReadoutSource`,
`unitBrowserDefault`, `containerUnitNameGen`). The result: picker
prefs that only apply to one of the two layouts (dense vs Mondrian)
are indistinguishable from prefs that apply to both, and the
single `sceneMode` toggle has no home of its own.

Tasks:

- **New "Unit Picker" category** between "Units" and "QuickSaves".
  Move into it: `showFavorites`, `pickerStyle`,
  `pickerSectionDividers`, `pickerDefaultSort`, `pickerPinFavorites`,
  `pickerPinRecents`.
- **Mark layout-specific entries** in the description text so the
  user knows which apply when. The dense picker has the type
  glyphs, sort cycle, section dividers, pin behavior. The Mondrian
  (OG) picker has the favorites toggle and not much else.
  - `pickerStyle`: both (it IS the layout switch).
  - `showFavorites`: both.
  - `pickerDefaultSort`, `pickerSectionDividers`, `pickerPinFavorites`,
    `pickerPinRecents`: dense-only. Append `(dense)` to the
    description text.
- Long-term: gray-out / hide dense-only entries when
  `pickerStyle == "classic"` (Mondrian), and the reverse if any
  classic-only setting ever materializes. Skip for v1 if it
  requires `Settings.Interface` refactoring; the description
  suffix is enough signal for now.
- **New "Scenes" category** containing `sceneMode`. Even with one
  entry, putting it in its own section keeps the menu navigable
  as scene mode accumulates settings (`confirmSceneDelete` already
  lives under Confirmations; future v1.1 entries -- skip-include
  mask, default A/B selector mode, etc. -- will land here).

Touch points: `xroot/Settings/Interface.lua` (menuItems table) and
the per-variable `description` strings in `xroot/Settings/init.lua`
for the `(dense)` suffixing. Variable definitions stay put; only
the menu category placement and descriptions change.

Out of scope: no functional change to any existing setting. This
is pure menu reorganization plus description suffixes.

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

## Audio Editor: Selection-Scoped Operations (idea, 2026-06-13)

The sample editor today is geared mostly toward slicing. The rudiments
for a more featured destructive editor are already in place: a
shift+scroll selection mechanic that scopes any subsequent action to
the highlighted range.

Idea: layer Audacity/Audition-style operations on top of the existing
selection convention. When nothing is selected, an action operates on
the whole sample. When a selection is active, the same action operates
only on the range. Same button, two scopes, same code path with a
"start/end" pair the action consumes.

Candidate actions (per crumb dinger, WIGL):

- **Copy / Cut / Paste** between samples in the pool (cross-sample
  paste is the interesting bit; needs a sample-side clipboard or a
  shared scratch buffer)
- **Reverse** in place
- **Gain** as a multiply with a one-knob amount picker
- **Pitch / time stretch** (granular or PSOLA; complex enough to gate
  behind its own design pass)

Sub-bar would dispatch via the M-keys with contextually-relevant
labels: nothing selected = global operations, selection active =
range operations. The visual mode switch is already familiar from the
sequencer's selection-active sub-bar swap.

Out of scope for the idea phase:

- Undo/redo (large): destructive edits in a 0.7-era engine need
  either an undo journal or a separate "edit buffer" the user
  commits from. Both are real surface area; pick before building.
- Non-destructive edit layer: probably the right model long-term,
  but it changes the sample pool semantics meaningfully. Out of
  scope for a first pass.
- Loop region authoring: distinct enough from edit-region selection
  that it should stay where it is.

Conversation reference: 2026-06-13 design discussion. The
existing slicing focus stays; this adds a layer rather than replacing
it.

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

## Bug Report: Stereo Mix Output Drops on Quicksave Load (pre-v9.1.0)

User-reported bug, 2026-06-15. Reproduces on both stolmine **and**
vanilla v0.7.0, so it lives upstream (not a stolmine regression). The
quicksave persists the broken state; rebuilding the chain manually
fixes it on both firmwares.

**Setup:**
- One stereo (linked) channel.
- Stereo Mix unit with both inputs occupied (some audio source going
  into both L and R, e.g. `/home/bram/Downloads/plumbutter.mp3` for
  the user's bench).
- Mono Mix unit following the stereo mix, no inputs, intended as a
  passthrough.

**Symptom:**
- Audio cuts out at the stereo mix's outputs. Scope on the stereo
  mix output reads silent.
- Input to the stereo mix's subchain visualizes correctly (signal is
  arriving at the subchain inputs).
- Mono mix downstream also passes silence (consistent with its input
  being the now-silent stereo mix output).
- Quicksave + reload does NOT fix it. The broken state persists.
- Loading the same quicksave on vanilla v0.7.0 reproduces the same
  failure.
- Deleting both units and rebuilding the chain manually fixes it on
  both firmwares.

**Likely shape:**
- An internal state on the stereo mix unit (or its sub-chain) gets
  into a wedged configuration that serialize/deserialize round-trips
  faithfully (so quicksave reload preserves the wedge).
- Whatever happens during a fresh insert from the picker initializes
  state correctly, so the rebuilt chain works.
- The "fresh chain works, restored chain doesn't" split points at
  something in the unit's `onLoadGraph` vs. its `serialize` /
  `deserialize` pair not lining up.

**To investigate:**
- Capture a copy of the broken quicksave (the user's
  plumbutter-loaded version). It's needed to reproduce.
- Diff the unit-internal state of a broken-quicksave-loaded stereo
  mix against a freshly-inserted one. Look for: input/output
  connection map, sub-chain head pointer, gain or pan parameters at
  out-of-band values.
- Check whether unlinking + relinking the channel resets the failure
  (would point at the link/unlink chain rebuild path).
- Check whether the failure depends specifically on the mono Mix
  being downstream, or whether the stereo mix alone reproduces it.
- Report upstream to odevices since the issue affects vanilla.

**Status 2026-06-15:** Bram cannot reproduce locally with the
described setup. Following up with the user to gather more info
(broken quicksave file, exact unit versions, link/unlink state,
sample player config feeding the stereo mix, whether the failure
appears on first patch build or only after some operation).

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

## Chain UI: Replace Picker Opens in Favorites-Tagging Mode (target: .9.2.1)
Two related quality-of-life bugs in the unit picker invoked from the
chain UI's **replace** facility. Investigation 2026-05-16 mapped both
to exact file:line evidence below; share a common entry point
(`ring:toggleFavoritesEditMode()`).

### 1. Replace lands in tagging mode instead of normal browse

When the user invokes "replace" on a chain unit (shift + M3 in the
header sub-menu), the unit picker opens already in favorites-tagging
mode. User has to release shift to get out of tagging before they can
pick a replacement.

**Mechanism**:
1. `xroot/Unit/ViewControl/Header.lua:243-255` (`subReleased`) does
   NOT check the `shifted` parameter before dispatching
   `doCommand("Replace")` -- unlike `spotReleased` at lines 157-158
   in the same file, which does filter shifted.
2. `doReplace` at `Header.lua:212-218` shows the `UnitChooser`. Shift
   is still physically held at this moment.
3. `xroot/Unit/Chooser/Default.lua` has `shiftReleased` (line
   424-427) but **no `shiftPressed`**. When the input system
   processes the picker's first refresh, the shift-held state
   surfaces as a `shiftReleased` event (since the press had no
   handler to consume the transition).
4. `shiftReleased` calls `ring:toggleFavoritesEditMode()` -> picker
   enters tagging mode on first display.

**Surgical fix (one line)**: add an empty `shiftPressed` handler to
`Default.lua` that consumes the event:
```lua
function Chooser:shiftPressed()
  return true
end
```

**Alternative**: at `Header.lua:subReleased`, add `if shifted then
return false end` at the top, consistent with the existing
`spotReleased` pattern.

### 2. Exiting favorites-tagging mode feels sluggish

Press shift -> instant tagging-mode swap. Release shift -> perceptible
lag before the picker reverts to browse mode.

**Mechanism (asymmetry)**:
- **Enter** tagging (`xroot/Unit/Chooser/init.lua:148-156`): updates
  text labels + panel state. No list work. Instant.
- **Exit** tagging (`init.lua:157-172`): calls
  `saveFavoritesIfDirty()` (synchronous file I/O on the rear card) +
  `refresh()` on **both** `categoric` AND `alphabetic` choosers, not
  just the visible one.

`refresh()` at `Default.lua:169-261` is heavy: clears the list,
iterates `Factory.getCategories()` + `Factory.getUnits()`, re-sorts,
rebuilds the category hierarchy, calls `mlist:updateLayout()` (a
SWIG'd C++ call that triggers a redraw).

**Root causes**:
1. Synchronous file I/O on the input handler.
2. Both choosers refreshed instead of just the visible one.
3. Full rebuild instead of an in-place "fix favorites borders" pass.

**Surgical fix**: refresh only the visible chooser, defer file save:
```lua
-- init.lua exit branch
if self.current == self.categoric then self.categoric:refresh() end
if self.current == self.alphabetic then self.alphabetic:refresh() end
-- Schedule file save via Timer.after(0, ...) instead of inline.
```

**Bigger but better**: cache category/alphabet trees, only update
borders/colors of favorited items (similar pattern to `choose()` at
`Default.lua:374-380`) instead of full rebuild. Drops both costs to
near-zero.

### Cross-cutting

Fixing Bug 1 (so toggle doesn't fire on picker init) reduces Bug 2's
perceived frequency but doesn't fix the underlying sluggishness when
the user does deliberately enter and exit tagging. Both fixes should
land in the same .9.2.1 patch.

## Sequencer BPM Latch: Exit Gestures + Scope-Mode Persistence (target: .9.2.1)
Two related issues with the `shift+S2` BPM-latch fader in the
sequencer takeover. Currently it's only reliably exitable via a
second `shift+S2` toggle; UP doesn't release it, and the latch
state persists across scope-mode exit (so re-entering the takeover
later finds the encoder still routed to BPM with no visible cue
beyond the sub-bar label).

### 1. UP and CANCEL should release the latch

`xroot/Sequencer/GridView.lua:1808-1818` (cancelReleased) already
has a bpmLatched release branch, so CANCEL release is wired in
code. If hardware testing confirms CANCEL is not actually working,
trace why; otherwise the only real gap is UP.

`upReleased` at `GridView.lua:1854-1879` has no bpmLatched branch.
Add a parallel block at the top:
```lua
if self.bpmLatched then
  self.bpmLatched = false
  self.bpmAccum   = 0
  -- Mirror the persistence behaviour from cancelReleased so the
  -- dialed value survives reboot.
  local seq = app.AudioThread.getSequencerTask()
  if seq then
    local Settings = require "Settings"
    Settings.set("bpm", string.format("%.2f", seq:getBpm()))
  end
  self:refresh()
  return true
end
```

### 2. Latch must NOT persist across takeover hide / scope-mode exit

`GridView:onHide` at `GridView.lua:1198-1203` only clears the frame
callback; it does NOT reset `bpmLatched`. So if the user latches
BPM, exits the takeover (via `shift+ENTER`, mode-toggle switch,
home gesture, etc.), and re-opens the sequencer later, the encoder
is still routed to BPM with the only signal being the sub-bar
label, which is easy to miss after a context switch.

Fix in onHide:
```lua
function GridView:onHide()
  if self.frameCallback then
    Signal.remove("onDisplayFrame", self.frameCallback)
    self.frameCallback = nil
  end
  -- Release any sticky modal state so a later re-show starts clean.
  if self.bpmLatched then
    self.bpmLatched = false
    self.bpmAccum   = 0
    local seq = app.AudioThread.getSequencerTask()
    if seq then
      local Settings = require "Settings"
      Settings.set("bpm", string.format("%.2f", seq:getBpm()))
    end
  end
end
```

While we're here: consider whether other modal states should also
reset in onHide (selection, mark modal, editingL1). Currently
they persist too. Same scope-mode-exit principle: re-entering
should land in the default state, not the middle of a half-finished
gesture.

## Sequencer: Include 0 in gate-len Random Pool (target: .9.2.1)
The gate-len random pool currently is `{0.0625, 0.125, 0.25, 0.5,
1.0, 2.0}` (TIE / 4.0 intentionally excluded). It should also include
0 so random rolls can produce "no gate" (silent step) outcomes.
Lets `?` actions and the selection-RAND softkey author musical rest
patterns instead of always-firing density.

Two files to update so the Lua-side selection-RAND and the C++ L2
ACTION_RAND stay in sync:

1. `xroot/Sequencer/GridView.lua:715` (`kRandomBeats`): add `0` to
   the front of the list. `{0, 0.0625, 0.125, 0.25, 0.5, 1.0, 2.0}`.
2. `od/sequencer/ActionApply.cpp:106-108` (`beats` static array in
   ACTION_RAND case 2/3): add `0.0f` and bump the
   `uniform_int_distribution<int> b(0, 5)` upper bound to `(0, 6)`.

Consider whether to weight the pool toward "fire" (e.g.
`{0, 0.25, 0.25, 0.5, 1.0, 2.0}` with 0 appearing once vs the others
appearing 1-2x) to keep density-on-roll musically sensible. Or leave
uniform and let the user roll a rest more often. Pick before
implementation.

## Sequencer: Mark Mode vs Edit Mode Conflict (target: .9.2.1)
Pressing `S2` to enter mark mode while in L1 inline-edit mode lets
both modes coexist. Encoder is then ambiguous (nudge value vs.
live-update marker2), and the visual cursor / sub-bar reads
incorrectly for at least one of them.

**Mechanism**: `xroot/Sequencer/GridView.lua:1471-1490` (`subReleased`
case `i == 2`) flips `self.markingMode = "marking_end"` without
checking `self.editingL1`. The two state machines are independent.

**Fix**: at the top of the `elseif i == 2 then` branch, force-commit
any in-flight L1 edit before entering mark mode:
```lua
elseif i == 2 then
  -- If user was inline-editing an L1 cell, commit-and-exit edit
  -- before entering / toggling mark mode. The cell value has been
  -- live-pushed to the engine on every encoder tick during the
  -- edit, so "commit" just means dropping the editingL1 flag.
  if self.editingL1 then
    self.editingL1 = false
  end
  if self.markingMode == "idle" then
    ...
```

The same defensive check probably belongs on any other modal-entry
gesture that could collide with edit mode (selection extension via
shift+encoder, mark-modal exit S3 unify, etc.). Audit the
subReleased and subPressed branches for parallel cases while at it.

## Sequencer: Admin Toggle for ENTER-in-Edit Behavior (target: .9.2.1)
The bulk-edit-then-edit flow has an asymmetry users notice:

1. User builds a selection (shift+encoder), bulk-nudges values via
   encoder during selection (`GridView.lua:1638`).
2. ENTER commits the selection and drops into single-cell L1 edit
   mode on the focused cell (`GridView.lua:1764-1797` enterReleased,
   `editingL1=false` branch at 1783-1795).
3. Subsequent ENTER presses in single-cell edit mode advance focus
   head by 1 and **stay in edit mode** (`enterReleased` `editingL1=true`
   branch at 1783-1784).

Some users expect step 3's ENTER to instead **exit edit mode** back
to the navigation state they came from. The "in" route (ENTER -> edit)
and the "out" routes (UP / CANCEL -> nav) are incongruent: there's no
ENTER -> nav loop, only ENTER -> advance.

Both behaviors are defensible. Add an admin Setting under the
`Sequencer` subheading:

- **Setting name (proposed)**: `sequencerEnterInEditMode`
- **Choices**: `"advance"` (current default; ENTER moves to next
  cell, stays in edit) | `"exit"` (ENTER commits + exits edit, back
  to navigation)
- **Where it gates**: `GridView.lua:1783-1784` in the `editingL1`
  branch of enterReleased. If `"exit"`, drop `editingL1 = false` +
  refresh + return instead of incrementing focusHeadRow.

Plumbing:
- `xroot/Settings/init.lua`: new String entry, default `"advance"`.
- `xroot/Settings/Interface.lua`: surface under Sequencer subheading.
- `GridView.lua:1783-1784`: branch on `Settings.get(...)` with pcall
  guard (boot-time bench may call enterReleased before Settings.init).

If the user picks `"exit"`, document that "advance to next cell"
becomes encoder-driven only (the value-nudge edit happens at the
current cell; user uses encoder to navigate after exiting).

## Sequencer: shift+HOME Resets All Slot Playheads (target: .9.2.1)
Currently `shift+HOME` (zeroReleased) resets only the active slot's
playheads. Per the unified-transport model (S1 start/stop hits all
4 slots), the playhead reset should follow the same scope and
fan to all 4 slots.

**Mechanism**: `xroot/Sequencer/GridView.lua:1903-1916` (`zeroReleased`)
calls `seq:resetSlot(self.slot)` -- single-slot only -- when not in
L1 cell-editor mode.

**Surgical fix**: replace the single call with a loop:
```lua
local seq = app.AudioThread.getSequencerTask()
if seq then
  for s = 0, 3 do seq:resetSlot(s) end
  self:refresh()
end
```

In-edit-mode behavior at lines 1904-1911 stays untouched -- there
shift+HOME zeros the focused cell (a different gesture entirely).

## TXo Units: Top-Level Passthrough Toggle (target: .9.2.1)
TXo TR + CV units currently pass the chain input straight through to
Out1 (and Out2 when stereo) regardless of port state -- the unit
acts as both "send to I2C" AND "pass audio through". Some patches
want I2C-pure send with no audible passthrough; some want only
passthrough with no TXo (impractical via removing the unit but
worth supporting via the same toggle).

**Files**: `mods/txo/assets/TR.lua:23-41` (onLoadGraph) +
`mods/txo/assets/TR.lua:43-92` (views table + onLoadViews +
expanded list); same shape in `mods/txo/assets/CV.lua`.

**Widget research** (from .9.2.1 plan): no existing "binary toggle
on top-level view" ViewControl. Recommended design: continuous
**Multiply + Fader on ParameterAdapter** rather than a discrete
toggle. Gives crossfade-to-mute for free, same encoder UX as gain,
zero new widget code.

**Surgical implementation** (per-unit, same pattern):
1. `onLoadGraph`: add `app.Multiply()` named `passthrough` between
   the txo object's Out and `self:Out1`. Add a `ParameterAdapter`
   named `passthroughGain` with `Out` tied to one side of the
   Multiply. Initial bias 1.0 (= passthrough on, current behavior).
2. `onLoadViews`: add a `GainBias` ViewControl named `passthrough`,
   `biasMap = Encoder.getMap("unit")` clamped 0..1, `biasPrecision
   = 2`, `initialBias = 1.0`. Sub-bar label "passthrough".
3. Insert `"passthrough"` at the FRONT of the `expanded` views list
   so it sits left of `port` / `threshold` on the top-level bar.

**Default decision**: bias = 1.0 (passthrough on). Preserves existing
behavior on upgrade; old presets with no `passthroughGain` field
read the default and stay audible.

**Risk callouts**:
- Sample-accurate-bypass check: bit-exact identical to a direct
  connect at gain 1.0? Multiply-by-1 should be, but verify if any
  patch relies on TXo as a sample-accurate fall-through.
- Preset compat: ensure old presets load with `passthroughGain`
  branch reading 1.0 as default (no field present in saved data).
- View-list shift: focused-unit spot indexing may break for users
  with TXo focused; verify spotted-strip rebuild handles the new
  view inserting at the front.

**Hardware verification gate** (TXo required, cannot validate in
emu without bus simulator): with toggle dialed to 0.0, assert In1 ->
Out1 silent; assert TR gate detection still fires (TXo LED); assert
CV stream still drives V/oct downstream.

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

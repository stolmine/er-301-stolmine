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

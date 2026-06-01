# ER-301 Cursor + Selection Conventions

Read-up after the third round of bench feedback on Performance view
carets. Source-of-truth for "what does the standard firmware do",
captured from:

- `xroot/Unit/ViewControl/init.lua` (the ViewControl base)
- `xroot/Unit/ViewControl/GainBias.lua` (the canonical fader)
- `xroot/SpottedStrip/Control.lua`, `Section.lua`, `init.lua`
- `od/graphics/spotted/SpottedStrip.cpp` (cursor + spot mechanics)
- `od/graphics/controls/Fader.cpp` (per-fader cursor anchoring)
- `od/graphics/birdseye/ChainOverview.cpp` (the ▼-above pattern)
- `od/graphics/Cursor.{h,cpp}` (the bouncing caret renderer)

Goal: stop nibbling on Performance view by writing the rules down.

## Two cursor states

The firmware distinguishes:

- **Navigation** -- "the cursor is hovering over this item; encoder
  will move it elsewhere; pressing M/S/ENTER acts on it."
- **Selection** (a.k.a. focused) -- "this control is now grabbed
  for editing; encoder writes to its value; UP releases."

Two visually-distinct caret idioms convey these states. They never
appear on the same display at the same time for the same ply.

## ▶ Right-pointing caret

Rendered by `Cursor::draw` when `mCursorState.orientation == cursorRight`.
Anchored at the LEFT of a control with the tip pointing right. Used by:

- **`app.Fader`** -- set in C++ constructor (`Fader.cpp:20`). Every
  draw call, `mCursorState.x = mWorldLeft` and `mCursorState.y` is
  re-aimed at the bias slider position. The fader is the main cursor
  controller of its `Unit.ViewControl` (`GainBias.lua:145`,
  `Pitch.lua:103`, `BranchMeter.lua:44`, etc).
- **`app.Readout`** -- the readouts in the sub display. Anchored at
  their `mWorldLeft` similarly.
- **`app.TextPanel`** -- set in C++ constructor (`TextPanel.cpp:26`).
- All other "stick a caret to the left of this control" widgets.

Distinction:
- The Fader's ▶ is **always present whenever the control is on
  screen** (the controller is permanently bound at init). It serves
  as "this fader's bias is at this position." It's persistent
  scene-furniture, not a navigation indicator.
- A Readout's ▶ only appears when a parent ViewControl explicitly
  routes the sub cursor to it via `setSubCursorController(readout)`.
  That happens in `setFocusedReadout`, which is called in
  `spotReleased` / `enterReleased` / `subReleased`.

## ▼ Down-pointing caret

Rendered by `Cursor::draw` when `mCursorState.orientation == cursorDown`.
Anchored ABOVE an item with the tip pointing down. Used by:

- **`app.ChainOverview`** (the birds-eye view of all units in a
  chain, accessed via MODE button) -- updates `mCursorState.x`,
  `mCursorState.y` to point at the top of the currently selected
  unit each draw (`ChainOverview.cpp:484-486`).
- **`app.DurationControl`** -- sets cursorDown in init.

This is the "horizontal-list-of-things-being-navigated" idiom.
Each item is a discrete target; the cursor lands on one at a time;
encoder navigates between them. There is no "focus" or "selection"
state because the items aren't editable in place.

ChainOverview specifically: the user hits MODE to enter it, the ▼
is above whichever section/unit they last had selected in the chain
edit view, they encoder-scroll to highlight a different one, and
ENTER drops them back into the chain edit view selected on that
unit. ▼ → ENTER → ▶ (because they land back on a fader's ▶).

## Section border (selection highlight)

Drawn by `Graphic::draw`'s border block (`Graphic.cpp:100-133`).
1px outline in `mBorderColor` (typically WHITE) around the control
graphic.

Set by `ViewControl:enableHighlight` (`init.lua:71-84`):
- `controlGraphic:setBorder(1)`
- A `MoreThisWay` left arrow appears as a child of the control
  graphic.
- `self.focused = true`.

Cleared by `disableHighlight` (`init.lua:86-93`):
- `setBorder(0)`
- left arrow hidden.
- `Encoder.set(Neutral)` to disengage encoder.

Called from:
- `focus()` (`init.lua:95-104`) -- which also does `grabFocus(
  "encoder", "upReleased", "cancelReleased")` and runs `onFocused()`.
- `unfocus()` (`:106-115`) -- inverse.

**Border = selection.** When you see a border around a control, that
control owns the encoder. When you don't, it doesn't.

## Hover state (cursor on control, not focused)

Driven by `ViewControl:onCursorEnter` (`init.lua:130-137`). When
the SpottedStrip cursor lands on this control:

- `addSubGraphic(self.subGraphic)` -- the sub display panel for
  this control appears.
- `grabFocus("dialPressed", "dialReleased", "subPressed",
  "subReleased", "homeReleased", "homePressed", "zeroPressed",
  "enterReleased", "selectReleased")` -- panel-button events route
  here. **Notably NOT `encoder` / `upReleased` / `cancelReleased`**;
  those go to whoever's `focus()`d.
- `Encoder.set(self.encoderState)` -- encoder sensitivity per the
  control's saved state (the strip-level encoder still navigates
  between sections, not this control's value).

Reverse: `onCursorLeave` (`:139-147`) removes the sub graphic +
release-all-focus + disableHighlight.

## The chain edit view at a glance

When you encoder-scroll the chain edit view, here's what's actually
shown per state:

### Hover-only (cursor on a fader-bearing control, NOT focused)

- Main display: the fader is on screen, with ▶ at the left of the
  bias position (the Fader's own permanent cursorRight).
- Sub display: the control's sub graphic (readouts, scope,
  description, mod button) is showing.
- NO border around the control.
- NO MoreThisWay arrow.
- Encoder turning -> SpottedStrip's `encoder` handler scrolls to
  the next control. **It does NOT edit the fader's value.**

### Focused (control grabbed for editing)

- Same fader on screen, same ▶ at bias. (The fader didn't move; it
  just got selected.)
- Sub display: same sub graphic, now with ▶ at the left of the
  focused readout (set via `setSubCursorController`).
- 1px border around the control + MoreThisWay arrow on its left.
- Encoder turning -> the focused readout's value changes.

So in chain edit:
- ▶ on the Fader is **always there** -- it's an anchor, not a
  state cue.
- The cue for "you are now editing" is the BORDER + sub caret,
  not the fader caret.
- The cue for "you are hovering" is implicit: the strip scrolled
  this control on-screen, so it must be where the cursor is.

## How `GainBias:subReleased` cycles through states

For S2 (gain) / S3 (bias), the canonical pattern from
`GainBias.lua:760-781`:

```lua
elseif i == 3 then
  if self:hasFocus("encoder") then       -- already selected
    if self.focusedReadout == self.bias then
      self:doBiasSet()                   -- second tap on focused
                                         -- readout: numeric kb
    else
      self:setFocusedReadout(self.bias)  -- focused on gain,
                                         -- switch to bias
    end
  else                                   -- just hovering
    self:focus()                         -- engage selection
    self:setFocusedReadout(self.bias)    -- and aim sub caret
  end
```

Three states:
1. **Hovered, not focused** → first tap: `focus()` + set readout.
   Border appears, sub ▶ appears at the readout.
2. **Focused on the OTHER readout** → tap switches focus to this
   readout. Border stays, sub ▶ moves.
3. **Focused on THIS readout** → second tap opens the decimal
   keyboard.

shift+S2 / shift+S3 (from the same `subReleased`):
```lua
if shifted then
  if i == 2 then self:doGainSet()
  elseif i == 3 then self:doBiasSet()
  end
  return true
end
```
Decimal keyboard direct, irrespective of current focus.

## Encoder behavior

When NOT focused: SpottedStrip handles encoder, scrolls between
sections.

When focused: the focused ViewControl owns "encoder" (via
`grabFocus("encoder", ...)` in `focus()`). `GainBias:encoder`
delegates to `self.focusedReadout:encoder(...)`. Strip encoder
handler doesn't fire because the focus widget intercepts the
event before it bubbles up.

## Performance view applied

The Performance view is not a chain edit (no Sections of
ViewControls). It's a Window with six fixed plies. M1 hosts a
Fader-style crossfader weight control; M2-M6 host scene slots.

Applying the conventions:

### Main caret on M1

- **Hovered, no readout focused**: ▼ above M1 (we're in the
  ChainOverview idiom -- horizontal list of plies, encoder
  navigates).
- **Focused on a readout**: ▶ on the fader at the bias position
  (we're in the GainBias idiom -- fader's permanent cursorRight
  takes over). PLUS ▶ on the sub readout. Border around M1.

The swap of main cursor controller from navCaret (▼) to cvFader
(▶) happens in the SAME place that `m1FocusedReadout` flips. That
**means `_setM1FocusedReadout` must trigger the controller swap**,
not just sub controller.

### Main caret on slots (M2-M6)

Slots have no focusable control. The main caret is permanently
▼ above the slot (or nothing on unoccupied plies).

### Sub caret

Standard convention: only appears when focused. Mirrors GainBias.

### Border

Standard convention: only when focused. For slot plies, never
(no editable target). For M1: only when `m1FocusedReadout ~= nil`.

### S-button behavior (M1)

Three-state cycle matching `GainBias:subReleased`:

```
not focused      -> S2/S3 focuses the corresponding readout
focused on OTHER -> S2/S3 switches to this readout
focused on SAME  -> S2/S3 opens decimal keyboard
shift+S2/S3      -> open decimal keyboard regardless of focus
```

### M1 mainReleased (tap)

```
cursor elsewhere      -> move cursor to M1
cursor on M1, !focus  -> focus the bias readout (auto-focus on
                         first M1 land)
cursor on M1, focused -> unfocus
```

This is a Performance-specific tweak: standard chain edit doesn't
auto-focus on cursor-arrival (the user must do an explicit
focus gesture). For Performance, since the M-key tap *is* the
arrival gesture, treating the first tap as a focus is friendlier
than two-tap-to-edit.

### UP (M1 focused)

`unfocus()`. Standard.

### CANCEL / ZERO (M1 focused)

Route to focused readout. Standard.

## Implementation checklist for Performance.lua

When _refresh runs or m1FocusedReadout changes, the main cursor
controller MUST be reconsidered:

```lua
function Performance:_refresh()
  ...
  if self.cursorCol == 1 and self.m1FocusedReadout then
    self:setMainCursorController(self.cvFader)
    self:setSubCursorController(self.m1FocusedReadout)
  else
    self:setMainCursorController(self.navCaret)
    self:setSubCursorController(nil)
  end
  -- border only when actively editing
  if self.cursorCol == 1 and self.m1FocusedReadout then
    self.cursorBox:show()
  else
    self.cursorBox:hide()
  end
  ...
end

function Performance:_setM1FocusedReadout(readout)
  if readout then readout:save() end
  self.m1FocusedReadout = readout
  self:_refresh()  -- so the main controller + cursorBox track
                   -- the new focus state
end
```

The previous bug: `_setM1FocusedReadout` only updated the SUB
controller (▶ at readout) but left the MAIN controller as the
nav ▼. So when you tapped S3 on M1 from hover, you got the
sub-display ▶ on the bias readout but the ▼ stayed above M1.

Fix: route through `_refresh` (or update both controllers and
the cursorBox here too).

## Caret rendering quirks

- The Cursor singleton tweens position between target moves
  (`Cursor.cpp:30-58`). Mid-tween, the orientation is whatever
  the current controller says. So when controller swaps from
  navCaret (▼ above) to cvFader (▶ at bias), the cursor
  instantly switches orientation but the position slides over
  ~130ms. That looks fine.
- `mCursorState.show = false` (set via the new
  `setCursorShow(bool)` API on Graphic) suppresses the caret
  entirely. Used by `noCaret` placeholder graphics when we
  want "no main caret at all" without disabling
  `mainGraphicContext.mShowCursor` (which would also kill the
  sub caret).
- `app.SpottedStrip` updates its own `mCursorState` each draw to
  position above the selected spot, but the controller is never
  set to the SpottedStrip itself in standard chain edit, so
  this is effectively dormant. Our Performance view doesn't
  use SpottedStrip.

## TL;DR

- **▶ on a Fader is permanent** -- it's not a state cue, it's an
  anchor that shows where the bias is.
- **▼ above an item** is the "horizontal-list nav" cue
  (ChainOverview). Use it when there's no permanent ▶ already
  serving the role.
- **Border** = focused (selected for editing). Not navigation.
- **Sub caret** = pointing at the focused readout. Not present
  when nothing is focused.
- For Performance, the M1 fader gets the ▶ when focused, the ▼
  when hovered but unfocused; slots get the ▼ always (no
  editable target → no ▶ anchor possible).

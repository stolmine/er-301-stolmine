# Sequencer: terminal edit mode + encoder LEDs (H4 + C1+E2)

Follow-up batch from the 2026-06-09 sequencer modal sweep
(`docs/planning/sequencer-modal-sweep-followups.md`). The A-D polish
batch (F4 / D1 / H6 / H8) landed on develop at `4a95e3a` and shipped
in firmware `9.4.0.29`. This branch picks up the two remaining items
that needed design discussion or API surface investigation.

**Branch:** `feature/sequencer-edit-terminal` off develop `4a95e3a`.
**Scope:** two commits, both on `xroot/Sequencer/GridView.lua`.
**Estimated size:** ~70 lines across 2 commits.

## H4 — encoder coarse/fine LEDs

### API surface found

`xroot/Encoder.lua` already exposes a clean abstraction:

- `Encoder.set(state)` where `state` is `Encoder.Fine`, `Encoder.Coarse`, or
  `Encoder.Neutral`
- The state machine's `enter` handlers drive `LED_DIAL1` / `LED_DIAL2`
  via the SWIG-bound `app.Led_on` / `app.Led_off` (lines 207-223)
- Standard convention used throughout: `PinView/Fader.lua:85`,
  `Unit/ViewControl/EncoderControl.lua:36`,
  `Unit/ViewControl/GainBias.lua:663-665`

No new bindings needed. The LED IDs `LED_DIAL1` / `LED_DIAL2` are
auto-exposed to Lua because `od/glue/app.cpp.swig:251` includes
`<hal/gpio.h>`.

### Mapping

The encoder LED reflects whichever modal currently owns the encoder:

| GridView state | LED |
|---|---|
| `bpmLatched` | `Fine` or `Coarse` per `bpmStepMode` |
| `editingL1` | `Fine` or `Coarse` per `editStepMode` |
| `selectionActive` AND layer L1 AND same column | `Fine` or `Coarse` per `editStepMode` (bulk-edit) |
| any other state | `Neutral` (both LEDs off) |

### Implementation

**Import** (line ~15):

```lua
local Encoder = require "Encoder"
```

**Helper** (insert before `_commitOtherModalsBefore` at line ~1223):

```lua
function GridView:_pushEncoderLED()
  if self.bpmLatched then
    Encoder.set(self.bpmStepMode == "coarse" and Encoder.Coarse or Encoder.Fine)
  elseif self.editingL1
         or (self.selectionActive
             and self.layer == "L1"
             and self.selectionColumn == self.columnCursor) then
    Encoder.set(self.editStepMode == "coarse" and Encoder.Coarse or Encoder.Fine)
  else
    Encoder.set(Encoder.Neutral)
  end
end
```

**Call sites:**

1. End of `refresh()` (line ~1150): `self:_pushEncoderLED()` as the
   final statement. refresh() is the per-state-change sync function so
   one call here covers every modal transition.
2. Top of `onHide()` (line ~1169): `Encoder.set(Encoder.Neutral)`.
   Explicit release of LED ownership when the takeover dismisses.
3. `onShow()`: already calls `:refresh()` at the end, which picks up
   the helper. No new line.

`dialPressed` already calls `:refresh()` after flipping the step mode,
so the helper fires there too. No direct call needed.

### Hardware-only behavior

LED writes go through `hal/gpio.h:Gpio_write` which is am335x GPIO on
hardware and stubbed in emu. Helper is a no-op in the emulator; bench
verification is hardware-only.

### Totals

1 import + 15-line helper + 2 call sites = **~20 lines**.

## C1 + E2 — terminal edit mode + S-key rebind

### Design intent

While `editingL1` is active, the bare S-keys are repurposed for
edit-specific actions. The cross-modal entry gestures that currently
flow from edit (mark via bare S2, BPM latch via shift+S2, layer toggle
via bare S3) are silenced. Edit becomes a pit: easy to enter (ENTER /
same-col M-tap), exits are explicit (UP / CANCEL / column-switch / new
slot). No accidental escape into other modes.

The L2 `CellEditor` modal is untouched; it has its own complete
S-key environment and is unrelated to L1 inline edit.

### Bindings while `editingL1`

| Key | Bare | Shifted |
|---|---|---|
| S1 | `dupe^` (copy from row above) | `paste` (existing, preserved) |
| S2 | step back one row | (blank; BPM-latch entry blocked) |
| S3 | `rand` (`randomForColumn`) | `clr` (existing zero-cell, preserved) |

**Bare actions in detail:**

- **S1 dupe^**: `seq:setL1(slot, col, focusHeadRow,
  seq:l1Value(slot, col, focusHeadRow - 1))` guarded by
  `focusHeadRow > 0`. No-op at row 0.
- **S2 step**: `self.focusHeadRow = self.focusHeadRow - 1` clamped to
  0. Stay editing. Pairs with ENTER's commit + advance for an
  up/down editing loop without exit.
- **S3 rand**: `seq:setL1(slot, col, focusHeadRow,
  randomForColumn(col))` using the column-type-aware random pool that
  already exists at line ~682 (used by selection-mode bulk-rand).

### Shifted bindings preserved

`shift+S1` paste and `shift+S3` clr are cell-edit-relevant gestures
and stay reachable. They already work because the shifted overlay
branch runs unconditionally before the new edit-mode branch.

### Cross-modal entry gates

While `editingL1`:

- `subPressed`: `shift+S2` (BPM-latch entry) returns false. Edit stays
  the active modal.
- `subReleased`: bare S2 (mark entry) and bare S3 (layer toggle) are
  short-circuited by the new edit-mode branch BEFORE reaching the
  default transport/mark/layer code.

### Implementation

**Change 1** — subPressed gate (line ~1332). Insert at top of the
`shift+S2` branch:

```lua
if i == 2 and shifted then
  if self.editingL1 then return false end
  -- existing ext-clock + latch enter/exit code
```

**Change 2** — subReleased edit-mode branch. Insert AFTER the
shifted overlay (`if shifted then ... end` at line ~1483) and BEFORE
the default transport/mark/layer branch (line ~1490):

```lua
if self.editingL1 then
  if i == 1 then
    -- Dupe from row above. No-op at row 0.
    if self.focusHeadRow > 0 then
      local v = seq:l1Value(self.slot, self.columnCursor, self.focusHeadRow - 1)
      seq:setL1(self.slot, self.columnCursor, self.focusHeadRow, v)
      self:refresh()
    end
    return true
  elseif i == 2 then
    -- Step back one row, stay editing. Pairs with ENTER's advance.
    if self.focusHeadRow > 0 then
      self.focusHeadRow = self.focusHeadRow - 1
      self:refresh()
    end
    return true
  elseif i == 3 then
    -- Randomize current cell using the column-type-aware pool.
    seq:setL1(self.slot, self.columnCursor, self.focusHeadRow,
              randomForColumn(self.columnCursor))
    self:refresh()
    return true
  end
  return false
end
```

**Change 3** — refresh() sub-bar labels (line ~1112). Insert
editingL1 branch above the existing selectionActive branch:

```lua
elseif self.editingL1 then
  if app.isShiftButtonPushed() then
    self.s1Button:setText(clipboard ~= nil and "paste" or "")
    self.s2Button:setText("")
    self.s3Button:setText("clr")
  else
    self.s1Button:setText("dupe^")
    self.s2Button:setText("step")
    self.s3Button:setText("rand")
  end
```

### What stays reachable while editingL1

- ENTER (commit + advance one row)
- UP, CANCEL (exit edit)
- HOME / shift+HOME (`zeroReleased`, cell-clear, independent of S-keys)
- M-tap on current column (existing advance behavior)
- M-tap on different column (column-switch, drops editingL1)
- `shift+M2..M5` (slot switch, already clears in-flight modals)
- dialPressed (FINE/COARSE toggle on editStepMode)
- `shift+ENTER` (`commitReleased`, returns to scope subview)
- `shift+S1` (paste), `shift+S3` (clr)
- Encoder + `shift+encoder` (cell nudge / super-step)

### What becomes unreachable while editingL1

- Bare S2 (mark entry)
- Bare S3 (layer toggle)
- `shift+S2` (BPM-latch entry)
- S1 transport stop/start (acceptable; exit edit first)

### Totals

1 subPressed gate + 1 subReleased branch (~35 lines) + 1 refresh
label branch (~12 lines) = **~50 lines**.

## Test matrix

19 rows total. Saved as
`docs/planning/sequencer-edit-terminal-test-matrix.csv` for bench walk;
companion `-results.csv` for annotated outcomes after bench.

| Section | ID | Starting state | Gesture | Expected | Watch |
|---|---|---|---|---|---|
| **H4** | H4-1 | nav, no edit | (idle) | both LEDs off | Neutral |
| H4 | H4-2 | editingL1, editStepMode=fine | ENTER on col 0 | LED_DIAL1 on | Fine LED lights |
| H4 | H4-3 | editingL1 | dial press | LED_DIAL2 on, LED_DIAL1 off | swap immediate |
| H4 | H4-4 | bpmLatched, bpmStepMode=fine | shift+S2 enter latch | LED_DIAL1 on | Fine LED |
| H4 | H4-5 | bpmLatched + bare S2 exit | exit latch | both off | Neutral |
| H4 | H4-6 | bulk-edit, editStepMode=fine | selection on col 1 | LED_DIAL1 on | Fine LED during bulk |
| H4 | H4-7 | onHide / takeover dismiss | UP from latched | both off | Neutral persists |
| **C1** | C1-1 | editingL1 | bare S1 | row above value copied | "dupe^" label |
| C1 | C1-2 | editingL1, row=0 | bare S1 | no-op | cell unchanged |
| C1 | C1-3 | editingL1 | bare S2 | focusHeadRow -=1, still editing | row indicator up |
| C1 | C1-4 | editingL1, row=0 | bare S2 | no-op | row stays 0 |
| C1 | C1-5 | editingL1 | bare S3 | cell randomized | "rand" label; plausible value |
| **E2** | E2-1 | editingL1 | shift+S2 | NO BPM latch entry | sub-bar stays editing |
| E2 | E2-2 | editingL1 | bare S2 | step-back (NOT mark entry) | no marker indicator |
| E2 | E2-3 | editingL1 | bare S3 | rand (NOT layer toggle) | layer stays L1 |
| E2 | E2-4 | editingL1 | shift+S1 | paste still works | clipboard pasted |
| E2 | E2-5 | editingL1 | shift+S3 | clr still works | cell zeroed |
| E2 | E2-6 | editingL1 | UP | exit edit | edit indicator off; LED Neutral |

## Build + bench sequence

1. Implement H4 commit; `luac5.4 -p` parse check.
2. Implement C1+E2 commit; parse check.
3. Emu smoke launch; check `~/.od/front/crash.log` and `/tmp/emu.log`.
4. Hardware build: clean rebuild ARCH=am335x PROFILE=release. Version
   auto-derived per `scripts/env.mk` (dev digit `.31` or higher).
5. Bench-walk the 19-row matrix on hardware. H4 only verifiable on
   hardware (emu GPIO stubs).
6. Save bench annotations to `-results.csv`.
7. Merge `feature/sequencer-edit-terminal` to develop, then rpidev.
   Push both.

## Known risks

- **Encoder.set + emu**: untested whether emu's GPIO stubs silently
  swallow or log. Verify on first emu launch.
- **Selection-extend tick**: `selectionActive` is true on the first
  shift+encoder tick already on the same column. LED will jump
  Fine/Coarse on that tick. Acceptable; matches existing editStepLabel
  behavior.
- **L2 mark mode encoder routing**: mark on L2 routes encoder to
  focusHead, not cell. LED goes Neutral (no edit step semantics). This
  is correct since the encoder isn't editing a value.
- **No infinite recursion in refresh**: `_pushEncoderLED` doesn't call
  `:refresh()` — safe.

## Open questions reserved for future polish

- Encoder.set is hardware-only. If we ever want the emu to render an
  LED indicator, a small UI ring chip near the encoder dial in the
  sub-display would mirror the state. Out of scope here.
- Terminal-edit could extend to other modals (mark-mode encoder owners
  could lock S-keys too). Out of scope; current scope is editingL1.

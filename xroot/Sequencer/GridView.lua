-- ER-301 stolmine sequencer Step-1 minimum-interactable view.
--
-- Renders one slot's six columns as a read-only grid maximizing row-count
-- visibility on the 256x64 main display: top row = column headers with
-- live playhead counters (format "name:NN"), remaining rows = L1 cell
-- values per column with a ">" marker on each column's playhead row.
--
-- Sub display: slot label + transport status + BPM + S1/S3 softkeys.
-- shift+ENTER returns to the standard scope view.

local app = app
local Class = require "Base.Class"
local Window = require "Base.Window"
local Signal = require "Signal"
local Env = require "Env"

local GridView = Class {}
GridView:include(Window)

-- Default slot index shown when the takeover opens. Each GridView
-- instance carries its own `self.slot` (initialized from this
-- constant) which the user can change via shift+M2..M5 to pick
-- among the 4 sequencer slots. Methods read self.slot at runtime.
local kDefaultSlot = 0

-- Column-name labels (matching seqN.<name> picker entries, kept to 3
-- chars so the header "name:NN" fits in 6 chars / ~30 px at font 8).
local kColNames = { "cv1", "cv2", "cv3", "gtL", "gtA", "stL" }

-- Layout constants.
local kFontHeader = 9                -- header row: font 9
local kFontMain   = 9                -- cell rows: font 9
local kFontSub    = 10               -- sub display: font 10 standard
local kColPly     = app.SECTION_PLY  -- 42 px per column on the 256 px main
local kRulerX     = 244              -- 2-digit row ruler at right; overlays the unused space past column 6's text (cell text ends ~x=242)
local kRowHeight  = 9                -- 9 px row pitch (font 9 + 1 px margin)
local kNumColumns = 6
local kVisibleRows = 6               -- cell rows shown below the header

-- Y-coordinates run BOTTOM-UP on this display. Header at y=53 (was 54,
-- dropped 1 px to clear top edge fully); cell rows at 44, 35, 26, 17,
-- 8, -1. The bottom row's baseline sits just below y=0, which is fine
-- because cell text is digits / punctuation only (no descenders); cap
-- height keeps the visible glyph above the bottom edge.
local kHeaderY = 53

-- Per-column display formatters. Each returns a 5-character string.
-- The engine stores CV cells in VOLTS (1V/oct convention for CV1).
-- Gate-len and step-len cells are in BEATS (1.0 = 1 quarter note).
-- Gate-amp is in [0, 1].

local kNoteNames = { "C ", "C#", "D ", "D#", "E ", "F ", "F#", "G ", "G#", "A ", "A#", "B " }

-- CV1: 1V/oct note name. Rounds to nearest semitone for display.
-- Format puts a 2-char note name and a 3-char signed octave: "C   4",
-- "C#  4", "B  -1", "G# 10".
local function fmtNote(volts)
  if volts ~= volts then return "  NaN" end
  local semi = math.floor(volts * 12 + 0.5)
  local oct  = math.floor(semi / 12)
  local n    = semi - oct * 12
  if n < 0 then n = n + 12 end
  return string.format("%-2s%3d", kNoteNames[n + 1], oct)
end

-- CV2/CV3: signed volts with one decimal: " 1.5", "-1.5", " 10.0", "-10.0".
local function fmtVolts(v)
  if v ~= v then return "  NaN" end
  return string.format("%5.1f", v)
end

-- gate-len / step-len: beats. Common musical fractions get clean names.
local function fmtBeats(v)
  if v ~= v then return "  NaN" end
  if v < 0.005 then return " 0.00" end
  if math.abs(v - 0.0625) < 0.001 then return "1/16 " end
  if math.abs(v - 0.125)  < 0.001 then return "1/8  " end
  if math.abs(v - 0.25)   < 0.001 then return "1/4  " end
  if math.abs(v - 0.5)    < 0.001 then return "1/2  " end
  if math.abs(v - 1.0)    < 0.001 then return "1    " end
  if math.abs(v - 2.0)    < 0.001 then return "2    " end
  if math.abs(v - 4.0)    < 0.001 then return "4    " end
  return string.format("%5.2f", v)
end

-- gate-amp: 0..1 envelope amplitude.
local function fmtAmp(v)
  if v ~= v then return "  NaN" end
  return string.format(" %4.2f", v)
end

-- step-len: clock ticks per row. Engine stores the value in beats
-- (1.0 = quarter note); at the locked 4 PPQN this is 4 ticks per
-- beat, so ticks = beats * 4. Displayed as an integer so the user
-- doesn't see decimals when nudging the step length.
local function fmtTicks(v)
  if v ~= v then return "  NaN" end
  return string.format("%5d", math.floor(v * 4 + 0.5))
end

local function fmtCellByCol(col, v)
  if col == 0 then return fmtNote(v) end
  if col == 1 or col == 2 then return fmtVolts(v) end
  if col == 3 then return fmtBeats(v) end   -- gate-len: fractional beats
  if col == 5 then return fmtTicks(v) end   -- step-len: integer ticks
  if col == 4 then return fmtAmp(v) end
  return string.format("%5.2f", v)
end

-- L2 cell rendering. Each L2 cell is a `predicate : action` rule that
-- fires when the host column's playhead lands on the cell's row. The
-- compact rendering fits the same 5-char field as L1: empty cells show
-- a centered em-dash, present cells show truncated "pred:action".
local kColLetters    = { "A", "B", "C", "D", "E", "F" }
local kPredSymbolMap = {
  [0] = "",      -- PRED_NONE (absent shown as em-dash by caller)
  [1] = "%",     -- PRED_MODULO
  [2] = "=",     -- PRED_EQ
  [3] = ">",     -- PRED_GT
  [4] = "<",     -- PRED_LT
  [5] = "?",     -- PRED_PROBABILITY
  [6] = "~",     -- PRED_APPROX
  [7] = "!",     -- PRED_FIRE  (no operand)
  [8] = "c",     -- PRED_CHANGED (no operand)
  [9] = "@",     -- PRED_STEP_RANGE
}
local kPredHasVal = {
  [1] = true, [2] = true, [3] = true, [4] = true,
  [5] = true, [6] = true, [9] = true,
}
local kActSymbolMap = {
  [0]  = "",     -- ACTION_NONE
  [1]  = "+",    -- ACTION_ADD
  [2]  = "-",    -- ACTION_SUB
  [3]  = "=",    -- ACTION_SET
  [4]  = "*",    -- ACTION_MUL
  [5]  = "/",    -- ACTION_DIV
  [6]  = "!",    -- ACTION_FIRE (no operand)
  [7]  = "?",    -- ACTION_RAND (no operand)
  [8]  = "M",    -- ACTION_MUTE (no operand)
  [9]  = "j",    -- ACTION_JUMP_THIS  (operand = row)
  [10] = "J",    -- ACTION_JUMP_GLOBAL
  [11] = ".",    -- ACTION_JUMP_SELF
}
local kActHasVal = {
  [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
  [9] = true, [10] = true, [11] = true,
}
local kActHasTgt = {
  [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
  [6] = true, [7] = true, [8] = true,
}

local function fmtNum(v)
  if v == math.floor(v) then return tostring(math.floor(v)) end
  return string.format("%.1f", v)
end

-- Column letter + optional 2-digit row pin for the compact preview.
-- Empty string when col == -1 AND row == -1 (host + playhead -- the
-- legacy form that needs no decoration). "h" host marker is omitted
-- to keep simple rules short ("%2:+1" rather than "%2:h+1").
local function colRefText(col, row)
  local s = ""
  if col >= 0 then
    s = kColLetters[col + 1] or "?"
  end
  if row and row >= 0 then
    s = s .. string.format("%02d", row)
  end
  return s
end

local function fmtL2Cell(predOp, predColA, predColARow, predVal,
                          actOp, actTgt, actTgtRow, actVal)
  if predOp == 0 then return "  -  " end
  local p = colRefText(predColA, predColARow) .. (kPredSymbolMap[predOp] or "?")
  if kPredHasVal[predOp] then p = p .. fmtNum(predVal) end
  local a = ""
  if actOp ~= 0 then
    if kActHasTgt[actOp] then
      a = colRefText(actTgt, actTgtRow)
    end
    a = a .. (kActSymbolMap[actOp] or "?")
    if kActHasVal[actOp] then a = a .. fmtNum(actVal) end
  end
  local s = (#a > 0) and (p .. ":" .. a) or p
  if #s > 5 then s = s:sub(1, 4) .. ":" end
  return string.format("%-5s", s)
end

-- Non-truncating variant of fmtL2Cell. Used by the shift-held
-- preview overlay on the sub display where a 5-char field would be
-- too tight to read the full rule. Unlike fmtL2Cell (which omits
-- the host letter for compactness), this resolves host (col == -1)
-- to the cell's own column letter so the user always sees the
-- column references explicitly.
local function fmtL2CellFull(predOp, predColA, predColARow, predVal,
                              actOp, actTgt, actTgtRow, actVal,
                              hostCol)
  if predOp == 0 then return "-" end
  local function resolved(col, row)
    local r = (col < 0) and (hostCol or 0) or col
    local s = kColLetters[r + 1] or "?"
    if row and row >= 0 then s = s .. string.format("%02d", row) end
    return s
  end
  local p = resolved(predColA, predColARow) .. (kPredSymbolMap[predOp] or "?")
  if kPredHasVal[predOp] then p = p .. fmtNum(predVal) end
  local a = ""
  if actOp ~= 0 then
    if kActHasTgt[actOp] then
      a = resolved(actTgt, actTgtRow)
    end
    a = a .. (kActSymbolMap[actOp] or "?")
    if kActHasVal[actOp] then a = a .. fmtNum(actVal) end
  end
  return (#a > 0) and (p .. ":" .. a) or p
end

function GridView:init(chain)
  Window.init(self)
  self:setClassName("Sequencer.GridView")
  self.chain = chain

  -- ---- main display: column headers + cell grid ----

  -- Header row: per column, "name:NN" at the top of the display.
  self.headerLabels = {}
  for c = 1, kNumColumns do
    local x = (c - 1) * kColPly + 2
    local lbl = app.Label(string.format("%s:00", kColNames[c]), kFontHeader)
    lbl:setJustification(app.justifyLeft)
    lbl:setPosition(x, kHeaderY)
    self:addMainGraphic(lbl)
    self.headerLabels[c] = lbl
  end

  -- Cell value grid: (kVisibleRows + 1) slots x kNumColumns columns.
  -- The +1 slot holds the partially-visible row that slides in from
  -- the bottom edge during a smooth scroll transition. Each slot's
  -- Y position is recomputed every refresh from `self.scrollFrac`.
  self.cellLabels = {}
  for c = 1, kNumColumns do
    local x = (c - 1) * kColPly + 2
    self.cellLabels[c] = {}
    for r = 1, kVisibleRows + 1 do
      local y = kHeaderY - r * kRowHeight
      local lbl = app.Label("      ", kFontMain)
      lbl:setJustification(app.justifyLeft)
      lbl:setPosition(x, y)
      self:addMainGraphic(lbl)
      self.cellLabels[c][r] = lbl
    end
  end

  -- Row ruler at the right edge: one label per visible row showing the
  -- absolute row number. Overlays the unused space past column 6's
  -- text (cell text ends ~x=242, ruler at x=244). Same +1-slot extra
  -- as the cell grid so the bottom partial row gets a ruler value.
  self.rulerLabels = {}
  for r = 1, kVisibleRows + 1 do
    local y = kHeaderY - r * kRowHeight
    local lbl = app.Label("00", kFontMain)
    lbl:setJustification(app.justifyLeft)
    lbl:setPosition(kRulerX, y)
    self:addMainGraphic(lbl)
    self.rulerLabels[r] = lbl
  end

  -- Slot indicator at the grid header's top-right corner. Mirrors
  -- the sub title's "seq{N}" so the user can see which sequencer
  -- slot the grid is showing without looking down at the sub
  -- display. Sits in the unused space past column 6's "stL:00"
  -- header text (ends ~x=242) and above the row ruler column
  -- (which starts at the first cell row, y=44). Refreshed in
  -- refresh() so slot picker (shift+M2..M5) updates it live.
  self.slotIndicator = app.Label("S1", kFontMain)
  self.slotIndicator:setJustification(app.justifyLeft)
  self.slotIndicator:setPosition(kRulerX, kHeaderY)
  self:addMainGraphic(self.slotIndicator)

  -- Active-cell cursor box. Outlines the cell at
  -- (focusHeadRow, columnCursor). Position updates in refresh().
  --
  -- Anchor math: an app.Label with the default margin (4 px) has a
  -- bounding box 8 px taller than the rendered text. setPosition(x, y)
  -- sets the BOTTOM of that bounding box, NOT the bottom of the glyph.
  -- The text glyph itself sits centered inside the bounding box, so
  -- its bottom is at y+4 and its top at y+4+textHeight-1.
  --
  -- Cursor box wraps the rendered text glyph with ~1 px buffer top
  -- and bottom. Empirically tuned: mBottom = labelY + 3, mHeight = 10.
  self.cursorBox = app.Graphic(0, 0, kColPly, 10)
  self.cursorBox:setBorder(1)
  self.cursorBox:setBorderColor(app.GRAY10)
  self:addMainGraphic(self.cursorBox)

  -- Selection box: a dotted-edge rectangle wrapping the active row-range
  -- selection on `selectionColumn`. Built from app.Drawing +
  -- app.DrawingInstructions (no C++ changes needed) -- the dotted look
  -- is achieved by emitting many short solid hline/vline segments.
  -- Hidden by default; refresh() rebuilds + shows when selection is
  -- active on the user's current column.
  self.selectionDrawing = app.Drawing(0, 0, 256, 64)
  self.selectionInstr   = app.DrawingInstructions()
  self.selectionDrawing:add(self.selectionInstr)
  self:addMainGraphic(self.selectionDrawing)
  self.selectionDrawing:hide()

  -- Dirty-edit indicator overlay. While a bulk-edit is in progress
  -- (selection active and at least one cell mutated), every modified
  -- cell gets a small dot rendered at its right edge. Rebuilt each
  -- refresh from `self.editedCells`. Hidden when nothing is dirty.
  self.dirtyDrawing = app.Drawing(0, 0, 256, 64)
  self.dirtyInstr   = app.DrawingInstructions()
  self.dirtyDrawing:add(self.dirtyInstr)
  self:addMainGraphic(self.dirtyDrawing)
  self.dirtyDrawing:hide()

  -- L2 fire-indicator overlay. Rendered only when on the L2 layer.
  -- Each refresh, polls seq:l2LastFiredRow(slot, col) per column. When
  -- the value changes, captures the current frame counter against
  -- (col, row); subsequent frames check elapsed time and render a
  -- small dot until the decay window expires (~10 frames at 55 Hz ~=
  -- 180 ms blink). Decay state lives in `self.l2FireDecay` as a per-
  -- column { row, framesLeft } table.
  self.l2FireDrawing  = app.Drawing(0, 0, 256, 64)
  self.l2FireInstr    = app.DrawingInstructions()
  self.l2FireDrawing:add(self.l2FireInstr)
  self:addMainGraphic(self.l2FireDrawing)
  self.l2FireDrawing:hide()
  self.l2FireDecay         = {}   -- [col] = { row = N, framesLeft = K }
  self.l2FireLastSerial    = {}   -- [col] = last seen l2FireSerial value
                                  -- (compares against engine's monotonic
                                  -- fire counter so same-row repeats still
                                  -- register as new fire events)

  -- ---- navigation state ----
  -- focusHeadRow: shared "global scroll" row, encoder-driven.
  -- columnCursor: which column is active, 0..5, M1-M6-driven.
  -- editingL1: when true, the encoder nudges the cell value at
  --            (focusHeadRow, columnCursor) instead of scrolling.
  -- selection*: shift+encoder builds a row-range selection on a column.
  self.focusHeadRow      = 0
  self.columnCursor      = 0
  self.encoderAccum      = 0  -- accumulates ticks until kEncoderThreshold is reached
  self.editingL1         = false
  self.editStepMode      = "fine"  -- "fine" or "coarse"; toggled via dial button
  self.selectionActive   = false
  self.selectionAnchor   = 0
  self.selectionEnd      = 0
  self.selectionColumn   = 0
  -- Bulk-edit revert/dirty state. preEditValues[col][row] holds the
  -- pre-bulk-edit value of each affected cell, captured the first time
  -- that cell is touched by an encoder tick. editedCells[col][row] is
  -- a set marking which cells currently show the dirty-edit indicator.
  -- CANCEL restores from preEditValues; UP commits (drops both tables).
  self.preEditValues     = {}
  self.editedCells       = {}
  -- Cursor-box easing state. Floats track the current rendered position
  -- of the cursor; each refresh eases them toward the logical target by
  -- kCursorEase. nil means "snap on next render" (used on first show
  -- and after hide). Y target moves smoothly with subPx during scroll
  -- transitions, so cursorAnimY normally just tracks it; `cursorEasingY`
  -- is flipped on when a discontinuous Y jump is detected (boundary
  -- scrolls where startRow can't shift) and stays on until the lerp
  -- catches up.
  self.cursorAnimX       = nil
  self.cursorAnimY       = nil
  self.cursorEasingY     = false

  -- Scroll-position easing state. scrollFrac is the absolute row at
  -- the top of the visible window in fractional row units; it eases
  -- toward the integer targetStart computed from focusHeadRow. nil =
  -- snap on first render (after onShow).
  self.scrollFrac        = nil

  -- Which sequencer slot the grid currently shows / edits. Default
  -- is slot 0; shift+M2..M5 selects slots 0..3 (M1 and M6 reserved).
  -- The cell editor modal reads this when it opens so ENTER on the
  -- L2 layer targets the right slot.
  self.slot = kDefaultSlot

  -- BPM fader gesture state. Set on shift+S2 press, cleared on S2
  -- release. While held, the encoder routes to BPM nudge instead of
  -- focus-head scroll / selection extend / etc.
  self.bpmHeld  = false
  self.bpmAccum = 0

  -- Active grid layer: "L1" shows L1 cell values (per-column formatters);
  -- "L2" shows compact pred:action rules from the L2 grammar layer.
  -- Toggled via shift+S3 (with shift-overlay label "L2" / "L1" on S3).
  -- Phase 1 is read-only on L2: ENTER, shift+encoder selection, paste,
  -- and bulk ops are blocked while layer == "L2". Marking, transport,
  -- and scroll work on both layers since they're layer-agnostic.
  self.layer = "L1"

  -- Mark-start / mark-end modal state. Idle outside the modal; while
  -- "marking_end" the S2 ply reads "end" and every focusHead change
  -- live-updates marker2 on the active column so the loop dim moves
  -- with the user's intent. First S2 press snapshots the pre-marking
  -- (m1, m2) pair into markBackup so CANCEL can restore. Second S2
  -- press (or UP, ENTER, M-key) commits the normalized (lo, hi) pair
  -- and clears the snapshot.
  self.markingMode    = "idle"  -- or "marking_end"
  self.markBackup     = nil     -- {col, m1, m2} of pre-marking state
  self.markFirstMark  = nil     -- absolute row of the committed first mark

  -- ---- sub display: slot label + transport state + softkeys ----

  self.titleLabel = app.Label("seq1", 12)
  self.titleLabel:setPosition(2, app.GRID4_LINE1)
  self.titleLabel:setJustification(app.justifyLeft)
  self:addSubGraphic(self.titleLabel)

  self.statusLabel = app.Label("stopped", kFontSub)
  self.statusLabel:setPosition(2, app.GRID4_LINE2)
  self.statusLabel:setJustification(app.justifyLeft)
  self:addSubGraphic(self.statusLabel)

  self.bpmLabel = app.Label("BPM 120", kFontSub)
  self.bpmLabel:setPosition(2, app.GRID4_LINE3)
  self.bpmLabel:setJustification(app.justifyLeft)
  self:addSubGraphic(self.bpmLabel)

  -- Shift-held preview overlay. Empty when shift is not held. While
  -- held: shows the clipboard contents (when occupied), otherwise
  -- shows the current L2 cell's expanded rule when on L2 and the
  -- cell is present. Positioned centered between the S2 and S3 sub
  -- plies horizontally, mid-vertical, so it doesn't crowd the title
  -- / status / BPM labels stacked along the left.
  self.previewLabel = app.Label("", kFontSub)
  self.previewLabel:setJustification(app.justifyCenter)
  self.previewLabel:setCenter(
    (app.BUTTON2_CENTER + app.BUTTON3_CENTER) // 2,
    app.GRID4_LINE2)
  self:addSubGraphic(self.previewLabel)

  -- Edit-step indicator (FINE / COARSE / SUPER FINE / SUPER COARSE).
  -- Blank when not editing.
  self.editStepLabel = app.Label("", kFontSub)
  self.editStepLabel:setPosition(60, app.GRID4_LINE2)
  self.editStepLabel:setJustification(app.justifyLeft)
  self:addSubGraphic(self.editStepLabel)

  -- Sub-display soft buttons. Texts swap between two modes via
  -- refresh(): default (start/stop, S2 empty, reset) and selection
  -- (copy / cut / rand). Action dispatch happens in subReleased().
  self.s1Button = app.SubButton("start", 1)
  self:addSubGraphic(self.s1Button)
  self.s2Button = app.SubButton("", 2)
  self:addSubGraphic(self.s2Button)
  self.s3Button = app.SubButton("reset", 3)
  self:addSubGraphic(self.s3Button)

  -- Global transport state shadow. S1 toggles all four slots in
  -- lockstep: the user mutes individual slots chain-side (by muting
  -- the chain that consumes seq*.cv1 etc.) rather than per-slot
  -- transport here. Avoids needing a separate per-slot reset / CV
  -- input scheme to recover from divergent states.
  self.running = false
  -- Per-frame refresh callback. Re-set on each onShow so the closure
  -- captures `self`; cleared on onHide via Signal.remove.
  self.frameCallback = nil
end

-- Hardcoded for v0.1; matches kMaxStepsPerColumn in od/sequencer/Sequencer.h.
-- Encoder-driven focus head clamps to this for now.
local kMaxRow = 63

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Brightness ramp (4bpp display, 0=black .. 15=white). Modelled on
-- monome/teletype's pattern_mode.c (dim=1, normal=6, playhead=11,
-- selected=15), with dim bumped to 3 for legibility and a focus-only
-- level inserted between normal and playhead.
local kBrightDim       = 3   -- out-of-loop cells
local kBrightNormal    = 6   -- in-loop cells, no focus or playhead
local kBrightFocus     = 9   -- focus head row, not playhead
local kBrightPlayhead  = 11  -- playhead row of a column, not focus
local kBrightBoth      = 15  -- focus row && that column's playhead row

-- Header brightness: inactive column muted, active column at full.
local kHeaderInactive  = 6
local kHeaderActive    = 15

-- Encoder accumulator: same threshold the rest of the firmware uses for
-- "list step" semantics, so the sequencer scroll feels consistent with
-- ScopeView / ListWindow / unit editors. Each `kEncoderThreshold` ticks
-- of physical encoder rotation advances the focus head one row.
local kEncoderThreshold = Env.EncoderThreshold.Default

-- Per-column nudge step when editing an L1 cell value. Each column
-- declares 4 step sizes covering the rate ramp: fine, coarse, and the
-- "super" variants of each (shift held). Tuned for musical units per
-- column type:
--   CV1 (V/oct):    1 semi  / 1 oct  / 1 cent  / 12 oct
--   CV2, CV3:       100 mV  / 1 V    / 10 mV   / 10 V
--   gate-len:       1/16   / 1/4    / 1/64    / 1 beat (fractional)
--   gate-amp:       5%     / 20%    / 1.25%   / 80%
--   step-len:       1 tick / 4 ticks / 1 tick / 16 ticks (integer ticks
--                   only -- the engine's 4 PPQN base means 1 tick = 1/16
--                   note = 0.25 beats; sub-tick steps would land off-
--                   grid and read as ugly decimals in the column, so
--                   super-fine matches fine.)
local kColumnSteps = {
  [0] = { fine = 1/12,   coarse = 1.0,    superFine = 1/120,  superCoarse = 12.0 },
  [1] = { fine = 0.1,    coarse = 1.0,    superFine = 0.01,   superCoarse = 10.0 },
  [2] = { fine = 0.1,    coarse = 1.0,    superFine = 0.01,   superCoarse = 10.0 },
  [3] = { fine = 0.0625, coarse = 0.25,   superFine = 0.0156, superCoarse = 1.0  },
  [4] = { fine = 0.05,   coarse = 0.2,    superFine = 0.0125, superCoarse = 0.8  },
  [5] = { fine = 0.25,   coarse = 1.0,    superFine = 0.25,   superCoarse = 4.0  },
}

-- Dial button toggles "fine" <-> "coarse"; shift held picks the
-- corresponding "super" variant. The dial state is per-view, the shift
-- state is implicit on each encoder event.
local function stepForColumn(col, editStepMode, shifted)
  local cfg = kColumnSteps[col] or kColumnSteps[1]
  if editStepMode == "coarse" then
    return shifted and cfg.superCoarse or cfg.coarse
  end
  return shifted and cfg.superFine or cfg.fine
end

local function cellBrightness(isPlayhead, isFocus, inLoop)
  if isPlayhead and isFocus then return kBrightBoth end
  if isPlayhead            then return kBrightPlayhead end
  if isFocus               then return kBrightFocus end
  if inLoop                then return kBrightNormal end
  return kBrightDim
end

-- Dotted-rectangle builder for the selection box. Emits multiple short
-- solid hline/vline segments through app.DrawingInstructions to
-- approximate dotting; the lower-level FrameBuffer.hline supports a
-- proper `dotting` arg but DrawingInstructions doesn't expose it.
local kDotOn     = 2   -- pixels lit per dot
local kDotOff    = 2   -- pixels off between dots
local kDotPeriod = kDotOn + kDotOff

-- Cursor-box easing factor (per-refresh lerp toward target). At 55 Hz
-- refresh, 0.4 converges to ~95% in 6 frames (~110 ms), making row /
-- column transitions visibly slide rather than snap. Snaps the final
-- pixel when within kCursorSnapEps to avoid sub-pixel oscillation.
local kCursorEase    = 0.4
local kCursorSnapEps = 0.5

-- Discontinuous-jump threshold on cursor Y. The cursor's target Y
-- moves smoothly with subPx during a scroll transition (~1.8 px per
-- frame at 0.2 scroll lerp). A frame-over-frame target delta larger
-- than this means the cursor has jumped to a different visible row
-- in a single step (boundary scroll near row 0 / kMaxRow), which we
-- want to ease through.
local kCursorJumpPx  = 5

-- Smooth-scroll constants. Lerp factor is scaled UP from the
-- firmware exponential-lerp standard (0.2, in MondrianList.cpp:99
-- / SpottedStrip.cpp:37 / ChainOverview.cpp:458) so that the initial
-- per-frame *pixel* velocity is equivalent. Those lists use row
-- pitches around 18-22 px, giving initial velocity 0.2 * ~20 ~= 4
-- px/frame. Our grid row is 9 px; matching that absolute velocity
-- requires lerp ~= 4/9 ~= 0.44, rounded to 0.4 (initial velocity
-- 3.6 px/frame). Snap at 1 px keeps the final settle ~< 1 px, also
-- tightened from firmware's 2 px because of the same row-pitch
-- ratio (2 px snap on a 9 px row would be a visibly bumpy 22%-of-a-row
-- settle vs. ~6% on a typical Mondrian row).
local kScrollLerp     = 0.4
local kScrollSnapRows = 1 / kRowHeight

-- Cells slide upward (toward the header) as scrollFrac increases. A
-- cell whose Y exceeds this threshold has its glyph overlapping the
-- header strip and is hidden until the next integer scroll position
-- moves it out of view entirely. = kHeaderY - kRowHeight + 1 = 45.
local kCellHideY      = kHeaderY - kRowHeight + 1

-- Dirty-cell indicator geometry: a small filled dot at the right edge
-- of an edited cell. dotX is the column-relative x offset; dot is 2x2
-- pixels at the vertical middle of the row's text glyph.
local kDirtyDotW    = 2
local kDirtyDotH    = 2
local kDirtyDotXOff = 38           -- right edge of column (column ends at 42)

-- L2 fire-indicator dot: same size + right-edge position as the L1
-- dirty dot, since L1 / L2 are mutually-exclusive views (only one of
-- the two dot kinds renders at a time). Decay window in frames at
-- 55 Hz; 10 frames is ~180 ms, fast enough to read as a tick-paced
-- blink at typical 4-8 Hz engine rates.
local kFireDotW        = 2
local kFireDotH        = 2
local kFireDotXOff     = kDirtyDotXOff   -- right edge of column
local kFireDecayFrames = 10

-- Single-slot ephemeral clipboard for L1 row-range selections. Stored
-- as { col = integer, values = {float, float, ...} }. Module-local
-- so it persists across GridView reopens during one session but does
-- NOT persist across patch save/restore (per the plan's "ephemeral"
-- decision). PASTE is a follow-up; for now this is consumed by COPY/
-- CUT only -- nothing reads it back yet.
local clipboard = nil

-- Column type categories for cross-column PASTE compatibility.
-- Paste refuses when source and destination columns fall in different
-- categories. Note that V/oct (col 0) is treated as "cv" alongside the
-- raw-voltage CV columns: a V/oct clipboard pasted into a raw CV2/CV3
-- column reinterprets the same float as volts, which is musically
-- defensible (semitones become a step pattern in V), so the plan
-- allows it. The strict-same-column policy is a future opt-in.
local function columnCategory(col)
  if col == 0 or col == 1 or col == 2 then return "cv"   end
  if col == 3 or col == 5             then return "time" end
  if col == 4                         then return "amp"  end
  return "unknown"
end

-- Render a compact text view of the current clipboard for the
-- shift-held preview overlay. L1 form: "<col>: v1 v2 v3 ..".
-- L2 form: "<col> L2: N rules" (sparse contents don't fit cleanly
-- in one line; full inspection happens via the modal). Returns "".
-- when clipboard is empty.
local function clipboardPreviewText()
  if not clipboard then return "" end
  local letter = (clipboard.col and (kColLetters[clipboard.col + 1])) or "?"
  if clipboard.layer == "L2" then
    local n = 0
    for _ in pairs(clipboard.cells or {}) do n = n + 1 end
    return string.format("%s L2: %d rule%s", letter, n, n == 1 and "" or "s")
  end
  if not clipboard.values then return "" end
  local s = letter .. ":"
  local n = math.min(5, #clipboard.values)
  for i = 1, n do
    s = s .. " " .. ((clipboard.values[i] == math.floor(clipboard.values[i]))
                       and tostring(math.floor(clipboard.values[i]))
                       or string.format("%.1f", clipboard.values[i]))
  end
  if #clipboard.values > n then s = s .. " .." end
  return s
end

-- Per-column random value generator for the RANDOMIZE action. The
-- distributions match the column's typed range so randomized values
-- look musically sensible: ±5 octaves for V/oct, ±5 V for raw CV,
-- common-fraction beats for length columns, 0..1 amplitude for gates.
local kRandomBeats = { 0.0625, 0.125, 0.25, 0.5, 1.0, 2.0, 4.0 }
-- Step-len draws from integer-tick multiples only. 1 tick = 0.25 beats
-- at the engine's 4 PPQN. Choices map to 1, 2, 4, 8, 16, 32 ticks --
-- i.e. 1/16, 1/8, 1/4, 1/2, whole, double-whole notes.
local kRandomStepTicks = { 1, 2, 4, 8, 16, 32 }
local function randomForColumn(col)
  if col == 0 then
    -- CV1 (V/oct): random semitone in -60..+60 (5 octaves each way).
    return math.random(-60, 60) / 12.0
  elseif col == 1 or col == 2 then
    -- CV2 / CV3: -5..+5 V, 0.1 V resolution.
    return math.random(-50, 50) / 10.0
  elseif col == 3 then
    -- gate-len: draw from the common-fraction set (fractional beats
    -- allowed for envelope duration -- sub-tick is fine here).
    return kRandomBeats[math.random(1, #kRandomBeats)]
  elseif col == 5 then
    -- step-len: integer tick count converted back to beats.
    return kRandomStepTicks[math.random(1, #kRandomStepTicks)] * 0.25
  elseif col == 4 then
    -- gate-amp: 0..1, 0.05 step.
    return math.random(0, 20) / 20.0
  end
  return 0.0
end

local function buildDottedRect(instr, x, y, w, h, color)
  instr:clear()
  instr:color(color)
  local xEnd = x + w - 1
  local yEnd = y + h - 1
  for px = x, xEnd, kDotPeriod do
    local px2 = math.min(px + kDotOn - 1, xEnd)
    instr:hline(px, px2, y)      -- bottom
    instr:hline(px, px2, yEnd)   -- top
  end
  for py = y, yEnd, kDotPeriod do
    local py2 = math.min(py + kDotOn - 1, yEnd)
    instr:vline(x,    py, py2)   -- left
    instr:vline(xEnd, py, py2)   -- right
  end
end

function GridView:refresh()
  local seq = app.AudioThread.getSequencerTask()
  if not seq then return end

  -- Smooth-scroll target: focus head sits at the 3rd visible row
  -- when not at row-range boundaries. scrollFrac eases at 0.2 toward
  -- this target each refresh; subPx is the fractional remainder in
  -- pixels, used to slide every row position vertically during
  -- transitions. HOME / boundary jumps trigger longer eases (the
  -- target moves by multiple rows in one focusHead update).
  --
  -- Scroll only follows focusHeadRow. The playhead may be inside or
  -- outside the visible window; auto-follow-playhead is intentionally
  -- NOT here -- it would conflict with the user's view-selection
  -- intent.
  local targetStart = clamp(self.focusHeadRow - 2, 0,
                            kMaxRow - kVisibleRows + 1)
  if self.scrollFrac == nil then
    self.scrollFrac = targetStart
  else
    self.scrollFrac = self.scrollFrac * (1 - kScrollLerp)
                       + targetStart * kScrollLerp
    if math.abs(self.scrollFrac - targetStart) < kScrollSnapRows then
      self.scrollFrac = targetStart
    end
  end
  local startRow = math.floor(self.scrollFrac)
  local subPx    = (self.scrollFrac - startRow) * kRowHeight

  -- Resolve cursor / box geometry once so the ruler-hide pass and the
  -- cursor / dotted-box render paths below share a single source of
  -- truth. cursorRow / cursorCol mark the active-edit target (=
  -- focusHead by default; selection master when selecting; moving end
  -- when marking). boxLo / boxHi / boxCol describe the active dotted
  -- range (selection or mark modal); nil when no box is active.
  local cursorRow, cursorCol
  local boxLo, boxHi, boxCol
  if self.selectionActive and self.selectionColumn == self.columnCursor then
    cursorRow = math.min(self.selectionAnchor, self.selectionEnd)
    cursorCol = self.selectionColumn
    boxLo     = cursorRow
    boxHi     = math.max(self.selectionAnchor, self.selectionEnd)
    boxCol    = self.selectionColumn
  elseif self.markingMode == "marking_end"
         and self.markBackup
         and self.markBackup.col == self.columnCursor then
    cursorRow = self.focusHeadRow
    cursorCol = self.markBackup.col
    boxLo     = math.min(self.markFirstMark, self.focusHeadRow)
    boxHi     = math.max(self.markFirstMark, self.focusHeadRow)
    boxCol    = self.markBackup.col
  else
    cursorRow = self.focusHeadRow
    cursorCol = self.columnCursor
  end

  -- Ruler-suppression set: rows whose digits would be visually cut by
  -- a cursor border or dotted box on the LAST column (where the box's
  -- right edge crosses into ruler-text territory at x ~= 251). Off-
  -- screen rows end up hidden anyway, so marking them here is a no-op.
  local rulerHidden = {}
  if cursorCol == kNumColumns - 1 then
    rulerHidden[cursorRow] = true
  end
  if boxCol == kNumColumns - 1 then
    for r = boxLo, boxHi do rulerHidden[r] = true end
  end

  for c = 1, kNumColumns do
    local col = c - 1
    local playhead = seq:playhead(self.slot, col)
    local m1 = seq:marker1(self.slot, col)
    local m2 = seq:marker2(self.slot, col)
    local loopLo, loopHi = math.min(m1, m2), math.max(m1, m2)

    self.headerLabels[c]:setText(string.format("%s:%02d", kColNames[c], playhead))
    self.headerLabels[c]:setForegroundColor(
      (col == self.columnCursor) and kHeaderActive or kHeaderInactive)

    for r = 1, kVisibleRows + 1 do
      local absRow = startRow + r - 1
      local y = kHeaderY - r * kRowHeight + subPx
      local lbl = self.cellLabels[c][r]
      if y > kCellHideY or absRow > kMaxRow or absRow < 0 then
        lbl:hide()
      else
        lbl:setPosition((c - 1) * kColPly + 2, math.floor(y + 0.5))
        local inLoop     = absRow >= loopLo and absRow <= loopHi
        local isFocus    = absRow == self.focusHeadRow
        local isPlayhead = absRow == playhead
        local text
        if self.layer == "L2" then
          text = fmtL2Cell(
            seq:l2PredOp(self.slot, col, absRow),
            seq:l2PredColA(self.slot, col, absRow),
            seq:l2PredColARow(self.slot, col, absRow),
            seq:l2PredVal(self.slot, col, absRow),
            seq:l2ActOp(self.slot, col, absRow),
            seq:l2ActTgt(self.slot, col, absRow),
            seq:l2ActTgtRow(self.slot, col, absRow),
            seq:l2ActVal(self.slot, col, absRow))
        else
          text = fmtCellByCol(col, seq:l1Value(self.slot, col, absRow))
        end
        lbl:setText(text)
        lbl:setForegroundColor(cellBrightness(isPlayhead, isFocus, inLoop))
        lbl:show()
      end
    end
  end

  -- Row ruler: absolute row numbers for the visible window, brightened
  -- on the focus row. Same slot count + Y formula as the cell grid.
  -- Rows in `rulerHidden` (any row a last-column cursor or dotted box
  -- crosses through) suppress their digits so the box edge doesn't
  -- visually clip into the ruler.
  for r = 1, kVisibleRows + 1 do
    local absRow = startRow + r - 1
    local y = kHeaderY - r * kRowHeight + subPx
    local lbl = self.rulerLabels[r]
    if y > kCellHideY or absRow > kMaxRow or absRow < 0
       or rulerHidden[absRow] then
      lbl:hide()
    else
      lbl:setPosition(kRulerX, math.floor(y + 0.5))
      lbl:setText(string.format("%02d", absRow))
      lbl:setForegroundColor(
        (absRow == self.focusHeadRow) and kBrightBoth or kBrightNormal)
      lbl:show()
    end
  end

  -- Cursor box: outline the cell at the "active edit target."
  --   nav / edit mode:        focusHeadRow on columnCursor.
  --   selection active:       master row = top of selection (=
  --                            min(anchor, end)) on selectionColumn.
  --                            This is the cell whose value bulk edit
  --                            increments; the rest of the selection
  --                            snaps to it (Chunk B).
  --   marking active:         moving end (focusHead) on mark column.
  -- Color: WHITE while editing / selecting / marking (so the user sees
  -- that the next encoder turn will mutate state). GRAY10 otherwise.
  -- cursorRow / cursorCol are resolved at the top of refresh.
  local visibleRow = cursorRow - startRow + 1
  local labelY = kHeaderY - visibleRow * kRowHeight + subPx
  local targetY = labelY + 3
  if visibleRow >= 1 and visibleRow <= kVisibleRows + 1
     and targetY <= kCellHideY + 3 then
    local targetX = cursorCol * kColPly
    -- X easing: column changes (M-key) jump the cursor by 42 px in
    -- a single frame; ease toward the new column.
    if self.cursorAnimX == nil then
      self.cursorAnimX = targetX
    else
      self.cursorAnimX = self.cursorAnimX + (targetX - self.cursorAnimX) * kCursorEase
      if math.abs(self.cursorAnimX - targetX) < kCursorSnapEps then
        self.cursorAnimX = targetX
      end
    end
    -- Y handling: during a smooth scroll, targetY changes by ~1.8 px
    -- per frame (subPx motion), so snapping to it keeps the cursor
    -- glued to the focus row as the data slides. Boundary scrolls
    -- (focusHead near 0 or kMaxRow, scrollFrac clamped) advance
    -- visibleRow by 1 in a single frame -- a ~9 px jump in targetY,
    -- which we detect and ease through.
    if self.cursorAnimY == nil then
      self.cursorAnimY = targetY
      self.cursorEasingY = false
    else
      local delta = targetY - self.cursorAnimY
      if math.abs(delta) > kCursorJumpPx then
        self.cursorEasingY = true
      end
      if self.cursorEasingY then
        self.cursorAnimY = self.cursorAnimY + delta * kCursorEase
        if math.abs(self.cursorAnimY - targetY) < kCursorSnapEps then
          self.cursorAnimY = targetY
          self.cursorEasingY = false
        end
      else
        self.cursorAnimY = targetY
      end
    end
    self.cursorBox:setPosition(
      math.floor(self.cursorAnimX + 0.5),
      math.floor(self.cursorAnimY + 0.5))
    local active = self.editingL1 or self.selectionActive
                    or self.markingMode == "marking_end"
    self.cursorBox:setBorderColor(active and app.WHITE or app.GRAY10)
    self.cursorBox:show()
  else
    self.cursorBox:hide()
    -- Reset easing so next show snaps rather than animating in from
    -- the cursor's last on-screen position.
    self.cursorAnimX   = nil
    self.cursorAnimY   = nil
    self.cursorEasingY = false
  end

  -- Selection / mark dotted box. boxLo / boxHi / boxCol are resolved
  -- at the top of refresh from the same source state used by the
  -- cursor + ruler-hide passes. Two gestures feed this drawing:
  --   * selection active on the cursor's column -> wrap selection range
  --   * mark modal on the cursor's column       -> wrap (firstMark..focusHead)
  -- Both share the same dotted-edge primitive so the visual language is
  -- consistent across "user-defined row range" gestures. Position rides
  -- on subPx so the box slides with the cells it wraps during smooth
  -- scroll.
  if boxCol then
    -- Clip to visible window (now including the +1 partial-bottom row).
    local topV    = math.max(1,                boxLo - startRow + 1)
    local bottomV = math.min(kVisibleRows + 1, boxHi - startRow + 1)
    if topV <= bottomV then
      local topLabelY    = kHeaderY - topV    * kRowHeight + subPx
      local bottomLabelY = kHeaderY - bottomV * kRowHeight + subPx
      local selX = boxCol * kColPly
      local selY = math.floor(bottomLabelY + 3 + 0.5)
      local selH = (bottomV - topV) * kRowHeight + 10
      buildDottedRect(self.selectionInstr, selX, selY, kColPly, selH, app.GRAY10)
      self.selectionDrawing:show()
    else
      self.selectionDrawing:hide()
    end
  else
    self.selectionDrawing:hide()
  end

  -- Dirty-cell indicators: small dot at the right edge of every cell
  -- in `editedCells` whose row currently falls in the visible window.
  -- Drawing is rebuilt from scratch each refresh -- the dirty set
  -- changes only on encoder ticks during a bulk edit, so paying the
  -- full rebuild at 55 Hz is cheap (usually nothing to draw). Position
  -- rides on subPx so the dots slide with their owning cells.
  self.dirtyInstr:clear()
  local anyDirty = false
  for col, rowSet in pairs(self.editedCells) do
    for absRow, _ in pairs(rowSet) do
      local visR = absRow - startRow + 1
      if visR >= 1 and visR <= kVisibleRows + 1 then
        local labelY = kHeaderY - visR * kRowHeight + subPx
        if labelY <= kCellHideY then
          if not anyDirty then
            self.dirtyInstr:color(app.WHITE)
            anyDirty = true
          end
          local dotX = col * kColPly + kDirtyDotXOff
          local dotY = math.floor(labelY + 6 + 0.5)
          self.dirtyInstr:fill(dotX, dotY, kDirtyDotW, kDirtyDotH)
        end
      end
    end
  end
  if anyDirty then
    self.dirtyDrawing:show()
  else
    self.dirtyDrawing:hide()
  end

  -- L2 fire indicator. Only relevant on the L2 layer. For each column,
  -- compare the engine's lastL2FiredRow to our last-seen value; when
  -- they differ, a new firing happened -- start a fresh decay window
  -- on (col, row). Each refresh, decrement framesLeft; render a small
  -- dot on the left edge of any column whose decay is still active.
  self.l2FireInstr:clear()
  local anyFire = false
  if self.layer == "L2" then
    for col = 0, kNumColumns - 1 do
      -- Detect new fires via the engine's monotonic fire serial so
      -- same-row repeats (e.g. a %3 rule on a single cell) still
      -- register as fresh events. lastL2FiredRow is read alongside
      -- to know WHICH row to draw the dot on.
      local engineSerial = seq:l2FireSerial(self.slot, col)
      local engineRow    = seq:l2LastFiredRow(self.slot, col)
      if engineSerial ~= (self.l2FireLastSerial[col] or 0)
         and engineRow >= 0 then
        self.l2FireDecay[col] = { row = engineRow, framesLeft = kFireDecayFrames }
      end
      self.l2FireLastSerial[col] = engineSerial
      local d = self.l2FireDecay[col]
      if d and d.framesLeft > 0 then
        local visR = d.row - startRow + 1
        if visR >= 1 and visR <= kVisibleRows + 1 then
          local labelY = kHeaderY - visR * kRowHeight + subPx
          if labelY <= kCellHideY then
            if not anyFire then
              self.l2FireInstr:color(app.WHITE)
              anyFire = true
            end
            local dotX = col * kColPly + kFireDotXOff
            local dotY = math.floor(labelY + 6 + 0.5)
            self.l2FireInstr:fill(dotX, dotY, kFireDotW, kFireDotH)
          end
        end
        d.framesLeft = d.framesLeft - 1
      end
    end
  end
  if anyFire then
    self.l2FireDrawing:show()
  else
    self.l2FireDrawing:hide()
  end

  self.bpmLabel:setText(string.format("BPM %d", math.floor(seq:getBpm() + 0.5)))
  -- Persistent layer indicator: "seq1.L1" or "seq1.L2" on the sub
  -- title line, so the user always knows which layer the grid view
  -- is showing without having to hold shift. Status mirrors the
  -- selected slot's running shadow so slot-switching updates it.
  self.titleLabel:setText(string.format("seq%d.%s", self.slot + 1, self.layer))
  self.statusLabel:setText(self.running and "running" or "stopped")
  self.slotIndicator:setText(string.format("S%d", self.slot + 1))

  -- Shift-held preview overlay: clipboard preview wins (paste-target
  -- preview), else current L2 cell expanded when on L2 with a present
  -- cell. Hidden when shift is not held or in a modal / selection.
  local previewText = ""
  if app.isShiftButtonPushed()
     and not self.selectionActive
     and not self.editingL1
     and self.markingMode == "idle"
     and not self.bpmHeld then
    if clipboard then
      previewText = "clip " .. clipboardPreviewText()
    elseif self.layer == "L2"
           and seq:l2Present(self.slot, self.columnCursor, self.focusHeadRow) then
      previewText = "here " .. fmtL2CellFull(
        seq:l2PredOp(self.slot, self.columnCursor, self.focusHeadRow),
        seq:l2PredColA(self.slot, self.columnCursor, self.focusHeadRow),
        seq:l2PredColARow(self.slot, self.columnCursor, self.focusHeadRow),
        seq:l2PredVal(self.slot, self.columnCursor, self.focusHeadRow),
        seq:l2ActOp(self.slot, self.columnCursor, self.focusHeadRow),
        seq:l2ActTgt(self.slot, self.columnCursor, self.focusHeadRow),
        seq:l2ActTgtRow(self.slot, self.columnCursor, self.focusHeadRow),
        seq:l2ActVal(self.slot, self.columnCursor, self.focusHeadRow),
        self.columnCursor)
    end
  end
  self.previewLabel:setText(previewText)

  -- Edit-step indicator. Shown only while in edit mode.
  if self.editingL1 then
    self.editStepLabel:setText(self.editStepMode == "coarse" and "COARSE" or "FINE")
  else
    self.editStepLabel:setText("")
  end

  -- Sub softkey labels. Modes checked in priority order:
  --   1. selection active     -> copy / cut / rand
  --   2. mark modal           -> start|stop / end / _
  --   3. shift held (default) -> S1 = paste (clipboard non-empty),
  --                              S2 / S3 reserved for future overlays
  --   4. default              -> start|stop / mark / L1<->L2 toggle
  -- The shift-overlay polls the hardware shift state each refresh
  -- (55 Hz), so labels swap responsively as the user holds / releases
  -- shift. Selection takes priority over everything -- once a
  -- selection is built, shift / mark gestures don't reach the bar.
  --
  -- Layer toggle lives on UNSHIFTED S3: the bar always shows the
  -- OTHER layer's name ("L2" while on L1, "L1" while on L2), so the
  -- gesture is discoverable without holding shift first.
  local otherLayer = (self.layer == "L1") and "L2" or "L1"
  if self.selectionActive then
    self.s1Button:setText("copy")
    self.s2Button:setText("cut")
    self.s3Button:setText("rand")
  elseif self.markingMode == "marking_end" then
    self.s1Button:setText(self.running and "stop" or "start")
    self.s2Button:setText("end")
    self.s3Button:setText("")
  elseif app.isShiftButtonPushed() then
    self.s1Button:setText(clipboard ~= nil and "paste" or "")
    self.s2Button:setText("BPM")
    self.s3Button:setText(otherLayer)
  else
    self.s1Button:setText(self.running and "stop" or "start")
    self.s2Button:setText("mark")
    self.s3Button:setText(otherLayer)
  end
end

function GridView:onShow()
  -- Per-display-frame refresh (55 Hz). Bypasses Timer.every which is
  -- throttled to ~5 Hz internally and would cause the playhead to
  -- visibly skip rows at any engine tick rate above ~5 Hz.
  -- Reset cursor + scroll easing so the first frame snaps to the
  -- current target rather than animating in from the previous
  -- session's last on-screen position.
  self.cursorAnimX   = nil
  self.cursorAnimY   = nil
  self.cursorEasingY = false
  self.scrollFrac    = nil
  self.frameCallback = function() self:refresh() end
  Signal.register("onDisplayFrame", self.frameCallback)
  self:refresh()
end

function GridView:onHide()
  if self.frameCallback then
    Signal.remove("onDisplayFrame", self.frameCallback)
    self.frameCallback = nil
  end
end

-- ---- input handlers ----

-- Mark-mode helpers. All three are no-ops when markingMode != "marking_end".
-- _updateMarkingLive: write (markFirstMark, focusHead) to the engine each
--                     time focusHead changes so the loop dim slides live.
-- _commitMark:        normalize the in-flight pair to (lo, hi) and write
--                     it, then exit the modal.
-- _revertMark:        restore the pre-marking (m1, m2) snapshot and exit.
function GridView:_updateMarkingLive()
  if self.markingMode ~= "marking_end" then return end
  local seq = app.AudioThread.getSequencerTask()
  if not (seq and self.markBackup) then return end
  -- Engine normalizes the loop region to min/max internally, so we can
  -- pass them in user-intended order during the live phase.
  seq:setMarkers(self.slot, self.markBackup.col,
                 self.markFirstMark, self.focusHeadRow)
end

function GridView:_commitMark()
  if self.markingMode ~= "marking_end" then return end
  local seq = app.AudioThread.getSequencerTask()
  if seq and self.markBackup then
    local lo = math.min(self.markFirstMark, self.focusHeadRow)
    local hi = math.max(self.markFirstMark, self.focusHeadRow)
    seq:setMarkers(self.slot, self.markBackup.col, lo, hi)
  end
  self.markingMode   = "idle"
  self.markBackup    = nil
  self.markFirstMark = nil
end

function GridView:_revertMark()
  if self.markingMode ~= "marking_end" then return end
  local seq = app.AudioThread.getSequencerTask()
  if seq and self.markBackup then
    seq:setMarkers(self.slot, self.markBackup.col,
                   self.markBackup.m1, self.markBackup.m2)
  end
  self.markingMode   = "idle"
  self.markBackup    = nil
  self.markFirstMark = nil
end

-- Paste clipboard.values into rows starting at focusHead, in the
-- user's current column. Refuses silently on type mismatch (clipboard
-- column category != destination column category). focusHead advances
-- past the pasted region so chained pastes stitch contiguously; if the
-- paste would run past kMaxRow it truncates at the boundary.
function GridView:_pasteAtFocus()
  if clipboard == nil then return false end
  local seq = app.AudioThread.getSequencerTask()
  if not seq then return false end
  -- Cross-layer paste refuses (clipboard layer must match current).
  if clipboard.layer ~= self.layer then return false end

  local startR = self.focusHeadRow

  if clipboard.layer == "L1" then
    -- Type-checked by column category so a CV clipboard doesn't
    -- silently paste into a time column.
    if columnCategory(clipboard.col) ~= columnCategory(self.columnCursor) then
      return false
    end
    local n = #clipboard.values
    for i, v in ipairs(clipboard.values) do
      local r = startR + i - 1
      if r > kMaxRow then break end
      seq:setL1(self.slot, self.columnCursor, r, v)
    end
    self.focusHeadRow = clamp(startR + n, 0, kMaxRow)
  else
    -- L2 paste: sparse map keyed by row offset relative to selMin
    -- at capture time. Reproduce the same sparse pattern starting
    -- at the current focusHead. Advances focusHead past the highest
    -- offset committed so consecutive pastes stitch contiguously.
    local maxOffset = -1
    for off, cell in pairs(clipboard.cells or {}) do
      local r = startR + off
      if r > kMaxRow then
        -- Skip cells that fall past the column max.
      else
        seq:setL2(self.slot, self.columnCursor, r,
                  cell.predOp,
                  cell.predColA, cell.predColARow,
                  cell.predVal,
                  cell.actOp,
                  cell.actTgt, cell.actTgtRow,
                  cell.actVal)
        if off > maxOffset then maxOffset = off end
      end
    end
    if maxOffset >= 0 then
      self.focusHeadRow = clamp(startR + maxOffset + 1, 0, kMaxRow)
    end
  end

  self:refresh()
  return true
end

-- subPressed: captures shift+S2 to enter BPM-nudge mode. While S2
-- stays held, encoder routes to BPM regardless of shift state on
-- the encoder gesture itself; release of S2 (any shift state) drops
-- out. The press is otherwise a no-op so the rest of the sub stack
-- (paste, mark, layer toggle) sees nothing.
function GridView:subPressed(i, shifted)
  if i == 2 and shifted then
    self.bpmHeld  = true
    self.bpmAccum = 0
    self:refresh()
    return true
  end
  return false
end

function GridView:subReleased(i, shifted)
  -- BPM release: claim regardless of shift state, since the press
  -- could have been shifted but release after shift was let go.
  if i == 2 and self.bpmHeld then
    self.bpmHeld  = false
    self.bpmAccum = 0
    self:refresh()
    return true
  end

  local seq = app.AudioThread.getSequencerTask()
  if not seq then return false end

  -- Selection-mode sub buttons (copy / cut / rand). All three commit
  -- any in-flight bulk edit implicitly: editedCells + preEditValues
  -- are dropped (values stay as-is in the engine) and the selection
  -- collapses. The action itself sees the post-bulk-edit values.
  if self.selectionActive then
    local selMin = math.min(self.selectionAnchor, self.selectionEnd)
    local selMax = math.max(self.selectionAnchor, self.selectionEnd)
    local col    = self.selectionColumn
    if self.layer == "L1" then
      -- L1: clipboard stores dense array of cell values.
      if i == 1 then
        local values = {}
        for r = selMin, selMax do
          values[#values + 1] = seq:l1Value(self.slot, col, r)
        end
        clipboard = { layer = "L1", col = col, values = values }
      elseif i == 2 then
        local values = {}
        for r = selMin, selMax do
          values[#values + 1] = seq:l1Value(self.slot, col, r)
          seq:setL1(self.slot, col, r, 0.0)
        end
        clipboard = { layer = "L1", col = col, values = values }
      elseif i == 3 then
        for r = selMin, selMax do
          seq:setL1(self.slot, col, r, randomForColumn(col))
        end
      else
        return false
      end
    else
      -- L2: clipboard stores sparse map of L2 rule tuples keyed by
      -- offset from selMin so paste can reproduce the same sparse
      -- pattern at a new focusHead. Random L2 is deferred to the
      -- coherent-randomization sub-item; unconstrained random L2
      -- rules don't produce musically useful output.
      if i == 1 then
        local cells = {}
        for r = selMin, selMax do
          if seq:l2Present(self.slot, col, r) then
            cells[r - selMin] = {
              predOp      = seq:l2PredOp(self.slot, col, r),
              predColA    = seq:l2PredColA(self.slot, col, r),
              predColARow = seq:l2PredColARow(self.slot, col, r),
              predVal     = seq:l2PredVal(self.slot, col, r),
              actOp       = seq:l2ActOp(self.slot, col, r),
              actTgt      = seq:l2ActTgt(self.slot, col, r),
              actTgtRow   = seq:l2ActTgtRow(self.slot, col, r),
              actVal      = seq:l2ActVal(self.slot, col, r),
            }
          end
        end
        clipboard = { layer = "L2", col = col, cells = cells }
      elseif i == 2 then
        local cells = {}
        for r = selMin, selMax do
          if seq:l2Present(self.slot, col, r) then
            cells[r - selMin] = {
              predOp      = seq:l2PredOp(self.slot, col, r),
              predColA    = seq:l2PredColA(self.slot, col, r),
              predColARow = seq:l2PredColARow(self.slot, col, r),
              predVal     = seq:l2PredVal(self.slot, col, r),
              actOp       = seq:l2ActOp(self.slot, col, r),
              actTgt      = seq:l2ActTgt(self.slot, col, r),
              actTgtRow   = seq:l2ActTgtRow(self.slot, col, r),
              actVal      = seq:l2ActVal(self.slot, col, r),
            }
            seq:clearL2(self.slot, col, r)
          end
        end
        clipboard = { layer = "L2", col = col, cells = cells }
      elseif i == 3 then
        -- Random L2 deferred (see Step 9 item 6: coherent random).
        -- Cleaner to no-op than to dump chaotic rules.
      else
        return false
      end
    end
    self.preEditValues   = {}
    self.editedCells     = {}
    self.selectionActive = false
    self:refresh()
    return true
  end

  -- Shift-overlay bindings:
  --   shift+S1 = paste (only when clipboard is non-empty; see refresh
  --              for the matching label swap on S1)
  --   shift+S3 = layer toggle (kept on shifted too for muscle memory
  --              continuity; same gesture as unshifted S3 below).
  if shifted then
    if i == 1 then return self:_pasteAtFocus() end
    if i == 3 then
      self.layer = (self.layer == "L1") and "L2" or "L1"
      self:refresh()
      return true
    end
    return false
  end

  -- Default sub bar: S1 = transport, S2 = mark / end (modal),
  -- S3 = layer toggle (L1 <-> L2). The bar always shows the OTHER
  -- layer's name on S3 so the gesture is discoverable without
  -- requiring the user to hold shift first.
  if i == 1 then
    -- Unified transport across all four slots so users mute
    -- individual slots chain-side (where it composes with the rest
    -- of the patch) rather than juggling per-slot runs that can
    -- drift apart without a reset gesture.
    if self.running then
      for s = 0, 3 do seq:stopSlot(s) end
      self.running = false
      self.statusLabel:setText("stopped")
    else
      for s = 0, 3 do seq:startSlot(s) end
      self.running = true
      self.statusLabel:setText("running")
    end
    return true
  elseif i == 2 then
    if self.markingMode == "idle" then
      -- First press: snapshot existing marker pair, plant marker1 at
      -- focusHead, set marker2 = focusHead as a 1-step seed loop, and
      -- enter the modal. Encoder + HOME from here live-update marker2.
      local col = self.columnCursor
      self.markBackup = {
        col = col,
        m1  = seq:marker1(self.slot, col),
        m2  = seq:marker2(self.slot, col),
      }
      self.markFirstMark = self.focusHeadRow
      seq:setMarkers(self.slot, col, self.focusHeadRow, self.focusHeadRow)
      self.markingMode = "marking_end"
    else
      -- Second press: commit the normalized (lo, hi) pair and exit.
      self:_commitMark()
    end
    self:refresh()
    return true
  elseif i == 3 then
    -- Layer toggle: same gesture whether shift is held or not (see
    -- shifted path above), so the bar's S3 label is the discoverable
    -- always-on affordance.
    self.layer = (self.layer == "L1") and "L2" or "L1"
    self:refresh()
    return true
  end
  return false
end

-- Encoder advances/retreats the focus head row (shared across all 6
-- plies per locked decision). The ER-301 has a single encoder; column
-- movement is M-key only (mainReleased). Each kEncoderThreshold ticks
-- of physical rotation = one row, matching ScopeView / ListWindow.
--
-- In edit state, the encoder instead nudges the cell value at
-- (focusHeadRow, columnCursor) by the column's type-specific step.
function GridView:encoder(change, shifted)
  local seq = app.AudioThread.getSequencerTask()
  if not seq then return false end

  -- BPM nudge has top priority: while shift+S2 is held, the encoder
  -- routes here regardless of other modal state. Step is integer
  -- BPM; shift on the encoder gesture itself picks the super step.
  -- Clamped 20..300 (musical range covering most use cases).
  if self.bpmHeld then
    self.bpmAccum = self.bpmAccum + change
    local step = shifted and 5 or 1
    local cur = seq:getBpm()
    local function clamp(v) return math.max(20, math.min(300, v)) end
    while self.bpmAccum >= kEncoderThreshold do
      cur = clamp(cur + step)
      self.bpmAccum = self.bpmAccum - kEncoderThreshold
    end
    while self.bpmAccum <= -kEncoderThreshold do
      cur = clamp(cur - step)
      self.bpmAccum = self.bpmAccum + kEncoderThreshold
    end
    seq:setBpm(cur)
    self:refresh()
    return true
  end

  self.encoderAccum = self.encoderAccum + change
  local moved = false

  if self.editingL1 then
    -- Edit mode: nudge cell value. Shift picks the super step.
    local step = stepForColumn(self.columnCursor, self.editStepMode, shifted)
    while self.encoderAccum >= kEncoderThreshold do
      local v = seq:l1Value(self.slot, self.columnCursor, self.focusHeadRow)
      seq:setL1(self.slot, self.columnCursor, self.focusHeadRow, v + step)
      self.encoderAccum = self.encoderAccum - kEncoderThreshold
      moved = true
    end
    while self.encoderAccum <= -kEncoderThreshold do
      local v = seq:l1Value(self.slot, self.columnCursor, self.focusHeadRow)
      seq:setL1(self.slot, self.columnCursor, self.focusHeadRow, v - step)
      self.encoderAccum = self.encoderAccum + kEncoderThreshold
      moved = true
    end
  elseif self.markingMode == "marking_end" then
    -- Mark modal: encoder scrolls focusHead and live-updates marker2
    -- on the column being marked. Shift modifier is ignored here --
    -- marking is exclusive of selection-extend, so the user can't
    -- accidentally bend the encoder into a selection mid-mark.
    while self.encoderAccum >= kEncoderThreshold do
      self.focusHeadRow = clamp(self.focusHeadRow + 1, 0, kMaxRow)
      self.encoderAccum = self.encoderAccum - kEncoderThreshold
      moved = true
    end
    while self.encoderAccum <= -kEncoderThreshold do
      self.focusHeadRow = clamp(self.focusHeadRow - 1, 0, kMaxRow)
      self.encoderAccum = self.encoderAccum + kEncoderThreshold
      moved = true
    end
    if moved then self:_updateMarkingLive() end
  elseif shifted then
    -- Nav mode + shift: extend selection on either layer. The
    -- selection mechanic itself is layer-agnostic (just a row-range
    -- on a column); only the sub-bar actions (copy / cut / rand)
    -- differ between L1 floats and L2 rule tuples (handled in
    -- subReleased below).
    -- focusHeadRow tracks the moving end. Selection range =
    -- [min(anchor, end), max(anchor, end)]. The cursor box renders
    -- at min(anchor, end) (= master) per Chunk B; the focusHeadRow
    -- stays as the moving end for the next shift-encoder tick.
    if not self.selectionActive then
      self.selectionAnchor = self.focusHeadRow
      self.selectionColumn = self.columnCursor
      self.selectionActive = true
    end
    while self.encoderAccum >= kEncoderThreshold do
      self.focusHeadRow = clamp(self.focusHeadRow + 1, 0, kMaxRow)
      self.encoderAccum = self.encoderAccum - kEncoderThreshold
      moved = true
    end
    while self.encoderAccum <= -kEncoderThreshold do
      self.focusHeadRow = clamp(self.focusHeadRow - 1, 0, kMaxRow)
      self.encoderAccum = self.encoderAccum + kEncoderThreshold
      moved = true
    end
    if moved then self.selectionEnd = self.focusHeadRow end
  elseif self.selectionActive and self.selectionColumn == self.columnCursor
         and self.layer == "L1" then
    -- Bulk edit on selection (L1 only). L2 cells are pred:action
    -- tuples, not numeric values, so bulk-nudge doesn't translate;
    -- encoder during L2 selection falls through to a no-op below.
    -- Top of selection (= min(anchor, end)) is master. Each encoder
    -- tick reads master's current value, adds the column's fine /
    -- coarse step, and writes the result to every cell in [selMin,
    -- selMax]. After the first tick, all selected cells share the
    -- master's value; subsequent ticks
    -- step them together.
    --
    -- Pre-edit snapshot: the first time a tick mutates a given cell,
    -- capture its original value into preEditValues so that CANCEL
    -- can revert. Subsequent ticks on that cell do NOT overwrite the
    -- snapshot (the snapshot must always be the user's pre-edit
    -- value, not the in-progress edited value). editedCells[col][r]
    -- gates the dirty-dot overlay in refresh.
    local selMin = math.min(self.selectionAnchor, self.selectionEnd)
    local selMax = math.max(self.selectionAnchor, self.selectionEnd)
    local col    = self.selectionColumn
    local step   = stepForColumn(col, self.editStepMode, false)
    local function applyBulk(delta)
      local newV = seq:l1Value(self.slot, col, selMin) + delta
      local pre  = self.preEditValues[col]
      local dirty = self.editedCells[col]
      if not pre   then pre   = {}; self.preEditValues[col] = pre end
      if not dirty then dirty = {}; self.editedCells[col]   = dirty end
      for r = selMin, selMax do
        if pre[r] == nil then
          pre[r] = seq:l1Value(self.slot, col, r)
        end
        seq:setL1(self.slot, col, r, newV)
        dirty[r] = true
      end
    end
    while self.encoderAccum >= kEncoderThreshold do
      applyBulk(step)
      self.encoderAccum = self.encoderAccum - kEncoderThreshold
      moved = true
    end
    while self.encoderAccum <= -kEncoderThreshold do
      applyBulk(-step)
      self.encoderAccum = self.encoderAccum + kEncoderThreshold
      moved = true
    end
  elseif self.selectionActive and self.layer == "L2" then
    -- L2 selection: encoder during selection is a no-op (L2 cells
    -- aren't numerically bulk-editable). User acts via S1 / S2 / S3
    -- (copy / cut / rand) or extends further via shift+encoder.
    self.encoderAccum = 0
  else
    -- Nav mode no shift, no selection: plain focus-head scroll.
    while self.encoderAccum >= kEncoderThreshold do
      self.focusHeadRow = clamp(self.focusHeadRow + 1, 0, kMaxRow)
      self.encoderAccum = self.encoderAccum - kEncoderThreshold
      moved = true
    end
    while self.encoderAccum <= -kEncoderThreshold do
      self.focusHeadRow = clamp(self.focusHeadRow - 1, 0, kMaxRow)
      self.encoderAccum = self.encoderAccum + kEncoderThreshold
      moved = true
    end
  end

  if moved then self:refresh() end
  return true
end

-- M1-M6 jump the column cursor directly to that ply. Switching to a
-- different column clears any active selection (selection is per-column).
function GridView:mainReleased(i, shifted)
  -- shift+M2..M5 = slot picker (slots 0..3). M1 and M6 are reserved
  -- per locked direction so they stay out of the slot map. On slot
  -- switch we keep focusHead / columnCursor where they are so the
  -- user lands on the same logical position in the new slot.
  -- Selection / mark / bulk-edit state is per-slot, so we clear any
  -- in-flight modal state on switch.
  if shifted and i >= 2 and i <= 5 then
    local newSlot = i - 2
    if newSlot ~= self.slot then
      -- Clear in-flight modals on the outgoing slot.
      self.preEditValues   = {}
      self.editedCells     = {}
      self.selectionActive = false
      self:_revertMark()   -- no-op if not marking
      self.slot = newSlot
      -- Reset visual easing so the cursor snaps to the new slot's
      -- starting position rather than animating from old slot.
      self.cursorAnimX   = nil
      self.cursorAnimY   = nil
      self.cursorEasingY = false
      self.scrollFrac    = nil
      self:refresh()
    end
    return true
  end
  if shifted then return false end
  if i >= 1 and i <= kNumColumns then
    local newCol = i - 1
    if self.selectionActive and newCol ~= self.selectionColumn then
      -- Switching columns implicitly commits any in-flight bulk edit.
      -- Values stay at their current (edited) state, but the pre-edit
      -- snapshot + dirty markers are dropped so they don't follow the
      -- user to the new column.
      self.preEditValues   = {}
      self.editedCells     = {}
      self.selectionActive = false
    end
    -- Column-switch during a mark modal also implicit-commits the
    -- in-flight marker pair (on its original column) before moving.
    if self.markingMode == "marking_end"
       and self.markBackup and newCol ~= self.markBackup.col then
      self:_commitMark()
    end
    self.columnCursor = newCol
    self:refresh()
    return true
  end
  return false
end

-- ENTER from grid view: enter the L1 inline edit state on the active
-- cell, or (if already editing) commit + auto-advance focus head down
-- one row (Habitat-fluid editing). CANCEL or UP exit the edit state.
-- Entering edit mode clears any active selection (mutually exclusive).
function GridView:enterReleased(shifted)
  if shifted then return false end
  -- L2 layer: open the cell editor modal. Commit / advance / cancel
  -- are handled by the modal; we only need to refresh on close so
  -- the grid picks up any newly written L2 cell. shift+ENTER inside
  -- the modal advances focusHead and reloads the editor for the
  -- next row via the commitAndAdvance signal below.
  if self.layer == "L2" and not self.editingL1 then
    local CellEditor = require "Sequencer.CellEditor"
    local editor = CellEditor(self.slot, self.columnCursor, self.focusHeadRow)
    editor:subscribe("done", function() self:refresh() end)
    editor:subscribe("commitAndAdvance", function()
      self.focusHeadRow = clamp(self.focusHeadRow + 1, 0, kMaxRow)
      editor:reloadForCell(self.columnCursor, self.focusHeadRow)
      self:refresh()
    end)
    editor:show()
    return true
  end
  if self.editingL1 then
    self.focusHeadRow = clamp(self.focusHeadRow + 1, 0, kMaxRow)
  else
    -- Entering edit mode commits any in-flight mark modal (same
    -- semantics as UP / column-change).
    self:_commitMark()
    self.editingL1 = true
    -- Entering edit mode while a bulk-edit is active commits it (same
    -- semantics as UP / column-change): keep values, drop snapshot.
    self.preEditValues   = {}
    self.editedCells     = {}
    self.selectionActive = false
  end
  self:refresh()
  return true
end

function GridView:cancelReleased(shifted)
  -- Edit mode takes priority -- CANCEL exits edit first.
  if self.editingL1 then
    self.editingL1 = false
    self:refresh()
    return true
  end
  -- Mark modal: CANCEL = REVERT the in-flight (markFirstMark, focusHead)
  -- pair back to the pre-S2 snapshot. Symmetric with selection's
  -- CANCEL-reverts behavior.
  if self.markingMode == "marking_end" then
    self:_revertMark()
    self:refresh()
    return true
  end
  -- Otherwise CANCEL = REVERT: restore any bulk-edit pre-edit values
  -- to the engine, then clear the selection. If no bulk edit has
  -- occurred this is just a deselect.
  if self.selectionActive then
    local seq = app.AudioThread.getSequencerTask()
    if seq then
      for col, rows in pairs(self.preEditValues) do
        for row, val in pairs(rows) do
          seq:setL1(self.slot, col, row, val)
        end
      end
    end
    self.preEditValues = {}
    self.editedCells   = {}
    self.selectionActive = false
    self:refresh()
    return true
  end
  return false
end

function GridView:upReleased(shifted)
  if self.editingL1 then
    self.editingL1 = false
    self:refresh()
    return true
  end
  -- UP = implicit COMMIT during selection: drop the pre-edit snapshot
  -- and dirty markers (keeping the bulk-edited cell values as-is) and
  -- release the selection handle.
  if self.selectionActive then
    self.preEditValues = {}
    self.editedCells   = {}
    self.selectionActive = false
    self:refresh()
    return true
  end
  -- UP also implicit-commits a mark modal (alias for the second S2
  -- press); the in-flight markFirstMark/focusHead pair becomes the
  -- final loop region.
  if self.markingMode == "marking_end" then
    self:_commitMark()
    self:refresh()
    return true
  end
  return false
end

-- HOME jumps focus head to row 0 (only useful in the grid, not in edit
-- mode). shift+HOME comes through as zeroReleased and zeroes the
-- value of the active cell while in edit mode.
function GridView:homeReleased()
  if not self.editingL1 then
    self.focusHeadRow = 0
    self.encoderAccum = 0
    -- During a mark modal, jumping to row 0 should drag marker2 with
    -- the focus head so the live loop visual stays in sync.
    self:_updateMarkingLive()
    self:refresh()
    return true
  end
  return false
end

-- shift+HOME dispatches as zeroReleased. Inside the L1 cell editor it
-- zeros the focused cell (the original "shift+HOME = clear cell"
-- gesture). Outside the editor it now stands in for the playhead
-- reset previously bound to S3 (since S3 was reclaimed for marking);
-- pressing it sends every column's playhead back to row 0 without
-- touching transport state.
function GridView:zeroReleased()
  if self.editingL1 then
    local seq = app.AudioThread.getSequencerTask()
    if seq then
      seq:setL1(self.slot, self.columnCursor, self.focusHeadRow, 0.0)
      self:refresh()
    end
    return true
  end
  local seq = app.AudioThread.getSequencerTask()
  if seq then
    seq:resetSlot(self.slot)
    self:refresh()
  end
  return true
end

-- Dial mode button toggles between fine and coarse step in edit mode.
-- Outside edit mode, fall through so the firmware's default dial
-- behavior can run (encoder Fine/Coarse global state). Shift selects
-- the "super" variant of whichever mode is current.
function GridView:dialPressed(shifted)
  if not self.editingL1 then return false end
  self.editStepMode = (self.editStepMode == "fine") and "coarse" or "fine"
  self:refresh()
  return true
end

-- shift+ENTER dispatches as commitReleased via Application.lua. Returns
-- to the standard scope sub-view.
function GridView:commitReleased()
  local Channels = require "Channels"
  Channels.toggleSequencerSubView()
  return true
end

return GridView

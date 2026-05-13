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

-- Slot 0 is shown by default. Multi-slot selection comes later.
local kSlot = 0

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

local function fmtCellByCol(col, v)
  if col == 0 then return fmtNote(v) end
  if col == 1 or col == 2 then return fmtVolts(v) end
  if col == 3 or col == 5 then return fmtBeats(v) end
  if col == 4 then return fmtAmp(v) end
  return string.format("%5.2f", v)
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

  -- Cell value grid: kVisibleRows rows x kNumColumns columns.
  self.cellLabels = {}
  for c = 1, kNumColumns do
    local x = (c - 1) * kColPly + 2
    self.cellLabels[c] = {}
    for r = 1, kVisibleRows do
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
  -- text (cell text ends ~x=242, ruler at x=244).
  self.rulerLabels = {}
  for r = 1, kVisibleRows do
    local y = kHeaderY - r * kRowHeight
    local lbl = app.Label("00", kFontMain)
    lbl:setJustification(app.justifyLeft)
    lbl:setPosition(kRulerX, y)
    self:addMainGraphic(lbl)
    self.rulerLabels[r] = lbl
  end

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

  -- Edit-step indicator (FINE / COARSE / SUPER FINE / SUPER COARSE).
  -- Blank when not editing.
  self.editStepLabel = app.Label("", kFontSub)
  self.editStepLabel:setPosition(60, app.GRID4_LINE2)
  self.editStepLabel:setJustification(app.justifyLeft)
  self:addSubGraphic(self.editStepLabel)

  self.startStopButton = app.SubButton("start", 1)
  self:addSubGraphic(self.startStopButton)

  -- S2 reserved (slot selector etc.).

  self.resetButton = app.SubButton("reset", 3)
  self:addSubGraphic(self.resetButton)

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
--   gate-len/step-len: 1/16 / 1/4    / 1/64    / 1 beat
--   gate-amp:       5%      / 20%    / 1.25%   / 80%
local kColumnSteps = {
  [0] = { fine = 1/12,   coarse = 1.0,    superFine = 1/120,  superCoarse = 12.0 },
  [1] = { fine = 0.1,    coarse = 1.0,    superFine = 0.01,   superCoarse = 10.0 },
  [2] = { fine = 0.1,    coarse = 1.0,    superFine = 0.01,   superCoarse = 10.0 },
  [3] = { fine = 0.0625, coarse = 0.25,   superFine = 0.0156, superCoarse = 1.0  },
  [4] = { fine = 0.05,   coarse = 0.2,    superFine = 0.0125, superCoarse = 0.8  },
  [5] = { fine = 0.0625, coarse = 0.25,   superFine = 0.0156, superCoarse = 1.0  },
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

  -- Scroll follows the focus head (encoder-driven). The playhead may
  -- be inside or outside the visible window depending on where the
  -- user has scrolled; HOME jumps focus head to row 0 (use that or
  -- manually scroll to follow the playhead). An auto-follow-playhead
  -- mode is intentionally NOT added here -- it conflicts with the
  -- user's view-selection intent.
  local startRow = clamp(self.focusHeadRow - 2, 0, kMaxRow - kVisibleRows + 1)

  for c = 1, kNumColumns do
    local col = c - 1
    local playhead = seq:playhead(kSlot, col)
    local m1 = seq:marker1(kSlot, col)
    local m2 = seq:marker2(kSlot, col)
    local loopLo, loopHi = math.min(m1, m2), math.max(m1, m2)

    self.headerLabels[c]:setText(string.format("%s:%02d", kColNames[c], playhead))
    self.headerLabels[c]:setForegroundColor(
      (col == self.columnCursor) and kHeaderActive or kHeaderInactive)

    for r = 1, kVisibleRows do
      local absRow = startRow + r - 1
      local v = seq:l1Value(kSlot, col, absRow)
      local inLoop     = absRow >= loopLo and absRow <= loopHi
      local isFocus    = absRow == self.focusHeadRow
      local isPlayhead = absRow == playhead
      self.cellLabels[c][r]:setText(fmtCellByCol(col, v))
      self.cellLabels[c][r]:setForegroundColor(
        cellBrightness(isPlayhead, isFocus, inLoop))
    end
  end

  -- Row ruler: absolute row numbers for the visible window, brightened
  -- on the focus row.
  for r = 1, kVisibleRows do
    local absRow = startRow + r - 1
    self.rulerLabels[r]:setText(string.format("%02d", absRow))
    self.rulerLabels[r]:setForegroundColor(
      (absRow == self.focusHeadRow) and kBrightBoth or kBrightNormal)
  end

  -- Cursor box: outline the cell at (focusHeadRow, columnCursor).
  -- See the cursorBox construction comment for the +3 anchor math
  -- (label bounding-box bottom vs actual text glyph bottom).
  -- During playback the scroll follows the playhead, so the focus
  -- head can be off-screen; in that case we just hide the cursor.
  local visibleRow = self.focusHeadRow - startRow + 1  -- 1-based
  if visibleRow >= 1 and visibleRow <= kVisibleRows then
    local labelY = kHeaderY - visibleRow * kRowHeight
    local boxX = self.columnCursor * kColPly
    local boxY = labelY + 3
    self.cursorBox:setPosition(boxX, boxY)
    -- White when editing (Habitat-fluid mode), GRAY10 when just navigating.
    self.cursorBox:setBorderColor(self.editingL1 and app.WHITE or app.GRAY10)
    self.cursorBox:show()
  else
    self.cursorBox:hide()
  end

  -- Selection box: dotted-edge rectangle wrapping the row-range
  -- selection on `selectionColumn`. Hidden when the user has switched
  -- columns (which also clears the selection, but defensive in case).
  if self.selectionActive and self.selectionColumn == self.columnCursor then
    local selMin = math.min(self.selectionAnchor, self.selectionEnd)
    local selMax = math.max(self.selectionAnchor, self.selectionEnd)
    -- Clip to visible window so off-screen portions just don't render.
    local topV    = math.max(1,            selMin - startRow + 1)
    local bottomV = math.min(kVisibleRows, selMax - startRow + 1)
    if topV <= bottomV then
      local topLabelY    = kHeaderY - topV    * kRowHeight
      local bottomLabelY = kHeaderY - bottomV * kRowHeight
      local selX = self.selectionColumn * kColPly
      local selY = bottomLabelY + 3
      local selH = (bottomV - topV) * kRowHeight + 10
      buildDottedRect(self.selectionInstr, selX, selY, kColPly, selH, app.GRAY10)
      self.selectionDrawing:show()
    else
      self.selectionDrawing:hide()
    end
  else
    self.selectionDrawing:hide()
  end

  self.bpmLabel:setText(string.format("BPM %d", math.floor(seq:getBpm() + 0.5)))

  -- Edit-step indicator. Shown only while in edit mode.
  if self.editingL1 then
    self.editStepLabel:setText(self.editStepMode == "coarse" and "COARSE" or "FINE")
  else
    self.editStepLabel:setText("")
  end
end

function GridView:onShow()
  -- Per-display-frame refresh (55 Hz). Bypasses Timer.every which is
  -- throttled to ~5 Hz internally and would cause the playhead to
  -- visibly skip rows at any engine tick rate above ~5 Hz.
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

function GridView:subReleased(i, shifted)
  if shifted then return false end
  local seq = app.AudioThread.getSequencerTask()
  if not seq then return false end

  if i == 1 then
    if self.running then
      seq:stopSlot(kSlot)
      self.running = false
      self.statusLabel:setText("stopped")
      self.startStopButton:setText("start")
    else
      seq:startSlot(kSlot)
      self.running = true
      self.statusLabel:setText("running")
      self.startStopButton:setText("stop")
    end
    return true
  elseif i == 3 then
    seq:resetSlot(kSlot)
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

  self.encoderAccum = self.encoderAccum + change
  local moved = false

  if self.editingL1 then
    -- Edit mode: nudge cell value. Shift picks the super step.
    local step = stepForColumn(self.columnCursor, self.editStepMode, shifted)
    while self.encoderAccum >= kEncoderThreshold do
      local v = seq:l1Value(kSlot, self.columnCursor, self.focusHeadRow)
      seq:setL1(kSlot, self.columnCursor, self.focusHeadRow, v + step)
      self.encoderAccum = self.encoderAccum - kEncoderThreshold
      moved = true
    end
    while self.encoderAccum <= -kEncoderThreshold do
      local v = seq:l1Value(kSlot, self.columnCursor, self.focusHeadRow)
      seq:setL1(kSlot, self.columnCursor, self.focusHeadRow, v - step)
      self.encoderAccum = self.encoderAccum + kEncoderThreshold
      moved = true
    end
  elseif shifted then
    -- Nav mode + shift: extend selection. Anchor on first activation;
    -- focusHeadRow tracks the moving end (so the cursor box sits on
    -- the cell the user is actively dialing toward). Selection range
    -- = [min(anchor, end), max(anchor, end)].
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
  else
    -- Nav mode no shift: plain focus-head scroll.
    -- Bulk-edit on selection lands in Chunk B; for now selection is
    -- visible but inert when encoder is turned without shift.
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
  if shifted then return false end
  if i >= 1 and i <= kNumColumns then
    local newCol = i - 1
    if self.selectionActive and newCol ~= self.selectionColumn then
      self.selectionActive = false
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
  if self.editingL1 then
    self.focusHeadRow = clamp(self.focusHeadRow + 1, 0, kMaxRow)
  else
    self.editingL1 = true
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
  -- Otherwise CANCEL clears an active selection.
  if self.selectionActive then
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
  return false
end

-- HOME jumps focus head to row 0 (only useful in the grid, not in edit
-- mode). shift+HOME comes through as zeroReleased and zeroes the
-- value of the active cell while in edit mode.
function GridView:homeReleased()
  if not self.editingL1 then
    self.focusHeadRow = 0
    self.encoderAccum = 0
    self:refresh()
    return true
  end
  return false
end

function GridView:zeroReleased()
  if self.editingL1 then
    local seq = app.AudioThread.getSequencerTask()
    if seq then
      seq:setL1(kSlot, self.columnCursor, self.focusHeadRow, 0.0)
      self:refresh()
    end
    return true
  end
  return false
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

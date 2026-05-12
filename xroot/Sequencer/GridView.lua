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
local Timer = require "Timer"
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

-- Format an L1 cell value into a 5-character field. CV columns may show
-- a sign; gate-amp/step-len/gate-len are non-negative. Five chars at
-- font 8 (~5 px per glyph) = 25 px, well within the 42 px per column.
local function fmtCell(v)
  if v ~= v then return "  NaN" end
  if math.abs(v) < 0.005 then return " 0.00" end
  if v >= 0 then
    return string.format("%5.2f", v)
  else
    return string.format("%5.2f", v)  -- "-X.XX" already 5 chars
  end
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

  -- ---- navigation state ----
  -- focusHeadRow: shared "global scroll" row, encoder-driven.
  -- columnCursor: which column is active, 0..5, M1-M6-driven.
  -- editingL1: when true, the encoder nudges the cell value at
  --            (focusHeadRow, columnCursor) instead of scrolling.
  self.focusHeadRow = 0
  self.columnCursor = 0
  self.encoderAccum = 0  -- accumulates ticks until kEncoderThreshold is reached
  self.editingL1    = false
  self.editStepMode = "fine"  -- "fine" or "coarse"; toggled via dial button

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
  self.refreshTimer = nil
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
-- selected=15) with the dim bumped to 3 for legibility and a focus-only
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

-- Per-column nudge step when editing an L1 cell value. CV columns step
-- by 50 mV (0.05 V), gate-amp by 5%, time columns by 1/16-beat. These
-- match the typical "interesting musical resolution" for each column.
-- Indexed by 0-based column index (kColCV1..kColStepLen).
local kColumnSteps = {
  [0] = 0.05,    -- cv1
  [1] = 0.05,    -- cv2
  [2] = 0.05,    -- cv3
  [3] = 0.0625,  -- gate-len (beats)
  [4] = 0.05,    -- gate-amp
  [5] = 0.0625,  -- step-len (beats)
}

-- 4-level rate ramp for L1 edit, each level 4x the previous.
--   fine        -> 1x
--   coarse      -> 4x
--   super fine  -> 0.25x   (shift held while editStepMode == "fine")
--   super coarse-> 16x     (shift held while editStepMode == "coarse")
-- Dial button toggles fine <-> coarse; shift in either picks the "super" variant.
local function stepMultiplier(editStepMode, shifted)
  if editStepMode == "coarse" then
    return shifted and 16.0 or 4.0
  end
  -- fine
  return shifted and 0.25 or 1.0
end

local function cellBrightness(isPlayhead, isFocus, inLoop)
  if isPlayhead and isFocus then return kBrightBoth end
  if isPlayhead            then return kBrightPlayhead end
  if isFocus               then return kBrightFocus end
  if inLoop                then return kBrightNormal end
  return kBrightDim
end

function GridView:refresh()
  local seq = app.AudioThread.getSequencerTask()
  if not seq then return end

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
      self.cellLabels[c][r]:setText(fmtCell(v))
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
  -- The focus head is always within the visible window due to the
  -- centering scroll above, so we always have a valid visibleRow.
  -- See the cursorBox construction comment for the +3 anchor math
  -- (label bounding-box bottom vs actual text glyph bottom).
  local visibleRow = self.focusHeadRow - startRow + 1  -- 1-based
  local labelY = kHeaderY - visibleRow * kRowHeight
  local boxX = self.columnCursor * kColPly
  local boxY = labelY + 3
  self.cursorBox:setPosition(boxX, boxY)
  -- White when editing (Habitat-fluid mode), GRAY10 when just navigating.
  self.cursorBox:setBorderColor(self.editingL1 and app.WHITE or app.GRAY10)

  self.bpmLabel:setText(string.format("BPM %d", math.floor(seq:getBpm() + 0.5)))

  -- Edit-step indicator. Shown only while in edit mode.
  if self.editingL1 then
    self.editStepLabel:setText(self.editStepMode == "coarse" and "COARSE" or "FINE")
  else
    self.editStepLabel:setText("")
  end
end

function GridView:onShow()
  self.refreshTimer = Timer.every(1.0 / 30.0, function()
    self:refresh()
    return true
  end)
  self:refresh()
end

function GridView:onHide()
  if self.refreshTimer then
    Timer.cancel(self.refreshTimer)
    self.refreshTimer = nil
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
  -- Outside edit mode, shift+encoder is reserved for selection-extend
  -- per the plan (Step 7). For v0.1, swallow it so it doesn't scroll.
  -- Inside edit mode, shifted selects the "super" step multiplier.
  if shifted and not self.editingL1 then return false end

  local seq = app.AudioThread.getSequencerTask()
  if not seq then return false end

  self.encoderAccum = self.encoderAccum + change
  local moved = false

  if self.editingL1 then
    local baseStep = kColumnSteps[self.columnCursor] or 0.05
    local step = baseStep * stepMultiplier(self.editStepMode, shifted)
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
  else
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

-- M1-M6 jump the column cursor directly to that ply.
function GridView:mainReleased(i, shifted)
  if shifted then return false end
  if i >= 1 and i <= kNumColumns then
    self.columnCursor = i - 1
    self:refresh()
    return true
  end
  return false
end

-- ENTER from grid view: enter the L1 inline edit state on the active
-- cell, or (if already editing) commit + auto-advance focus head down
-- one row (Habitat-fluid editing). CANCEL or UP exit the edit state.
function GridView:enterReleased(shifted)
  if shifted then return false end
  if self.editingL1 then
    self.focusHeadRow = clamp(self.focusHeadRow + 1, 0, kMaxRow)
  else
    self.editingL1 = true
  end
  self:refresh()
  return true
end

function GridView:cancelReleased(shifted)
  if self.editingL1 then
    self.editingL1 = false
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

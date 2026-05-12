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

  -- ---- navigation state ----
  -- focusHeadRow: shared "global scroll" row, encoder-driven.
  -- columnCursor: which column is active, 0..5, M1-M6-driven.
  self.focusHeadRow = 0
  self.columnCursor = 0
  self.encoderAccum = 0  -- accumulates ticks until kEncoderThreshold is reached

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

  self.bpmLabel:setText(string.format("BPM %d", math.floor(seq:getBpm() + 0.5)))
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
function GridView:encoder(change, shifted)
  -- shift+encoder will become selection-extend per the plan (Step 7).
  -- For v0.1, only honor the unshifted form.
  if shifted then return false end
  self.encoderAccum = self.encoderAccum + change
  local moved = false
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

-- shift+ENTER dispatches as commitReleased via Application.lua. Returns
-- to the standard scope sub-view.
function GridView:commitReleased()
  local Channels = require "Channels"
  Channels.toggleSequencerSubView()
  return true
end

function GridView:upReleased(shifted)     return false end
function GridView:cancelReleased(shifted) return false end
function GridView:homeReleased()          return false end

return GridView

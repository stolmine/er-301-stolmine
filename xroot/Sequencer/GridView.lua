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
local kColPly     = app.SECTION_PLY  -- 42px per column on the 256px main
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
  -- self.cellLabels[c][r] is the Label showing column c's value at the
  -- r-th VISIBLE row (which maps to an absolute row in the column based
  -- on the column's playhead window in refresh()).
  self.cellLabels = {}
  for c = 1, kNumColumns do
    local x = (c - 1) * kColPly + 2
    self.cellLabels[c] = {}
    for r = 1, kVisibleRows do
      local y = kHeaderY - r * kRowHeight  -- 48, 40, 32, ..., 0
      local lbl = app.Label("      ", kFontMain)
      lbl:setJustification(app.justifyLeft)
      lbl:setPosition(x, y)
      self:addMainGraphic(lbl)
      self.cellLabels[c][r] = lbl
    end
  end

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

function GridView:refresh()
  local seq = app.AudioThread.getSequencerTask()
  if not seq then return end

  for c = 1, kNumColumns do
    local col = c - 1
    local playhead = seq:playhead(kSlot, col)
    self.headerLabels[c]:setText(string.format("%s:%02d", kColNames[c], playhead))
    -- v0.1: always show rows 0..kVisibleRows-1 (no auto-scroll yet).
    -- Header shows the live playhead row even when it leaves the window.
    -- Add a real column-length accessor + scroll math when authoring UI
    -- lands in Step 5 / Step 4.
    for r = 1, kVisibleRows do
      local absRow = r - 1
      local v = seq:l1Value(kSlot, col, absRow)
      local prefix = (absRow == playhead) and ">" or " "
      self.cellLabels[c][r]:setText(prefix .. fmtCell(v))
    end
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

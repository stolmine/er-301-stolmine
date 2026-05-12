-- ER-301 stolmine sequencer Step-1 minimum-interactable view.
--
-- Renders one slot's six columns as a read-only grid with live playhead
-- and held-value display. Sub-display has S1 = transport (start/stop).
-- shift+ENTER returns to the standard scope view (handled by parent
-- ChannelGroup via Channels.toggleSequencerSubView).
--
-- This is a placeholder for the eventual Step 4 GridView. Layout is
-- text-based via app.Label; the proper StepListGraphic-style grid lands
-- in Step 4.

local app = app
local Class = require "Base.Class"
local Window = require "Base.Window"
local Timer = require "Timer"

local GridView = Class {}
GridView:include(Window)

-- Slot 0 is shown by default. Multi-slot selection comes later.
local kSlot = 0

-- Column-name labels (matching seqN.<name> picker entries).
local kColNames = { "cv1", "cv2", "cv3", "gtL", "gtA", "stL" }

function GridView:init(chain)
  Window.init(self)
  self:setClassName("Sequencer.GridView")
  self.chain = chain

  -- ---- main display: header + per-column row/value labels ----
  self.title = app.Label("seq1 (slot 0)", 10)
  self.title:setPosition(2, app.GRID5_LINE1)
  self.title:setJustification(app.justifyLeft)
  self:addMainGraphic(self.title)

  -- Six column ply labels, ~42px wide each, left-aligned.
  self.colNameLabels  = {}
  self.colRowLabels   = {}
  self.colValueLabels = {}
  for c = 1, 6 do
    local x = (c - 1) * 42 + 4
    local name = app.Label(kColNames[c], 10)
    name:setPosition(x, app.GRID5_LINE2)
    name:setJustification(app.justifyLeft)
    self:addMainGraphic(name)
    self.colNameLabels[c] = name

    local rowLbl = app.Label("--", 10)
    rowLbl:setPosition(x, app.GRID5_LINE3)
    rowLbl:setJustification(app.justifyLeft)
    self:addMainGraphic(rowLbl)
    self.colRowLabels[c] = rowLbl

    local valLbl = app.Label("0.000", 10)
    valLbl:setPosition(x, app.GRID5_LINE4)
    valLbl:setJustification(app.justifyLeft)
    self:addMainGraphic(valLbl)
    self.colValueLabels[c] = valLbl
  end

  -- ---- sub display: transport ----
  self.statusLabel = app.Label("stopped", 10)
  self.statusLabel:setPosition(2, app.GRID4_LINE1)
  self.statusLabel:setJustification(app.justifyLeft)
  self:addSubGraphic(self.statusLabel)

  self.bpmLabel = app.Label("BPM 120", 10)
  self.bpmLabel:setPosition(2, app.GRID4_LINE2)
  self.bpmLabel:setJustification(app.justifyLeft)
  self:addSubGraphic(self.bpmLabel)

  self.startStopButton = app.SubButton("start", 1)
  self:addSubGraphic(self.startStopButton)

  -- S2 reserved for later (slot selector etc.). Leave unlabeled.

  self.resetButton = app.SubButton("reset", 3)
  self:addSubGraphic(self.resetButton)

  self.running = false
  self.refreshTimer = nil
end

local function fmtFloat(v)
  if v ~= v then return "NaN" end  -- guard against NaN even though we shouldn't produce them
  return string.format("%5.2f", v)
end

local kHeldGetters = { "heldCV1", "heldCV2", "heldCV3", "heldGateLen", "heldGateAmp", "heldStepLen" }

function GridView:refresh()
  local seq = app.AudioThread.getSequencerTask()
  if not seq then return end

  for c = 1, 6 do
    local row = seq:playhead(kSlot, c - 1)
    self.colRowLabels[c]:setText(string.format("r%02d", row))
    local v = seq[kHeldGetters[c]](seq, kSlot)
    self.colValueLabels[c]:setText(fmtFloat(v))
  end

  self.bpmLabel:setText(string.format("BPM %d", math.floor(seq:getBpm() + 0.5)))
end

function GridView:onShow()
  -- Refresh ~30 times per second while visible.
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

-- S1 toggles start/stop on slot 0.
function GridView:subReleased(i, shifted)
  if shifted then return false end
  local seq = app.AudioThread.getSequencerTask()
  if not seq then return false end

  if i == 1 then
    -- start/stop toggle
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
    -- reset slot 0: zero playheads, drop held values
    seq:resetSlot(kSlot)
    return true
  end
  return false
end

-- shift+ENTER: return to the standard scope sub-view.
function GridView:enterReleased(shifted)
  if shifted then
    local Channels = require "Channels"
    Channels.toggleSequencerSubView()
    return true
  end
  return false
end

-- Eat upReleased / cancelReleased so they don't escape the takeover.
function GridView:upReleased(shifted)
  return false
end

function GridView:cancelReleased(shifted)
  return false
end

function GridView:homeReleased()
  return false
end

return GridView

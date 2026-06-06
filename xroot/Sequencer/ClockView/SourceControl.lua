-- External clock source Control. Ply 1 of the SequencerClockView.
--
-- Main display: ComparatorView on the ext-clock comparator. Shows
-- the incoming gate state visually (Gate-pattern indicator) plus
-- the comparator's built-in rate readout (live BPM of the incoming
-- clock). This is the "typical gate input with comparator" surface
-- the user requested.
--
-- Sub display: GainBias-style layout with MiniScope at S1 area,
-- threshold readout at S2, globalDiv readout at S3 — keeping the
-- div fader on S3 per locked design. SubButtons:
--   S1 tap     -> Source picker (Source.Chooser, jacks tab).
--   S1 shifted -> int / ext mode toggle.
--   S2 tap     -> Focus threshold readout (encoder writes); tap
--                 again to open decimal keyboard.
--   S2 press / S2 release -> Manual fire (simulate rise / fall).
--                            Standard Gate ViewControl pattern,
--                            relocated to S2 because S3 is reserved
--                            for the div fader per locked design.
--   S3 tap     -> Focus globalDiv readout (encoder writes); tap
--                 again to open decimal keyboard.

local app = app
local Class = require "Base.Class"
local Encoder = require "Encoder"
local SpottedControl = require "SpottedStrip.Control"
local ClockBinding = require "Sequencer.ClockBinding"

local ply = app.SECTION_PLY

-- Standard ER-301 sub-display layout (mirrors Unit.ViewControl.GainBias
-- and SceneView.SceneSelectorControl so the readouts line up with
-- panel-paint positions).
local line1   = app.GRID5_LINE1
local line4   = app.GRID5_LINE4
local center1 = app.GRID5_CENTER1
local center3 = app.GRID5_CENTER3
local center4 = app.GRID5_CENTER4
local col1    = app.BUTTON1_CENTER
local col2    = app.BUTTON2_CENTER
local col3    = app.BUTTON3_CENTER

local CLOCK_INTERNAL = 0
local CLOCK_EXTERNAL = 1

-- Signal-flow sketch for the sub display (mirrors GainBias / Gate
-- so the layout feels familiar).
local subInstructions = app.DrawingInstructions()
subInstructions:circle(col2, center3, 8)
subInstructions:line(col2 - 3, center3 - 3, col2 + 3, center3 + 3)
subInstructions:line(col2 - 3, center3 + 3, col2 + 3, center3 - 3)
subInstructions:circle(col3, center3, 8)
subInstructions:hline(col3 - 5, col3 + 5, center3)
subInstructions:vline(col3, center3 - 5, center3 + 5)
subInstructions:hline(col1 + 20, col2 - 9, center3)
subInstructions:triangle(col2 - 12, center3, 0, 3)
subInstructions:hline(col2 + 9, col3 - 8, center3)
subInstructions:triangle(col3 - 11, center3, 0, 3)
subInstructions:vline(col3, center3 + 8, line1 - 2)
subInstructions:triangle(col3, line1 - 2, 90, 3)

local SourceControl = Class {}
SourceControl:include(SpottedControl)

function SourceControl:init()
  SpottedControl.init(self)
  self:setClassName("Sequencer.ClockView.SourceControl")
  self.seqTask = app.AudioThread.getSequencerTask()
  self.comparator = self.seqTask and self.seqTask:getExtClockComparator()

  self._divMap = app.LinearDialMap(1, 16)
  self._divMap:setSteps(5, 1, 0.25, 0.25)
  self._divMap:setRounding(1)

  local initialDiv = self.seqTask and self.seqTask:getGlobalDiv() or 1
  self._divParam = app.Parameter("globalDiv", initialDiv)

  -- Main display: ComparatorView wrapping the ext-clock comparator.
  if self.comparator then
    self.cv = app.ComparatorView(0, 0, ply, 64, self.comparator)
  else
    self.cv = app.Graphic(0, 0, ply, 64)
  end
  if self.cv.setLabel then self.cv:setLabel("clock") end
  if self.cv.setUnits then
    self.cv:setUnits(app.unitHertz)
    self.cv:setPrecision(2)
  end
  self:setControlGraphic(self.cv)
  self:setMainCursorController(self.cv)

  -- Right-edge vertical divider for ply border.
  self.verticalDivider = ply

  self:addSpotDescriptor{
    center = 0.5 * ply,
    radius = 0.5 * ply
  }

  -- Sub display.
  local sub = app.Graphic(0, 0, 128, 64)

  local drawing = app.Drawing(0, 0, 128, 64)
  drawing:add(subInstructions)
  sub:addChild(drawing)

  self.scope = app.MiniScope(col1 - 20, line4, 40, 45)
  self.scope:setBorder(1)
  self.scope:setCornerRadius(3, 3, 3, 3)
  sub:addChild(self.scope)

  if self.comparator then
    self._thresholdParam = self.comparator:getParameter("Threshold")
    self._thresholdParam:enableSerialization()
    self.thresholdReadout = app.Readout(0, 0, ply, 10)
    self.thresholdReadout:setParameter(self._thresholdParam)
    self.thresholdReadout:setCenter(col2, center4)
    self.thresholdReadout:setAttributes(app.unitNone, Encoder.getMap("default"))
    self.thresholdReadout:setPrecision(2)
    sub:addChild(self.thresholdReadout)
  end

  self.divReadout = app.Readout(0, 0, ply, 10)
  self.divReadout:setParameter(self._divParam)
  self.divReadout:setCenter(col3, center4)
  self.divReadout:setMap(self._divMap)
  self.divReadout:setUnits(app.unitNone)
  self.divReadout:setPrecision(0)
  sub:addChild(self.divReadout)

  self.descLabel = app.Label("clock", 10)
  self.descLabel:fitToText(3)
  self.descLabel:setSize(ply * 2, self.descLabel.mHeight)
  self.descLabel:setBorder(1)
  self.descLabel:setCornerRadius(3, 0, 0, 3)
  self.descLabel:setCenter(0.5 * (col2 + col3), center1 + 1)
  sub:addChild(self.descLabel)

  self.sourceButton = app.SubButton("source", 1)
  sub:addChild(self.sourceButton)
  self.threshButton = app.SubButton("thresh", 2)
  sub:addChild(self.threshButton)
  self.divButton = app.SubButton("div", 3)
  sub:addChild(self.divButton)

  self.menuGraphic = sub
  self.focusedReadout = nil
  self.encoderState = Encoder.Coarse

  self:_refreshLabels()
end

function SourceControl:_refreshLabels()
  local name = ClockBinding.getClockSourceName()
  if self.seqTask and self.seqTask:getClockSource() == CLOCK_EXTERNAL then
    self.descLabel:setText(name or "ext")
  else
    self.descLabel:setText("int")
  end
end

function SourceControl:_refreshScope()
  if not self.scope then return end
  local src = ClockBinding.getClockSource()
  if src and src.getOutlet then
    self.scope:watchOutlet(src:getOutlet())
  end
end

function SourceControl:onCursorEnter()
  if self.menuGraphic then self:addSubGraphic(self.menuGraphic) end
  self:grabFocus("subReleased", "subPressed")
  self:_refreshLabels()
  self:_refreshScope()
end

function SourceControl:onCursorLeave()
  self:_setFocusedReadout(nil)
  if self.menuGraphic then self:removeSubGraphic(self.menuGraphic) end
  self:releaseFocus("subReleased", "subPressed")
end

function SourceControl:_setFocusedReadout(readout)
  if self.focusedReadout == readout then return end
  if self.focusedReadout == nil and readout ~= nil then
    self:grabFocus("encoder", "upReleased", "cancelReleased",
                   "zeroPressed", "dialPressed")
    Encoder.set(self.encoderState)
  elseif self.focusedReadout ~= nil and readout == nil then
    self:releaseFocus("encoder", "upReleased", "cancelReleased",
                      "zeroPressed", "dialPressed")
    Encoder.set(Encoder.Neutral)
  end
  if readout then readout:save() end
  self.focusedReadout = readout
  self:setSubCursorController(readout)
end

function SourceControl:subReleased(i, shifted)
  if i == 1 then
    if shifted then
      if self.seqTask then
        local cur = self.seqTask:getClockSource()
        local next = (cur == CLOCK_EXTERNAL) and CLOCK_INTERNAL or CLOCK_EXTERNAL
        self.seqTask:setClockSource(next)
        self:_refreshLabels()
      end
      return true
    end
    local SourceChooser = require "Source.Chooser"
    local current = ClockBinding.getClockSource()
    local chooser = SourceChooser(nil, current)
    chooser:subscribe("choose", function(src)
      if src then ClockBinding.setClockSource(src)
      else ClockBinding.clearClockSource() end
      self:_refreshLabels()
      self:_refreshScope()
    end)
    chooser:show()
    return true
  elseif i == 2 then
    if shifted then return self:_thresholdSet() end
    if self.thresholdReadout then
      if self.focusedReadout == self.thresholdReadout then
        return self:_thresholdSet()
      end
      self:_setFocusedReadout(self.thresholdReadout)
    end
    -- Manual-fire falling edge ends the gate started on subPressed.
    if self.seqTask then self.seqTask:triggerClockFall() end
    return true
  elseif i == 3 then
    if shifted then return self:_divSet() end
    if self.focusedReadout == self.divReadout then
      return self:_divSet()
    end
    self:_setFocusedReadout(self.divReadout)
    return true
  end
  return false
end

function SourceControl:subPressed(i, shifted)
  if shifted then return false end
  if i == 2 and self.seqTask then
    self.seqTask:triggerClockRise()
    return true
  end
  return false
end

function SourceControl:encoder(change, shifted)
  if not self.focusedReadout then return false end
  self.focusedReadout:encoder(change, shifted,
                              self.encoderState == Encoder.Fine)
  if self.focusedReadout == self.divReadout then
    local v = math.floor(self._divParam:target() + 0.5)
    if v < 1 then v = 1 elseif v > 16 then v = 16 end
    if self.seqTask then self.seqTask:setGlobalDiv(v) end
  end
  return true
end

function SourceControl:upReleased(shifted)
  if self.focusedReadout then
    self:_setFocusedReadout(nil)
    return true
  end
  return false
end

function SourceControl:cancelReleased(shifted)
  if self.focusedReadout then
    self.focusedReadout:restore()
    self:_setFocusedReadout(nil)
    return true
  end
  return false
end

function SourceControl:zeroPressed()
  if self.focusedReadout then
    self.focusedReadout:zero()
    return true
  end
  return false
end

function SourceControl:dialPressed(shifted)
  if not self.focusedReadout then return false end
  self.encoderState = (self.encoderState == Encoder.Coarse) and Encoder.Fine or Encoder.Coarse
  Encoder.set(self.encoderState)
  return true
end

function SourceControl:_thresholdSet()
  if not self.thresholdReadout then return false end
  local Decimal = require "Keyboard.Decimal"
  local kb = Decimal {
    message = "Clock threshold.",
    commitMessage = "threshold updated.",
    initialValue = self.thresholdReadout:getValueInUnits()
  }
  local task = function(value)
    if value then
      self.thresholdReadout:save()
      self.thresholdReadout:setValueInUnits(value)
      self:_setFocusedReadout(nil)
    end
  end
  kb:subscribe("done", task)
  kb:subscribe("commit", task)
  kb:show()
  return true
end

function SourceControl:_divSet()
  local Decimal = require "Keyboard.Decimal"
  local kb = Decimal {
    message = "Global divider.",
    commitMessage = "div updated.",
    initialValue = self._divParam:target()
  }
  local task = function(value)
    if value then
      local v = math.floor(value + 0.5)
      if v < 1 then v = 1 elseif v > 16 then v = 16 end
      self._divParam:hardSet(v)
      if self.seqTask then self.seqTask:setGlobalDiv(v) end
      self:_setFocusedReadout(nil)
    end
  end
  kb:subscribe("done", task)
  kb:subscribe("commit", task)
  kb:show()
  return true
end

return SourceControl

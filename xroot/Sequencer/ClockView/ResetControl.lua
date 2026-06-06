-- Reset source Control. Ply 2 of the SequencerClockView.
--
-- Main display: ComparatorView on the ext-reset comparator. Same
-- "typical gate input" surface as the ext-clock ply, just for the
-- reset jack — shows gate state plus the comparator's built-in
-- rate readout.
--
-- Sub display: standard Gate-ViewControl layout.
--   S1 tap     -> Source picker.
--   S2 tap     -> Focus threshold readout; tap again -> decimal keyboard.
--   S2 shifted -> decimal keyboard for threshold.
--   S3 press / S3 release -> Manual fire (simulate rise / fall),
--                            standard Gate pattern.
--
-- No div fader here (reset has no divider concept).

local app = app
local Class = require "Base.Class"
local Encoder = require "Encoder"
local SpottedControl = require "SpottedStrip.Control"
local ClockBinding = require "Sequencer.ClockBinding"

local ply = app.SECTION_PLY

local line1   = app.GRID5_LINE1
local line4   = app.GRID5_LINE4
local center1 = app.GRID5_CENTER1
local center3 = app.GRID5_CENTER3
local center4 = app.GRID5_CENTER4
local col1    = app.BUTTON1_CENTER
local col2    = app.BUTTON2_CENTER
local col3    = app.BUTTON3_CENTER

-- Gate signal-flow sketch (mirrors Unit.ViewControl.Gate).
local subInstructions = app.DrawingInstructions()
subInstructions:box(col2 - 13, center3 - 8, 26, 16)
subInstructions:startPolyline(col2 - 8, center3 - 4, 0)
subInstructions:vertex(col2, center3 - 4)
subInstructions:vertex(col2, center3 + 4)
subInstructions:endPolyline(col2 + 8, center3 + 4)
subInstructions:color(app.GRAY3)
subInstructions:hline(col2 - 9, col2 + 9, center3)
subInstructions:color(app.WHITE)
subInstructions:circle(col3, center3, 8)
subInstructions:hline(col1 + 20, col2 - 13, center3)
subInstructions:triangle(col2 - 16, center3, 0, 3)
subInstructions:hline(col2 + 13, col3 - 8, center3)
subInstructions:triangle(col3 - 11, center3, 0, 3)
subInstructions:vline(col3, center3 + 8, line1 - 2)
subInstructions:triangle(col3, line1 - 2, 90, 3)
subInstructions:vline(col3, line4, center3 - 8)
subInstructions:triangle(col3, center3 - 11, 90, 3)

local ResetControl = Class {}
ResetControl:include(SpottedControl)

function ResetControl:init()
  SpottedControl.init(self)
  self:setClassName("Sequencer.ClockView.ResetControl")
  self.seqTask = app.AudioThread.getSequencerTask()
  self.comparator = self.seqTask and self.seqTask:getExtResetComparator()

  if self.comparator then
    self.cv = app.ComparatorView(0, 0, ply, 64, self.comparator)
  else
    self.cv = app.Graphic(0, 0, ply, 64)
  end
  if self.cv.setLabel then self.cv:setLabel("reset") end
  if self.cv.setUnits then
    self.cv:setUnits(app.unitHertz)
    self.cv:setPrecision(2)
  end
  self:setControlGraphic(self.cv)
  self:setMainCursorController(self.cv)
  self.verticalDivider = ply
  self:addSpotDescriptor{
    center = 0.5 * ply,
    radius = 0.5 * ply
  }

  local sub = app.Graphic(0, 0, 128, 64)

  local drawing = app.Drawing(0, 0, 128, 64)
  drawing:add(subInstructions)
  sub:addChild(drawing)

  -- "or" label at col3 (matches Gate.lua line 104-107: marks the OR
  -- gate where ext + manual-fire combine).
  local orLabel = app.Label("or", 10)
  orLabel:fitToText(0)
  orLabel:setCenter(col3, center3 + 1)
  sub:addChild(orLabel)

  self.scope = app.MiniScope(col1 - 20, line4, 40, 45)
  self.scope:setBorder(1)
  self.scope:setCornerRadius(3, 3, 3, 3)
  sub:addChild(self.scope)

  if self.comparator then
    self._thresholdParam = self.comparator:getParameter("Threshold")
    self._thresholdParam:enableSerialization()
    self.thresholdReadout = app.Readout(0, 0, ply, 10)
    self.thresholdReadout:setParameter(self._thresholdParam)
    self.thresholdReadout:setAttributes(app.unitNone, Encoder.getMap("default"))
    self.thresholdReadout:setCenter(col2, center4)
    self.thresholdReadout:setPrecision(2)
    sub:addChild(self.thresholdReadout)
  end

  self.descLabel = app.Label("reset", 10)
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
  self.fireButton = app.SubButton("fire", 3)
  sub:addChild(self.fireButton)

  self.menuGraphic = sub
  self.focusedReadout = nil
  self.encoderState = Encoder.Coarse

  self:_refreshLabels()
end

function ResetControl:_refreshLabels()
  local name = ClockBinding.getResetSourceName()
  self.descLabel:setText(name or "reset")
end

function ResetControl:_refreshScope()
  if not self.scope then return end
  local src = ClockBinding.getResetSource()
  if src and src.getOutlet then
    self.scope:watchOutlet(src:getOutlet())
  end
end

function ResetControl:onCursorEnter()
  if self.menuGraphic then self:addSubGraphic(self.menuGraphic) end
  self:grabFocus("subReleased", "subPressed")
  self:_refreshLabels()
  self:_refreshScope()
end

function ResetControl:onCursorLeave()
  self:_setFocusedReadout(nil)
  if self.menuGraphic then self:removeSubGraphic(self.menuGraphic) end
  self:releaseFocus("subReleased", "subPressed")
end

function ResetControl:_setFocusedReadout(readout)
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

function ResetControl:subReleased(i, shifted)
  if i == 1 then
    if shifted then return false end
    local SourceChooser = require "Source.Chooser"
    local current = ClockBinding.getResetSource()
    local chooser = SourceChooser(nil, current)
    chooser:subscribe("choose", function(src)
      if src then ClockBinding.setResetSource(src)
      else ClockBinding.clearResetSource() end
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
    return true
  elseif i == 3 then
    if shifted then return false end
    if self.seqTask then self.seqTask:triggerResetFall() end
    return true
  end
  return false
end

function ResetControl:subPressed(i, shifted)
  if shifted then return false end
  if i == 3 and self.seqTask then
    self.seqTask:triggerResetRise()
    return true
  end
  return false
end

function ResetControl:encoder(change, shifted)
  if not self.focusedReadout then return false end
  self.focusedReadout:encoder(change, shifted,
                              self.encoderState == Encoder.Fine)
  return true
end

function ResetControl:upReleased(shifted)
  if self.focusedReadout then
    self:_setFocusedReadout(nil)
    return true
  end
  return false
end

function ResetControl:cancelReleased(shifted)
  if self.focusedReadout then
    self.focusedReadout:restore()
    self:_setFocusedReadout(nil)
    return true
  end
  return false
end

function ResetControl:zeroPressed()
  if self.focusedReadout then
    self.focusedReadout:zero()
    return true
  end
  return false
end

function ResetControl:dialPressed(shifted)
  if not self.focusedReadout then return false end
  self.encoderState = (self.encoderState == Encoder.Coarse) and Encoder.Fine or Encoder.Coarse
  Encoder.set(self.encoderState)
  return true
end

function ResetControl:_thresholdSet()
  if not self.thresholdReadout then return false end
  local Decimal = require "Keyboard.Decimal"
  local kb = Decimal {
    message = "Reset threshold.",
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

return ResetControl

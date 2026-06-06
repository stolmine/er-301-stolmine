-- Reset source Control. Ply 2 of the SequencerClockView.
--
-- Main display: a fixed centered "reset" label. No fader; reset
-- has no settable value, just a rising-edge trigger.
-- Sub display:
--   S1: Source picker for the reset jack source.

local app = app
local Class = require "Base.Class"
local SpottedControl = require "SpottedStrip.Control"
local ClockBinding = require "Sequencer.ClockBinding"

local ply = app.SECTION_PLY

local subCenter1 = app.GRID5_CENTER1
local subCol2    = app.BUTTON2_CENTER
local subCol3    = app.BUTTON3_CENTER

local ResetControl = Class {}
ResetControl:include(SpottedControl)

function ResetControl:init()
  SpottedControl.init(self)
  self:setClassName("Sequencer.ClockView.ResetControl")
  self.seqTask = app.AudioThread.getSequencerTask()

  -- Plain centered label as the main display. A more elaborate
  -- "gate indicator" with edge-flash visualization can land in
  -- 6.7 once we have a real modular reset to observe.
  local mainGraphic = app.Graphic(0, 0, ply, 64)
  local label = app.Label("reset", 12)
  label:setJustification(app.justifyCenter)
  label:setSize(ply, 16)
  label:setCenter(ply * 0.5, 32)
  mainGraphic:addChild(label)
  self.mainGraphic = mainGraphic

  self:setControlGraphic(mainGraphic)
  self:addSpotDescriptor{
    center = 0.5 * ply,
    radius = 0.5 * ply
  }

  -- Sub display: source-picker button.
  local sub = app.Graphic(0, 0, 128, 64)

  self.sourceLabel = app.Label("---", 10)
  self.sourceLabel:fitToText(3)
  self.sourceLabel:setSize(ply * 2, self.sourceLabel.mHeight)
  self.sourceLabel:setBorder(1)
  self.sourceLabel:setCornerRadius(3, 3, 3, 3)
  self.sourceLabel:setCenter(0.5 * (subCol2 + subCol3), subCenter1 + 1)
  sub:addChild(self.sourceLabel)

  self.sourceButton = app.SubButton("source", 1)
  sub:addChild(self.sourceButton)

  self.menuGraphic = sub

  self:_refreshLabels()
end

function ResetControl:_refreshLabels()
  local name = ClockBinding.getResetSourceName()
  self.sourceLabel:setText(name or "---")
end

function ResetControl:onCursorEnter()
  if self.menuGraphic then self:addSubGraphic(self.menuGraphic) end
  self:grabFocus("subReleased")
  self:_refreshLabels()
end

function ResetControl:onCursorLeave()
  if self.menuGraphic then self:removeSubGraphic(self.menuGraphic) end
  self:releaseFocus("subReleased")
end

function ResetControl:subReleased(i, shifted)
  if shifted then return false end
  if i == 1 then
    local SourceChooser = require "Source.Chooser"
    local current = ClockBinding.getResetSource()
    local chooser = SourceChooser(nil, current)
    chooser:subscribe("choose", function(src)
      if src then
        ClockBinding.setResetSource(src)
      else
        ClockBinding.clearResetSource()
      end
      self:_refreshLabels()
    end)
    chooser:show()
    return true
  end
  return false
end

return ResetControl

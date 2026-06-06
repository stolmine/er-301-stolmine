-- Sequencer external-clock + reset settings view.
--
-- Phase 6.4. A 6-ply SpottedStrip Window invoked from AdminMode
-- (entry added in 6.5). One section, six controls left to right:
--
--   ply 1: external clock source + globalDiv fader (1..16) +
--          int/ext source toggle.
--   ply 2: external reset source.
--   plies 3-6: per-slot div (1..16), one per sequencer slot.
--
-- All state lives on SequencerTask (via getters / setters added
-- in 6.2) and the ClockBinding module (6.3). This Window is a
-- pure view: no state of its own beyond the per-control backing
-- Parameters that drive the Faders.

local app = app
local Class = require "Base.Class"
local SpottedStrip = require "SpottedStrip"
local Section = require "SpottedStrip.Section"

local SourceControl  = require "Sequencer.ClockView.SourceControl"
local ResetControl   = require "Sequencer.ClockView.ResetControl"
local SlotDivControl = require "Sequencer.ClockView.SlotDivControl"

local ClockView = Class {}
ClockView:include(SpottedStrip)

function ClockView:init()
  SpottedStrip.init(self)
  self:setClassName("Sequencer.ClockView")

  self:disableSelection()
  self.section = Section(app.sectionNoBorder)
  self.section:addView("default")
  self:appendSection(self.section)

  self.sourceControl = SourceControl()
  self.section:addControl("default", self.sourceControl)

  self.resetControl = ResetControl()
  self.section:addControl("default", self.resetControl)

  self.slotControls = {}
  for slotIdx = 0, 3 do
    local ctl = SlotDivControl(slotIdx)
    self.section:addControl("default", ctl)
    self.slotControls[slotIdx + 1] = ctl
  end

  self.section:rebuildView("default")
  self:setSelection(self.section, "default",
                    self.sourceControl:getSpotValue(1, "handle"))
  self:enableSelection()
end

-- Standard admin-sub-window egress (matches Sample.Pool.Interface +
-- GlobalChains.Interface). UP hides the view and returns control to
-- the AdminMode menu. The focused-control upReleased handlers
-- (SourceControl, ResetControl) grab focus first so a focused encoder
-- gets unfocused before the cancel bubbles up here.
function ClockView:upReleased(shifted)
  if not shifted then
    self:hide()
    self:emitSignal("done")
  end
  return true
end

function ClockView:homeReleased()
  self:hide()
  self:emitSignal("done")
  return true
end

function ClockView:cancelReleased(shifted)
  if not shifted then
    self:hide()
    self:emitSignal("done")
  end
  return true
end

return ClockView

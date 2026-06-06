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

return ClockView

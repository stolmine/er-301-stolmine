-- Per-slot divider Control. One instance per slot (plies 3-6 of
-- the SequencerClockView). Plain integer fader bound to
-- seqTask:getSlotDiv(slot) / setSlotDiv(slot, div).
--
-- Phase 6.4 — top-level only, no sub display, no scope, no
-- subchain dive (per the locked design: "Plies 3-6: per-slot
-- clock div faders, no modulation or subchains, just a top
-- level fader controlling an integer").

local app = app
local Class = require "Base.Class"
local Encoder = require "Encoder"
local SpottedControl = require "SpottedStrip.Control"

local ply = app.SECTION_PLY

local SlotDivControl = Class {}
SlotDivControl:include(SpottedControl)

-- slotIdx: 0..3.
function SlotDivControl:init(slotIdx)
  SpottedControl.init(self)
  self:setClassName("Sequencer.ClockView.SlotDivControl")
  self.slotIdx = slotIdx
  self.seqTask = app.AudioThread.getSequencerTask()

  -- Int [1, 16] map matching the larets clockDiv convention.
  -- Steps tuned so a single click moves by 1 (rounding = 1).
  self._map = app.LinearDialMap(1, 16)
  self._map:setSteps(5, 1, 0.25, 0.25)
  self._map:setRounding(1)

  -- Parameter backs the fader; encoder writes go through the
  -- Fader's bound parameter, then we sync to seqTask each
  -- encoder event so the audio thread sees the new divider.
  local initial = self.seqTask and self.seqTask:getSlotDiv(slotIdx) or 1
  self._param = app.Parameter(string.format("seq%d.div", slotIdx + 1),
                              initial)

  self.fader = app.Fader(0, 0, ply, 64)
  self.fader:setLabel(string.format("s%d", slotIdx + 1))
  self.fader:setParameter(self._param)
  self.fader:setMap(self._map)
  self.fader:setUnits(app.unitNone)
  self.fader:setPrecision(0)
  self:setControlGraphic(self.fader)
  self:setMainCursorController(self.fader)
  self.verticalDivider = ply

  self:addSpotDescriptor{
    center = 0.5 * ply,
    radius = 0.5 * ply
  }

  self._focused = false
end

function SlotDivControl:onCursorEnter()
  self:grabFocus("encoder", "zeroPressed", "cancelReleased")
  Encoder.set(Encoder.Coarse)
  self._focused = true
end

function SlotDivControl:onCursorLeave()
  self:releaseFocus("encoder", "zeroPressed", "cancelReleased")
  Encoder.set(Encoder.Neutral)
  self._focused = false
end

function SlotDivControl:encoder(change, shifted)
  if not self._focused then return false end
  self.fader:encoder(change, shifted, false)
  -- Param target is now the new int value (Map rounding clamps).
  -- Push to seqTask immediately for audio-thread visibility.
  local v = math.floor(self._param:target() + 0.5)
  if v < 1 then v = 1 elseif v > 16 then v = 16 end
  if self.seqTask then
    self.seqTask:setSlotDiv(self.slotIdx, v)
  end
  return true
end

function SlotDivControl:zeroPressed()
  if not self._focused then return false end
  self._param:hardSet(1)
  if self.seqTask then
    self.seqTask:setSlotDiv(self.slotIdx, 1)
  end
  return true
end

function SlotDivControl:cancelReleased(shifted)
  -- No restore semantics for a settings fader; let the parent
  -- handle (likely a "go back to admin menu" path).
  return false
end

return SlotDivControl

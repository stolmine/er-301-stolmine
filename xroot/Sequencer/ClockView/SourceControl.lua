-- External clock source Control. Ply 1 of the SequencerClockView.
--
-- Main display: globalDiv fader (int 1..16) using the larets
-- clockDiv pattern. The globalDiv divides the master event
-- stream BEFORE per-slot distribution.
-- Sub display:
--   S1: Source picker (Source.Chooser, jacks tab) — picks the
--       ext-clock source; binds it via ClockBinding.
--   S2: int/ext toggle — flips SequencerTask::clockSource.
--   S3: globalDiv readout (decimal entry shortcut).

local app = app
local Class = require "Base.Class"
local Encoder = require "Encoder"
local SpottedControl = require "SpottedStrip.Control"
local ClockBinding = require "Sequencer.ClockBinding"

local ply = app.SECTION_PLY

-- Sub-display layout (mirrors SceneSelectorControl).
local subLine1   = app.GRID5_LINE1
local subLine4   = app.GRID5_LINE4
local subCenter1 = app.GRID5_CENTER1
local subCenter3 = app.GRID5_CENTER3
local subCenter4 = app.GRID5_CENTER4
local subCol2    = app.BUTTON2_CENTER
local subCol3    = app.BUTTON3_CENTER

local CLOCK_INTERNAL = 0
local CLOCK_EXTERNAL = 1

local SourceControl = Class {}
SourceControl:include(SpottedControl)

function SourceControl:init()
  SpottedControl.init(self)
  self:setClassName("Sequencer.ClockView.SourceControl")
  self.seqTask = app.AudioThread.getSequencerTask()

  self._map = app.LinearDialMap(1, 16)
  self._map:setSteps(5, 1, 0.25, 0.25)
  self._map:setRounding(1)

  local initial = self.seqTask and self.seqTask:getGlobalDiv() or 1
  self._param = app.Parameter("globalDiv", initial)

  self.fader = app.Fader(0, 0, ply, 64)
  self.fader:setLabel("clock")
  self.fader:setParameter(self._param)
  self.fader:setMap(self._map)
  self.fader:setUnits(app.unitNone)
  self.fader:setPrecision(0)
  self:setControlGraphic(self.fader)
  self:setMainCursorController(self.fader)

  self:addSpotDescriptor{
    center = 0.5 * ply,
    radius = 0.5 * ply
  }

  -- Sub display: source-picker button + int/ext toggle + bias readout.
  local sub = app.Graphic(0, 0, 128, 64)

  -- Source label up top (current ext clock source name, or "---" if unbound).
  self.sourceLabel = app.Label("---", 10)
  self.sourceLabel:fitToText(3)
  self.sourceLabel:setSize(ply * 2, self.sourceLabel.mHeight)
  self.sourceLabel:setBorder(1)
  self.sourceLabel:setCornerRadius(3, 3, 3, 3)
  self.sourceLabel:setCenter(0.5 * (subCol2 + subCol3), subCenter1 + 1)
  sub:addChild(self.sourceLabel)

  -- Bias readout (globalDiv current value) at S3 position.
  self.biasReadout = app.Readout(0, 0, ply, 10)
  self.biasReadout:setParameter(self._param)
  self.biasReadout:setCenter(subCol3, subCenter4)
  self.biasReadout:setMap(self._map)
  self.biasReadout:setUnits(app.unitNone)
  self.biasReadout:setPrecision(0)
  sub:addChild(self.biasReadout)

  self.sourceButton = app.SubButton("source", 1)
  sub:addChild(self.sourceButton)
  self.modeButton = app.SubButton("int", 2)
  sub:addChild(self.modeButton)
  self.divButton = app.SubButton("div", 3)
  sub:addChild(self.divButton)

  self.menuGraphic = sub
  self._focused = false

  -- Sync display labels to current state.
  self:_refreshLabels()
end

function SourceControl:_refreshLabels()
  local name = ClockBinding.getClockSourceName()
  self.sourceLabel:setText(name or "---")
  if self.seqTask then
    if self.seqTask:getClockSource() == CLOCK_EXTERNAL then
      self.modeButton:setText("ext")
    else
      self.modeButton:setText("int")
    end
  end
end

function SourceControl:onCursorEnter()
  if self.menuGraphic then self:addSubGraphic(self.menuGraphic) end
  self:grabFocus("subReleased", "encoder", "zeroPressed", "cancelReleased")
  Encoder.set(Encoder.Coarse)
  self._focused = true
  self:_refreshLabels()
end

function SourceControl:onCursorLeave()
  if self.menuGraphic then self:removeSubGraphic(self.menuGraphic) end
  self:releaseFocus("subReleased", "encoder", "zeroPressed", "cancelReleased")
  Encoder.set(Encoder.Neutral)
  self._focused = false
end

function SourceControl:encoder(change, shifted)
  if not self._focused then return false end
  self.fader:encoder(change, shifted, false)
  local v = math.floor(self._param:target() + 0.5)
  if v < 1 then v = 1 elseif v > 16 then v = 16 end
  if self.seqTask then
    self.seqTask:setGlobalDiv(v)
  end
  return true
end

function SourceControl:zeroPressed()
  if not self._focused then return false end
  self._param:hardSet(1)
  if self.seqTask then
    self.seqTask:setGlobalDiv(1)
  end
  return true
end

function SourceControl:subReleased(i, shifted)
  if shifted then return false end
  if i == 1 then
    -- Source picker.
    local SourceChooser = require "Source.Chooser"
    local current = ClockBinding.getClockSource()
    -- Pass nil chain: only the jacks tab is useful for the ext
    -- clock; locals/globals would be confusing scope for a
    -- sequencer-global setting.
    local chooser = SourceChooser(nil, current)
    chooser:subscribe("choose", function(src)
      if src then
        ClockBinding.setClockSource(src)
      else
        ClockBinding.clearClockSource()
      end
      self:_refreshLabels()
    end)
    chooser:show()
    return true
  elseif i == 2 then
    -- int/ext toggle.
    if self.seqTask then
      local cur = self.seqTask:getClockSource()
      if cur == CLOCK_EXTERNAL then
        self.seqTask:setClockSource(CLOCK_INTERNAL)
      else
        self.seqTask:setClockSource(CLOCK_EXTERNAL)
      end
      self:_refreshLabels()
    end
    return true
  elseif i == 3 then
    -- Decimal entry for globalDiv.
    local Decimal = require "Keyboard.Decimal"
    local kb = Decimal {
      message = "Global divider.",
      commitMessage = "div updated.",
      initialValue = self._param:target()
    }
    local task = function(value)
      if value then
        local v = math.floor(value + 0.5)
        if v < 1 then v = 1 elseif v > 16 then v = 16 end
        self._param:hardSet(v)
        if self.seqTask then
          self.seqTask:setGlobalDiv(v)
        end
      end
    end
    kb:subscribe("done", task)
    kb:subscribe("commit", task)
    kb:show()
    return true
  end
  return false
end

return SourceControl

-- M1Control: the leftmost SpottedControl in the hold-mode
-- Performance view. Wraps the chain's scene-CV GainBias output
-- as a full-height bias fader with a GainBias-style sub display
-- (gain readout + bias readout + scope + branch-dive button).
--
-- Coexists with N SceneSlotControl (one per scene) + PlusControl
-- inside Performance's single SpottedStrip Section.
--
-- Focus model: cursor landing on M1 via M-tap auto-focuses the
-- bias readout (encoder writes immediately, ▶ caret on main +
-- sub). Tap again to unfocus, tap again to re-focus.
-- Encoder-driven navigation onto M1 does NOT auto-focus -- the
-- user is just panning through.
--
-- S-key bindings while M1 is focused:
--   S1: dive into the scene-cv branch (user inserts CV / LFO /
--       S&H / whatever to modulate the crossfade weight).
--   S2: focus gain readout. Second tap = decimal keyboard.
--   S3: focus bias readout. Second tap = decimal keyboard.
-- Shifted:
--   S2: decimal keyboard for gain.
--   S3: decimal keyboard for bias.

local app = app
local Class = require "Base.Class"
local Encoder = require "Encoder"
local Signal = require "Signal"
local SpottedControl = require "SpottedStrip.Control"

local ply = app.SECTION_PLY

-- Sub-display layout constants (mirror Unit.ViewControl.GainBias
-- so the readout / scope / arrow diagram lines up with the
-- panel-paint positions of S1/S2/S3).
local subLine1   = app.GRID5_LINE1
local subLine4   = app.GRID5_LINE4
local subCenter1 = app.GRID5_CENTER1
local subCenter3 = app.GRID5_CENTER3
local subCenter4 = app.GRID5_CENTER4
local subCol1    = app.BUTTON1_CENTER
local subCol2    = app.BUTTON2_CENTER
local subCol3    = app.BUTTON3_CENTER

-- The mul + sum diagram instructions. Built once at module load
-- since they never change.
local subInstructions = app.DrawingInstructions()
subInstructions:circle(subCol2, subCenter3, 8)
subInstructions:line(subCol2 - 3, subCenter3 - 3,
                     subCol2 + 3, subCenter3 + 3)
subInstructions:line(subCol2 - 3, subCenter3 + 3,
                     subCol2 + 3, subCenter3 - 3)
subInstructions:circle(subCol3, subCenter3, 8)
subInstructions:hline(subCol3 - 5, subCol3 + 5, subCenter3)
subInstructions:vline(subCol3, subCenter3 - 5, subCenter3 + 5)
subInstructions:hline(subCol1 + 20, subCol2 - 9, subCenter3)
subInstructions:triangle(subCol2 - 12, subCenter3, 0, 3)
subInstructions:hline(subCol2 + 9, subCol3 - 8, subCenter3)
subInstructions:triangle(subCol3 - 11, subCenter3, 0, 3)
subInstructions:vline(subCol3, subCenter3 + 8, subLine1 - 2)
subInstructions:triangle(subCol3, subLine1 - 2, 90, 3)

local M1Control = Class {}
M1Control:include(SpottedControl)

function M1Control:init(chain)
  SpottedControl.init(self)
  self:setClassName("SceneView.M1Control")
  self.chain = chain

  -- Main-display fader. Bound to the chain's scene-CV GainBias
  -- Bias Parameter. Full ply width / 64 height -- the section
  -- will setPosition it; we just declare local geometry.
  self.cvFader = app.Fader(0, 0, ply, 64)
  self.cvFader:setLabel("xfade")
  if chain and chain.getSceneCVGainBias then
    local gb = chain:getSceneCVGainBias()
    self._gainParam = gb:getParameter("Gain")
    self._biasParam = gb:getParameter("Bias")
    self._gainParam:enableSerialization()
    self._biasParam:enableSerialization()
    self._biasMap = app.LinearDialMap(-1, 1)
    self._biasMap:setSteps(0.5, 0.1, 0.01, 0.001)
    self.cvFader:setParameter(self._biasParam)
    self.cvFader:setMap(self._biasMap)
    self.cvFader:setUnits(app.unitNone)
    self.cvFader:setPrecision(2)
    -- A / B substitutions at the endpoints (same prior art as
    -- Plaits / Canals / Rings).
    self.cvFader:setTextAbove(0.999, "A")
    self.cvFader:setTextBelow(-0.999, "B")
    if chain.getSceneCVRange then
      local range = chain:getSceneCVRange()
      if range then self.cvFader:setRangeObject(range) end
    end
  end
  self:setControlGraphic(self.cvFader)

  -- One spot, ply-wide, centered on the fader.
  self:addSpotDescriptor{
    center = 0.5 * ply,
    radius = 0.5 * ply
  }

  -- Sub display: GainBias-style. Held in self.menuGraphic and
  -- swapped in / out by onCursorEnter / onCursorLeave.
  local sub = app.Graphic(0, 0, 128, 64)
  if self._biasParam then
    local drawing = app.Drawing(0, 0, 128, 64)
    drawing:add(subInstructions)
    sub:addChild(drawing)

    self.scope = app.MiniScope(subCol1 - 20, subLine4, 40, 45)
    self.scope:setBorder(1)
    self.scope:setCornerRadius(3, 3, 3, 3)
    sub:addChild(self.scope)

    self.gainReadout = app.Readout(0, 0, ply, 10)
    self.gainReadout:setParameter(self._gainParam)
    self.gainReadout:setCenter(subCol2, subCenter4)
    self.gainReadout:setMap(Encoder.getMap("gain"))
    self.gainReadout:setUnits(app.unitNone)
    self.gainReadout:setPrecision(2)
    sub:addChild(self.gainReadout)

    self.biasReadout = app.Readout(0, 0, ply, 10)
    self.biasReadout:setParameter(self._biasParam)
    self.biasReadout:setCenter(subCol3, subCenter4)
    self.biasReadout:setMap(self._biasMap)
    self.biasReadout:setUnits(app.unitNone)
    self.biasReadout:setPrecision(2)
    self.biasReadout:setTextAbove(0.999, "A")
    self.biasReadout:setTextBelow(-0.999, "B")
    sub:addChild(self.biasReadout)

    local desc = app.Label("X-fade", 10)
    desc:fitToText(3)
    desc:setSize(ply * 2, desc.mHeight)
    desc:setBorder(1)
    desc:setCornerRadius(3, 0, 0, 3)
    desc:setCenter(0.5 * (subCol2 + subCol3), subCenter1 + 1)
    sub:addChild(desc)

    self.modButton = app.SubButton("empty", 1)
    sub:addChild(self.modButton)
    self.gainButton = app.SubButton("gain", 2)
    self.biasButton = app.SubButton("bias", 3)
    sub:addChild(self.gainButton)
    sub:addChild(self.biasButton)
  end
  self.menuGraphic = sub

  self.gainEncoderState = Encoder.Coarse
  self.biasEncoderState = Encoder.Coarse
  self.focusedReadout = nil  -- nil / self.gainReadout / self.biasReadout

  -- contentChanged subscription: keeps the mod button label +
  -- scope outlet in sync with what the user has wired into the
  -- scene-CV branch. Performance forwards the chain's
  -- contentChanged Signal to us via :contentChanged.
end

-- Called by Performance when the scene-CV branch contents
-- change (user inserts / removes / focuses a CV source unit
-- inside the dive).
function M1Control:contentChanged()
  if not self.chain or not self.chain.getSceneCVBranch then return end
  local branch = self.chain:getSceneCVBranch()
  if branch == nil then return end
  if self.modButton then
    self.modButton:setText(branch:mnemonic())
  end
  if self.scope then
    local out = branch:getMonitoringOutput(1)
    self.scope:watchOutlet(out)
  end
end

function M1Control:onCursorEnter()
  if self.menuGraphic then self:addSubGraphic(self.menuGraphic) end
  self:grabFocus("subReleased")
end

function M1Control:onCursorLeave()
  -- Unfocus any inner readout so the encoder isn't still routed
  -- to bias / gain after the cursor moves to a slot.
  self:_setFocusedReadout(nil)
  if self.menuGraphic then self:removeSubGraphic(self.menuGraphic) end
  self:releaseFocus("subReleased")
end

-- Tap-tap focus cycle on the main M1 button:
--   First tap (isFocusedPress == false, cursor just landed):
--     auto-focus bias readout. Matches the .21 user-edit gesture
--     where clicking a GainBias control's M-key auto-grabs bias.
--   Second tap (isFocusedPress == true) while focused: unfocus.
--   Third tap (isFocusedPress == true) while unfocused: re-focus
--     bias. (toggle from here.)
function M1Control:spotPressed(spotIndex, shifted, isFocusedPress)
  if shifted then return end
  if not isFocusedPress then
    -- Cursor just moved to M1 via M-tap (not encoder navigation,
    -- which doesn't fire spotPressed). Auto-focus bias.
    self:_setFocusedReadout(self.biasReadout)
    return
  end
  -- isFocusedPress == true: already on M1.
  if self.focusedReadout then
    self:_setFocusedReadout(nil)
  else
    self:_setFocusedReadout(self.biasReadout)
  end
end

function M1Control:subReleased(i, shifted)
  if shifted then
    if i == 2 then return self:_gainSet() end
    if i == 3 then return self:_biasSet() end
    return false
  end
  if i == 1 then
    return self:callUp("diveSceneCV")
  elseif i == 2 then
    if self.focusedReadout == self.gainReadout then
      return self:_gainSet()
    end
    self:_setFocusedReadout(self.gainReadout)
    return true
  elseif i == 3 then
    if self.focusedReadout == self.biasReadout then
      return self:_biasSet()
    end
    self:_setFocusedReadout(self.biasReadout)
    return true
  end
  return false
end

-- Focused readout handlers grabbed via grabFocus.
function M1Control:encoder(change, shifted)
  if self.focusedReadout == nil then return false end
  local fine
  if self.focusedReadout == self.gainReadout then
    fine = (self.gainEncoderState == Encoder.Fine)
  else
    fine = (self.biasEncoderState == Encoder.Fine)
  end
  self.focusedReadout:encoder(change, shifted, fine)
  return true
end

function M1Control:upReleased(shifted)
  if self.focusedReadout then
    self:_setFocusedReadout(nil)
    return true
  end
  return false
end

function M1Control:cancelReleased(shifted)
  if self.focusedReadout then
    self.focusedReadout:restore()
    return true
  end
  return false
end

function M1Control:zeroPressed()
  if self.focusedReadout then
    self.focusedReadout:zero()
    return true
  end
  return false
end

function M1Control:dialPressed(shifted)
  if self.focusedReadout == self.gainReadout then
    if self.gainEncoderState == Encoder.Coarse then
      self.gainEncoderState = Encoder.Fine
    else
      self.gainEncoderState = Encoder.Coarse
    end
    Encoder.set(self.gainEncoderState)
    return true
  elseif self.focusedReadout == self.biasReadout then
    if self.biasEncoderState == Encoder.Coarse then
      self.biasEncoderState = Encoder.Fine
    else
      self.biasEncoderState = Encoder.Coarse
    end
    Encoder.set(self.biasEncoderState)
    return true
  end
  return false
end

------------------------------------------------------------

function M1Control:_setFocusedReadout(readout)
  if self.focusedReadout == readout then return end
  if self.focusedReadout == nil and readout ~= nil then
    -- about to focus: grab encoder + up + cancel.
    self:grabFocus("encoder", "upReleased", "cancelReleased",
                   "zeroPressed", "dialPressed")
    if readout == self.gainReadout then
      Encoder.set(self.gainEncoderState)
    else
      Encoder.set(self.biasEncoderState)
    end
  elseif self.focusedReadout ~= nil and readout == nil then
    self:releaseFocus("encoder", "upReleased", "cancelReleased",
                      "zeroPressed", "dialPressed")
    Encoder.set(Encoder.Neutral)
  elseif self.focusedReadout ~= nil and readout ~= nil then
    if readout == self.gainReadout then
      Encoder.set(self.gainEncoderState)
    else
      Encoder.set(self.biasEncoderState)
    end
  end
  if readout then readout:save() end
  self.focusedReadout = readout
end

function M1Control:_gainSet()
  local Decimal = require "Keyboard.Decimal"
  local kb = Decimal {
    message = "Crossfader gain.",
    commitMessage = "gain updated.",
    initialValue = self.gainReadout:getValueInUnits()
  }
  local task = function(value)
    if value then
      self.gainReadout:save()
      self.gainReadout:setValueInUnits(value)
      self:_setFocusedReadout(nil)
    end
  end
  kb:subscribe("done", task)
  kb:subscribe("commit", task)
  kb:show()
  return true
end

function M1Control:_biasSet()
  local Decimal = require "Keyboard.Decimal"
  local kb = Decimal {
    message = "Crossfader bias.",
    commitMessage = "bias updated.",
    initialValue = self.biasReadout:getValueInUnits()
  }
  local task = function(value)
    if value then
      self.biasReadout:save()
      self.biasReadout:setValueInUnits(value)
      self:_setFocusedReadout(nil)
    end
  end
  kb:subscribe("done", task)
  kb:subscribe("commit", task)
  kb:show()
  return true
end

return M1Control

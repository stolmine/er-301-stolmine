-- SceneSelectorControl: per-role A/B selector ply in the hold-mode
-- Performance view (v1.1). Lives between M1Control (morph) and
-- the scene bank, parameterized by role string "A" or "B".
--
-- Backed by a chain-owned SceneIndexArbiter. Encoder + Bias readout
-- writes go through arbiter:hardSetBias (which forces Tracking-
-- Manual and latches the CV-at-entry Schmitt baseline). CV input
-- arrives via the dive subchain that wraps arbiter.In; the arbiter
-- arbitrates between CV and manual using its state machine.
--
-- Main fader visualization mirrors the habitat ModeSelector
-- pattern (mods/biome/assets/ModeSelector.lua): after each input
-- event the fader label is set to the current scene's name via
-- :setLabel(). 5.4 phase: control renders + writes arbiter.Bias;
-- audio still flows through the v1.0 SceneView:setCrossfaderA/B
-- path so chip taps remain functional. 5.5 will rewire the
-- morpher to consume arbiter.Out directly and the SceneView
-- crossfader becomes computed from round(arbiter.out).

local app = app
local Class = require "Base.Class"
local Encoder = require "Encoder"
local SpottedControl = require "SpottedStrip.Control"

local ply = app.SECTION_PLY

-- Sub-display layout constants (match M1Control + Unit.ViewControl.GainBias).
local subLine1   = app.GRID5_LINE1
local subLine4   = app.GRID5_LINE4
local subCenter1 = app.GRID5_CENTER1
local subCenter3 = app.GRID5_CENTER3
local subCenter4 = app.GRID5_CENTER4
local subCol1    = app.BUTTON1_CENTER
local subCol2    = app.BUTTON2_CENTER
local subCol3    = app.BUTTON3_CENTER

-- Same gain x CV diagram instructions M1Control draws; recreated
-- here so M1Control's local subInstructions doesn't have to be
-- exposed.
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

local SceneSelectorControl = Class {}
SceneSelectorControl:include(SpottedControl)

-- chain: the Chain.Root owning the arbiter.
-- role: "A" or "B".
-- sceneView: passed in for getSceneCount / getScene(idx):getName().
function SceneSelectorControl:init(chain, role, sceneView)
  SpottedControl.init(self)
  self:setClassName("SceneView.SceneSelectorControl")
  self.chain = chain
  self.role = role
  self.sceneView = sceneView

  -- Main fader bound to arbiter.Bias. kIndex semantics: Bias is
  -- a [0, 1] normalized fader position (fraction of bank). The
  -- arbiter scales by mSceneCount at output time and clips to
  -- [0, N]. Fader visual range is bank-independent so adding /
  -- removing scenes never changes the encoder feel; the label
  -- (via _updateLabel) shows the current scene name at the
  -- bank-scaled rounded output position.
  self.cvFader = app.Fader(0, 0, ply, 64)
  self.cvFader:setLabel(role)
  self.arbiter = chain and chain.getSceneArbiter and chain:getSceneArbiter(role)
  if self.arbiter then
    self._gainParam = self.arbiter:getParameter("Gain")
    self._biasParam = self.arbiter:getParameter("Bias")
    self._gainParam:enableSerialization()
    self._biasParam:enableSerialization()
    -- Standard [0, 1] "unit" dial map (coarse 0.1, fine 0.01,
    -- super-fine 0.001). Fractional bias is valid stored state:
    -- audible output is round(Bias * N), so a slow CV-driven
    -- sweep can glide the fader visually between integer scene
    -- positions without immediately switching scenes.
    self._biasMap = Encoder.getMap("unit")
    self.cvFader:setParameter(self._biasParam)
    self.cvFader:setMap(self._biasMap)
    self.cvFader:setUnits(app.unitNone)
    self.cvFader:setPrecision(2)
    if chain.getSceneCVRange then
      local range = chain:getSceneCVRange(role)
      if range then self.cvFader:setRangeObject(range) end
    end
  end
  self:setControlGraphic(self.cvFader)
  self:setMainCursorController(self.cvFader)

  self:addSpotDescriptor{
    center = 0.5 * ply,
    radius = 0.5 * ply
  }

  -- Sub display. Same three-slot layout as M1: dive (S1), Gain
  -- readout (S2), Bias readout (S3) plus scope + diagram + role
  -- label.
  local sub = app.Graphic(0, 0, 128, 64)
  if self._biasParam then
    local drawing = app.Drawing(0, 0, 128, 64)
    drawing:add(subInstructions)
    sub:addChild(drawing)

    self.scope = app.MiniScope(subCol1 - 20, subLine4, 40, 45)
    self.scope:setBorder(1)
    self.scope:setCornerRadius(3, 3, 3, 3)
    sub:addChild(self.scope)

    -- Standard +-10 gain map. With Bias / CV in normalized [0, 1]
    -- domain, Gain=1 means "full input swing = full bank"; Gain=2
    -- means "half swing = full bank" (good for LFOs that only
    -- reach +-0.5). Wider range isn't musically useful in kIndex.
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
    sub:addChild(self.biasReadout)

    local desc = app.Label(role, 10)
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
  self.focusedReadout = nil

  -- Initial label refresh.
  self:_updateLabel()
end

------------------------------------------------------------
-- ModeSelector-style fader label refresh. Pulls the scene name
-- at the current rounded Bias position from SceneView. Called
-- on init, after every input event, and whenever Performance
-- refreshes (scene add / rename / delete).

function SceneSelectorControl:_updateLabel()
  if not (self.cvFader and self._biasParam) then return end
  if self.sceneView == nil then
    self.cvFader:setLabel(self.role)
    return
  end
  -- kIndex: Bias is [0, 1]. Output position is the same math the
  -- arbiter does -- round(bias * N) with bank-clip on either end.
  local n = self.sceneView:getSceneCount()
  if n <= 0 then
    self.cvFader:setLabel(self.role)
    return
  end
  local idx = math.floor(self._biasParam:value() * n + 0.5)
  if idx < 1 then idx = 1
  elseif idx > n then idx = n end
  local scene = self.sceneView:getScene(idx)
  if scene then
    self.cvFader:setLabel(scene:getName() or self.role)
  else
    self.cvFader:setLabel(self.role)
  end
end

-- Called by Performance after the scene-CV branch contents
-- change (user inserts / removes / focuses a CV source unit
-- inside the role's dive).
function SceneSelectorControl:contentChanged()
  if not self.chain or not self.chain.getSceneCVBranch then return end
  local branch = self.chain:getSceneCVBranch(self.role)
  if branch == nil then return end
  if self.modButton then
    self.modButton:setText(branch:mnemonic())
  end
  if self.scope then
    local out = branch:getMonitoringOutput(1)
    self.scope:watchOutlet(out)
  end
end

function SceneSelectorControl:onCursorEnter()
  if self.menuGraphic then self:addSubGraphic(self.menuGraphic) end
  self:grabFocus("subReleased")
end

function SceneSelectorControl:onCursorLeave()
  self:_setFocusedReadout(nil)
  if self.menuGraphic then self:removeSubGraphic(self.menuGraphic) end
  self:releaseFocus("subReleased")
end

-- Tap-tap focus cycle on the main M-key. Same pattern M1 uses
-- (.55 auto-focus behavior).
function SceneSelectorControl:spotPressed(spotIndex, shifted, isFocusedPress)
  if shifted then return end
  if not isFocusedPress then
    self:_setFocusedReadout(self.biasReadout)
    return
  end
  if self.focusedReadout then
    self:_setFocusedReadout(nil)
  else
    self:_setFocusedReadout(self.biasReadout)
  end
end

function SceneSelectorControl:subReleased(i, shifted)
  if shifted then
    if i == 2 then return self:_gainSet() end
    if i == 3 then return self:_biasSet() end
    return false
  end
  if i == 1 then
    return self:callUp("diveSceneCV", self.role)
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

function SceneSelectorControl:encoder(change, shifted)
  if self.focusedReadout == nil then return false end
  local fine
  if self.focusedReadout == self.gainReadout then
    fine = (self.gainEncoderState == Encoder.Fine)
  else
    fine = (self.biasEncoderState == Encoder.Fine)
  end
  self.focusedReadout:encoder(change, shifted, fine)
  -- Arbiter state-machine relatch. Readout writes via softSet
  -- (ramps mValue toward mTarget over 50 audio frames), so we
  -- read :target() not :value() -- the latter would still hold
  -- the stale pre-encoder value and we'd hardSet bias back to
  -- it, undoing the encoder write. hardSetBias also re-latches
  -- mCVInputAtEntry + mGainAtEntry from the current arbiter
  -- state, which is what we want on a Gain change too so the
  -- Schmitt threshold reflects the new Gain.
  if self.arbiter then
    self.arbiter:hardSetBias(self._biasParam:target())
  end
  self:_updateLabel()
  -- 5.4 dual-write: notify Performance so the v1.0 SceneView
  -- crossfader stays in sync with the arbiter Bias. With kIndex
  -- semantics, Bias is in [0, 1] and the SceneView crossfader
  -- wants an integer scene index -- convert via round(Bias * N).
  -- 5.5b drops this when chip-tap rewires to write arbiter
  -- directly.
  local n = self.sceneView and self.sceneView:getSceneCount() or 0
  local sceneIdx = math.floor(self._biasParam:target() * n + 0.5)
  if sceneIdx < 0 then sceneIdx = 0
  elseif sceneIdx > n then sceneIdx = n end
  self:callUp("syncSceneCrossfader", self.role, sceneIdx)
  return true
end

function SceneSelectorControl:upReleased(shifted)
  if self.focusedReadout then
    self:_setFocusedReadout(nil)
    return true
  end
  return false
end

function SceneSelectorControl:cancelReleased(shifted)
  if self.focusedReadout then
    self.focusedReadout:restore()
    return true
  end
  return false
end

function SceneSelectorControl:zeroPressed()
  if self.focusedReadout then
    self.focusedReadout:zero()
    return true
  end
  return false
end

function SceneSelectorControl:dialPressed(shifted)
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

function SceneSelectorControl:_setFocusedReadout(readout)
  if self.focusedReadout == readout then return end
  if self.focusedReadout == nil and readout ~= nil then
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
  self:setSubCursorController(readout)
end

function SceneSelectorControl:_gainSet()
  local Decimal = require "Keyboard.Decimal"
  local kb = Decimal {
    message = self.role .. " gain.",
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

function SceneSelectorControl:_biasSet()
  local Decimal = require "Keyboard.Decimal"
  local kb = Decimal {
    message = self.role .. " bias (0 to 1).",
    commitMessage = "bias updated.",
    initialValue = self.biasReadout:getValueInUnits()
  }
  local task = function(value)
    if value then
      self.biasReadout:save()
      self.biasReadout:setValueInUnits(value)
      if self.arbiter then
        self.arbiter:hardSetBias(value)
      end
      self:_updateLabel()
      local n = self.sceneView and self.sceneView:getSceneCount() or 0
      local sceneIdx = math.floor(value * n + 0.5)
      if sceneIdx < 0 then sceneIdx = 0
      elseif sceneIdx > n then sceneIdx = n end
      self:callUp("syncSceneCrossfader", self.role, sceneIdx)
      self:_setFocusedReadout(nil)
    end
  end
  kb:subscribe("done", task)
  kb:subscribe("commit", task)
  kb:show()
  return true
end

return SceneSelectorControl

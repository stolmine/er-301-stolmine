local Class = require "Base.Class"
local Chain = require "Chain"
local ScopeView = require "Chain.ScopeView"
local PinView = require "PinView"
local SequencerView = require "Sequencer.GridView"

local Root = Class {}
Root:include(Chain)

function Root:init(args)
  Chain.init(self, args)
  self:setClassName("Chain.Root")
  self.isRoot = true
  self.scopeView = ScopeView(self)
  self.pinView = PinView(self)
  self.sequencerView = SequencerView(self)
  -- SceneView state container is created LAZILY (see getSceneView).
  -- The scene mode rework is in-development; users with scene
  -- mode never enabled pay zero boot cost from it. The state
  -- container itself is cheap, but lazy avoids any chance of an
  -- in-flight SceneView change side-effecting the chain init path.
end

function Root:getSceneView()
  if self.sceneView == nil then
    local SceneView = require "SceneView"
    self.sceneView = SceneView(self)
  end
  return self.sceneView
end

function Root:getRootChain()
  return self
end

function Root:addPinSet(name)
  return self.pinView:addPinSet(name)
end

function Root:suggestPinSetName()
  return self.pinView:suggestPinSetName()
end

function Root:getPinSetByName(name)
  return self.pinView:getPinSetByName(name)
end

function Root:getPinSetMembership(control)
  return self.pinView:getPinSetMembership(control)
end

function Root:getPinSetNames(optionalControl)
  return self.pinView:getPinSetNames(optionalControl)
end

function Root:pinControlToAllPinSets(control)
  self.pinView:pinControlToAllPinSets(control)
end

function Root:unpinControlFromAllPinSets(control)
  self.pinView:unpinControlFromAllPinSets(control)
end

function Root:serializePins()
  return self.pinView:serialize()
end

function Root:deserializePins(data)
  self.pinView:deserialize(data)
end

function Root:serialize()
  local t = Chain.serialize(self)
  t.pinView = self.pinView:serialize()
  -- Only serialize scene state if SceneView has actually been
  -- created (user enabled scene mode at some point). Lazy init
  -- means most users get nothing extra written to their presets.
  if self.sceneView then
    t.sceneView = self.sceneView:serialize()
  end
  return t
end

function Root:deserialize(t)
  Chain.deserialize(self, t)
  if t.pinView then
    self.pinView:deserialize(t.pinView)
  else
    self.pinView:removeAllPinSets()
  end
  if t.sceneView then
    -- Force-create SceneView only if the preset actually carries
    -- scene state. Restores the data verbatim.
    self:getSceneView():deserialize(t.sceneView)
  end
end

function Root:pin(control, pinSetName)
  self.pinView:pin(control, pinSetName)
end

function Root:unpin(control, pinSetName)
  self.pinView:unpin(control, pinSetName)
end

function Root:enterHoldMode()
end

function Root:leaveHoldMode()
end

-- Arm every delta-able control in the chain for scene authoring.
-- Walks all units; for each control that exposes enterSceneMode,
-- builds a per-scene target parameter (initialized to the scene's
-- existing delta if one exists, else to the control's current
-- live value) and tells the control to swap its widget's control
-- parameter to that target. Audio doesn't change; the live value
-- parameter still holds the base value. The user's encoder edits
-- inside scene authoring write to the per-scene target.
--
-- Per-control enter/exitSceneMode methods land in 3b.3+; until
-- then this walk finds nothing to arm and is effectively a state-
-- tracking no-op. Lifecycle wiring is in place so 3b.2 (dive
-- routing) can hook in.
function Root:enterSceneAuthoring(sceneView, sceneIdx)
  if self.activeAuthoringScene then return end  -- already armed
  local scene = sceneView:getScene(sceneIdx)
  if scene == nil then return end
  self.activeAuthoringScene = scene
  self.activeAuthoringIdx   = sceneIdx
  self._sceneTargetParams   = {}
  -- Header indicator so the user knows they're editing scene N,
  -- not making live audio-path changes. Cleared on exit.
  self:setSubTitle("editing " .. (scene.name or string.format("S%d", sceneIdx)))

  for i = 1, self:length() do
    local unit = self:getUnit(i)
    if unit and unit.controls then
      local unitKey = unit:getInstanceKey()
      self._sceneTargetParams[unitKey] = {}
      for ctrlId, control in pairs(unit.controls) do
        if control.enterSceneMode then
          local baseVal  = control:getSceneBaseValue()
          local deltaVal = scene:getDelta(unitKey, ctrlId) or baseVal
          local targetParam = app.Parameter(ctrlId .. "_scene", deltaVal)
          self._sceneTargetParams[unitKey][ctrlId] = targetParam
          control:enterSceneMode(targetParam)
        end
      end
    end
  end
end

-- Restore every armed control to its pre-scene state and capture
-- each per-scene target value back into the scene's delta map.
-- Only values that differ from the live base become deltas;
-- equal-to-base targets are cleared so the scene's delta count
-- stays meaningful (no-op deltas don't clutter the map).
function Root:exitSceneAuthoring()
  if self.activeAuthoringScene == nil then return end
  local scene = self.activeAuthoringScene

  for i = 1, self:length() do
    local unit = self:getUnit(i)
    if unit and unit.controls then
      local unitKey = unit:getInstanceKey()
      for ctrlId, control in pairs(unit.controls) do
        if control.exitSceneMode and control.getSceneTargetValue then
          local targetVal = control:getSceneTargetValue()
          local baseVal   = control:getSceneBaseValue()
          if math.abs(targetVal - baseVal) > 1e-6 then
            scene:setDelta(unitKey, ctrlId, targetVal)
          else
            scene:setDelta(unitKey, ctrlId, nil)
          end
          control:exitSceneMode()
        end
      end
    end
  end

  self.activeAuthoringScene = nil
  self.activeAuthoringIdx   = nil
  self._sceneTargetParams   = nil
  self:clearSubTitle()
end

function Root:enterScopeView()
  local xpath = self:getXPathToSelection()
  self.scopeView:refresh()
  self.scopeView:select(xpath)
end

function Root:leaveScopeView()
  if self.scopeView:selectionChanged() then
    local xpath = self.scopeView:getXPath()
    if xpath then
      self:navigateToXPath(xpath)
    end
  end
end

function Root:releaseResources()
  self.pinView:releaseResources()
  if self.sceneView then
    self.sceneView:releaseResources()
  end
  self.scopeView:releaseResources()
  Chain.releaseResources(self)
end

return Root

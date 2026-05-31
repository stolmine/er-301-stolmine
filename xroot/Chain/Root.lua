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

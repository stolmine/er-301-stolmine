local Class = require "Base.Class"
local Chain = require "Chain"
local ScopeView = require "Chain.ScopeView"
local PinView = require "PinView"
local SceneView = require "SceneView"
local SequencerView = require "Sequencer.GridView"

local Root = Class {}
Root:include(Chain)

function Root:init(args)
  Chain.init(self, args)
  self:setClassName("Chain.Root")
  self.isRoot = true
  self.scopeView = ScopeView(self)
  self.pinView = PinView(self)
  -- SceneView always created (cheap; just a state container with
  -- no UI until shown). Whether the front-panel hold switch
  -- routes to the legacy PinView vs the new SceneView Performance
  -- view is gated by the Settings.sceneMode admin preference,
  -- checked dynamically in Channels.Group.setMode("hold"). Always
  -- creating both lets the user flip the preference live without
  -- re-instantiating chains.
  self.sceneView = SceneView(self)
  self.sequencerView = SequencerView(self)
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
  t.pinView   = self.pinView:serialize()
  t.sceneView = self.sceneView:serialize()
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
    self.sceneView:deserialize(t.sceneView)
  else
    self.sceneView:removeAllScenes()
  end
  -- Legacy-pinset detection: when scene mode is on AND we load a
  -- preset that still carries non-empty pinView data, surface a
  -- one-time dismiss overlay so the user knows their old pinsets
  -- won't migrate. Pinset data is left in the preset file for
  -- safety (toggling scene mode off still surfaces old pinsets);
  -- we just don't show them in the new scene surface.
  if t.pinView and t.pinView.pinSets and #t.pinView.pinSets > 0 then
    local Settings = require "Settings"
    if Settings.get("sceneMode") == "on" then
      local Overlay = require "Overlay"
      Overlay.flashMainMessage(
        "Legacy hold-mode pinsets can't migrate. Recreate as scenes.")
    end
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
  self.sceneView:releaseResources()
  self.scopeView:releaseResources()
  Chain.releaseResources(self)
end

return Root

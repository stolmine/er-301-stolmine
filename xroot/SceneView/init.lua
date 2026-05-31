-- Per-chain scene store. Replaces the legacy PinView when the
-- chain's usesScenes flag is on. Owns a list of Scenes plus the
-- crossfader configuration (which two scenes are assigned to the
-- A/B endpoints, and which CV input drives the blend).
--
-- Phase 1 scope: state model + serialize/deserialize only. No UI,
-- no engine apply. Performance + Authoring views land in phases
-- 2-3; ParamSetMorph wiring lands in phase 4.

local Class = require "Base.Class"
local Scene = require "SceneView.Scene"

local SceneView = Class {}

-- Max number of scenes per chain. Per docs/planning/hold-mode-
-- scenes-impl.md, 16 is plenty for the expected performance
-- workflow. The 5-per-page Performance view paginates beyond M2-M6.
local kMaxScenes = 16

-- Crossfader endpoint sentinel: 0 means "fall back to base values"
-- (the per-param values set in user-mode before entering scene
-- mode). Any positive value is a 1-based index into self.scenes.
local kEndpointBase = 0

function SceneView:init(chain)
  self:setClassName("SceneView")
  self.chain        = chain
  self.scenes       = {}
  self.cvInput      = nil               -- serialized source ref string
  self.crossfaderA  = kEndpointBase     -- 0 = base, else scene index
  self.crossfaderB  = kEndpointBase
end

function SceneView:getSceneCount()
  return #self.scenes
end

function SceneView:getScene(idx)
  return self.scenes[idx]
end

function SceneView:getMaxScenes()
  return kMaxScenes
end

-- Append a new scene. Returns (scene, idx) or (nil, "reason") on
-- failure. Name defaults to "S<n>" with n = next available index.
function SceneView:addScene(name)
  if #self.scenes >= kMaxScenes then
    return nil, "max scenes reached"
  end
  local idx = #self.scenes + 1
  local scene = Scene { name = name or string.format("S%d", idx) }
  self.scenes[idx] = scene
  return scene, idx
end

-- Remove scene at idx. Shifts subsequent indices down and clears
-- any crossfader assignment that pointed at the removed scene
-- (subsequent assignments shift with the indices).
function SceneView:removeScene(idx)
  if self.scenes[idx] == nil then return false end
  table.remove(self.scenes, idx)
  if self.crossfaderA == idx then
    self.crossfaderA = kEndpointBase
  elseif self.crossfaderA > idx then
    self.crossfaderA = self.crossfaderA - 1
  end
  if self.crossfaderB == idx then
    self.crossfaderB = kEndpointBase
  elseif self.crossfaderB > idx then
    self.crossfaderB = self.crossfaderB - 1
  end
  return true
end

function SceneView:setCrossfaderA(idx)
  if idx == kEndpointBase or self.scenes[idx] then
    self.crossfaderA = idx
  end
end

function SceneView:setCrossfaderB(idx)
  if idx == kEndpointBase or self.scenes[idx] then
    self.crossfaderB = idx
  end
end

function SceneView:getCrossfaderA() return self.crossfaderA end
function SceneView:getCrossfaderB() return self.crossfaderB end

function SceneView:setCvInput(sourceRef)
  self.cvInput = sourceRef
end

function SceneView:getCvInput()
  return self.cvInput
end

-- Lazy-instantiate the Performance view Window the user lands in
-- when scene mode is on and the panel hold switch fires. Created
-- on first access so chains without scenes pay no UI cost.
function SceneView:getPerformanceView()
  if self.performanceView == nil then
    local Performance = require "SceneView.Performance"
    self.performanceView = Performance(self)
  end
  return self.performanceView
end

-- Phase-1 lifecycle stubs. Wired up in later phases; defined now
-- so Chain.Root + Channels.Group can call them unconditionally.
function SceneView:enterPerformanceView() end
function SceneView:leavePerformanceView() end
function SceneView:releaseResources()   end

-- Serialize the full scene store. Schema matches the impl plan
-- (xroot/SceneView/init.lua is the source of truth; Chain.Root
-- just passes the table through to chain quicksave/preset state).
function SceneView:serialize()
  local scenes = {}
  for i, scene in ipairs(self.scenes) do
    scenes[i] = scene:serialize()
  end
  return {
    schemaVersion = 1,
    sceneCount    = #self.scenes,
    scenes        = scenes,
    cvInput       = self.cvInput,
    crossfaderA   = self.crossfaderA,
    crossfaderB   = self.crossfaderB,
  }
end

function SceneView:deserialize(t)
  if t == nil then return end
  -- Reset to a clean state so a partial restore doesn't leave
  -- stale scenes from a prior load.
  self.scenes      = {}
  self.cvInput     = t.cvInput     or nil
  self.crossfaderA = t.crossfaderA or kEndpointBase
  self.crossfaderB = t.crossfaderB or kEndpointBase
  if t.scenes then
    for i, sceneData in ipairs(t.scenes) do
      if i > kMaxScenes then break end
      local scene = Scene { name = sceneData.name }
      scene:deserialize(sceneData)
      self.scenes[i] = scene
    end
  end
  -- Clamp out-of-range crossfader assignments (e.g. if a saved
  -- index points past the actual loaded scene count).
  if self.crossfaderA > #self.scenes then
    self.crossfaderA = kEndpointBase
  end
  if self.crossfaderB > #self.scenes then
    self.crossfaderB = kEndpointBase
  end
end

function SceneView:removeAllScenes()
  self.scenes      = {}
  self.crossfaderA = kEndpointBase
  self.crossfaderB = kEndpointBase
end

-- Constants exposed for callers that need to compare against
-- "base" (the no-scene-assigned endpoint sentinel).
SceneView.ENDPOINT_BASE = kEndpointBase

return SceneView

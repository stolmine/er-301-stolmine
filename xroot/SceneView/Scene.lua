-- A single scene within a chain's SceneView. Stores a sparse map
-- of (unitInstanceKey, controlId) -> delta value, plus metadata.
--
-- Two representations coexist:
--
-- 1. self.deltas[unitKey][ctrlId] -> float. The on-disk format,
--    also the source of truth before any Parameters have been
--    instantiated for this scene. setDelta / getDelta / hasDelta
--    operate on this layer.
--
-- 2. self.params[unitKey][ctrlId] -> app.Parameter. Lazy. Created
--    by getOrCreateParam at engage time (or at scene-authoring
--    enter), seeded from the float in deltas if any, else from
--    the base value passed in. Persists until disengage; reused
--    across authoring transitions so the morpher (which holds
--    Parameter pointers) doesn't need rebuilds.
--
-- serialize() syncs params -> deltas first so the saved float
-- format reflects any live edits. deserialize() loads deltas
-- only; params get rebuilt on next engage.

local Class = require "Base.Class"
local Object = require "Base.Object"

local Scene = Class {}
Scene:include(Object)

function Scene:init(args)
  self:setClassName("SceneView.Scene")
  self.name   = args.name or "scene"
  -- deltas[unitInstanceKey][controlId] = numeric value (on-disk + bootstrap)
  self.deltas = args.deltas or {}
  -- params[unitInstanceKey][controlId] = app.Parameter (in-memory live state)
  self.params = {}
end

function Scene:getName()
  return self.name
end

function Scene:setName(name)
  if name and name ~= "" then self.name = name end
end

-- Write or clear the delta for a (unit, control) pair. Passing
-- value = nil removes the delta entirely.
function Scene:setDelta(unitKey, controlId, value)
  if unitKey == nil or controlId == nil then return end
  if value == nil then
    if self.deltas[unitKey] then
      self.deltas[unitKey][controlId] = nil
      if next(self.deltas[unitKey]) == nil then
        self.deltas[unitKey] = nil
      end
    end
    return
  end
  if self.deltas[unitKey] == nil then self.deltas[unitKey] = {} end
  self.deltas[unitKey][controlId] = value
end

function Scene:hasDelta(unitKey, controlId)
  return self.deltas[unitKey] ~= nil
     and self.deltas[unitKey][controlId] ~= nil
end

function Scene:getDelta(unitKey, controlId)
  if self.deltas[unitKey] == nil then return nil end
  return self.deltas[unitKey][controlId]
end

-- Total count of delta'd controls across all units. Used by the
-- Performance view's slot density indicator.
function Scene:countDeltas()
  -- Sync deltas from params first so the count reflects any
  -- live edits (e.g. user just turned an encoder in authoring).
  self:_syncDeltasFromParams()
  local n = 0
  for _, perUnit in pairs(self.deltas) do
    for _ in pairs(perUnit) do n = n + 1 end
  end
  return n
end

-- Live Parameter accessors.
--
-- getOrCreateParam returns the persistent Parameter for this
-- scene's (unit, ctrl) endpoint, creating it on first call. The
-- new Parameter is initialized to the existing delta value if one
-- exists, else to baseValue (the param's current user-mode
-- target). Subsequent calls return the same instance.
function Scene:getOrCreateParam(unitKey, controlId, baseValue)
  if unitKey == nil or controlId == nil then return nil end
  local u = self.params[unitKey]
  if u == nil then
    u = {}
    self.params[unitKey] = u
  end
  local p = u[controlId]
  if p == nil then
    local seed = self:getDelta(unitKey, controlId) or baseValue or 0
    local app = app
    p = app.Parameter(string.format("%s/%s/%s", self.name, tostring(unitKey), controlId), seed)
    u[controlId] = p
  end
  return p
end

function Scene:getParam(unitKey, controlId)
  local u = self.params[unitKey]
  if u == nil then return nil end
  return u[controlId]
end

-- Walk live params and copy each target() back into the float
-- deltas map. Called before serialize and before counting deltas
-- so external views always see the latest values.
function Scene:_syncDeltasFromParams()
  for unitKey, ctrls in pairs(self.params) do
    for ctrlId, param in pairs(ctrls) do
      if self.deltas[unitKey] == nil then self.deltas[unitKey] = {} end
      self.deltas[unitKey][ctrlId] = param:target()
    end
  end
end

-- Drop all live params. Called on disengage so re-engage rebuilds
-- with fresh base values. deltas survives unchanged.
function Scene:releaseParams()
  self:_syncDeltasFromParams()
  self.params = {}
end

function Scene:serialize()
  -- Make sure any encoder edits since last save land in deltas
  -- before we hand the table to disk.
  self:_syncDeltasFromParams()
  return {
    name   = self.name,
    deltas = self.deltas,
  }
end

function Scene:deserialize(t)
  if t == nil then return end
  if t.name   then self.name   = t.name   end
  if t.deltas then self.deltas = t.deltas end
  -- Params are not deserialized; getOrCreateParam will lazily
  -- rebuild them from deltas on next engage.
  self.params = {}
end

return Scene

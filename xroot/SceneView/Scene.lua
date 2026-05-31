-- A single scene within a chain's SceneView. Stores a sparse map
-- of (unitInstanceKey, controlId) -> delta value, plus metadata.
-- No engine apply happens at this layer; SceneView.Apply (phase 4)
-- consumes the delta map to drive the ParamSetMorph.

local Class = require "Base.Class"
local Object = require "Base.Object"

local Scene = Class {}
Scene:include(Object)

function Scene:init(args)
  self:setClassName("SceneView.Scene")
  self.name   = args.name or "scene"
  -- deltas[unitInstanceKey][controlId] = numeric value
  self.deltas = args.deltas or {}
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
  local n = 0
  for _, perUnit in pairs(self.deltas) do
    for _ in pairs(perUnit) do n = n + 1 end
  end
  return n
end

function Scene:serialize()
  return {
    name   = self.name,
    deltas = self.deltas,
  }
end

function Scene:deserialize(t)
  if t == nil then return end
  if t.name   then self.name   = t.name   end
  if t.deltas then self.deltas = t.deltas end
end

return Scene

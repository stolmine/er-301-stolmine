-- [stol:promote-control-to-top-level] Ancestor picker for control promotion.
--
-- Deliberately NOT a pruned ScopeView. ScopeView descends into children
-- (Chain/ScopeView.lua loadChainHelper/loadUnitHelper); the valid promotion
-- targets are the origin's ANCESTORS, which is the opposite direction. Since the
-- ancestor set is a single path from the topmost unit down to the origin, we emit
-- exactly that path into the same app.ChainOverview widget, outermost first, so
-- the widget's nesting reads as containment and depth is legible at a glance.
--
-- Emitting only the path is also what enforces the rule: a unit that does not
-- contain the origin is never drawn, so it cannot be selected. The origin's own
-- unit is excluded by Promote.ancestorsOf.
--
-- Selection commits via `onChoose(unit)`; CANCEL just closes. Nothing in the
-- patch is mutated by this window -- see planning/control-promotion-plan.md §7
-- for why the create/cancel boundary sits after this step, not inside it.

local app = app
local Env = require "Env"
local Class = require "Base.Class"
local Window = require "Base.Window"
local Encoder = require "Encoder"

local PromoteTargetView = Class {}
PromoteTargetView:include(Window)

function PromoteTargetView:init(control, ancestors, onChoose)
  self.ptr = app.ChainOverview(0, 0, 256, 64)
  local sub = app.Graphic(0, 0, 128, 64)
  local Drawings = require "Drawings"
  local drawing = app.Drawing(0, 0, 128, 64)
  drawing:add(Drawings.Sub.HelpfulButtons)
  sub:addChild(drawing)
  sub:addChild(app.TextPanel("Promote here", 1, 0.5, app.GRID5_LINE3 - 1))
  Window.init(self, self.ptr, sub)
  self:setClassName("Unit.PromoteTargetView")

  self.control = control
  self.onChoose = onChoose
  self.unitById = {}
  self:setMainCursorController(self.ptr)
  self.encoderState = Encoder.Fine
  self.ptr:setDepthFirstNavigation(true)
  self.ptr:setEmptyString("No unit above this one.")

  -- ancestorsOf returns innermost-first; reverse so the outermost container is
  -- emitted first and the path nests inward toward the origin.
  self.ancestors = {}
  for i = #ancestors, 1, -1 do
    self.ancestors[#self.ancestors + 1] = ancestors[i]
  end
  self:build()
end

function PromoteTargetView:build()
  local overview = self.ptr
  self.unitById = {}
  overview:clear()
  local opened = 0
  for _, unit in ipairs(self.ancestors) do
    local id = overview:startUnit(unit.mnemonic, unit.title, 1)
    self.unitById[id] = unit
    opened = opened + 1
  end
  for _ = 1, opened do
    overview:endUnit()
  end
  overview:rebuild()
end

function PromoteTargetView:selectedUnit()
  return self.unitById[self.ptr:selected()]
end

local threshold = Env.EncoderThreshold.Default
function PromoteTargetView:encoder(change, shifted)
  self.ptr:encoder(change, shifted, threshold)
  return true
end

function PromoteTargetView:enterReleased()
  local unit = self:selectedUnit()
  if unit == nil then
    return true
  end
  self:hide()
  if self.onChoose then
    self.onChoose(unit)
  end
  return true
end

function PromoteTargetView:cancelReleased(shifted)
  if not shifted then
    self:hide()
  end
  return true
end

function PromoteTargetView:upReleased(shifted)
  self:hide()
  return true
end

function PromoteTargetView:homeReleased()
  self:hide()
  return true
end

function PromoteTargetView:onShow()
  Encoder.set(self.encoderState)
end

function PromoteTargetView:onHide()
  Encoder.set(Encoder.Neutral)
end

return PromoteTargetView

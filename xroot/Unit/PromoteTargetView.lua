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

-- A unit's children hang off a PATCH or a BRANCH node, never off the unit
-- directly. Nesting startUnit inside startUnit gives the widget nothing to hang
-- the inner one from, and it draws only the outermost -- which is what happened
-- (reported 2026-08-13: "in situations more than one layer deep we do not see
-- anything below the uppermost layer"). Chain/ScopeView.lua is the reference for
-- the shape: unit -> patch/branch -> unit.
--
-- Which container to open is decided by the INNER unit's own chain, since that
-- chain is precisely the patch or branch of the outer unit that holds it.
function PromoteTargetView:openContainerFor(innerUnit)
  local chain = innerUnit and innerUnit.chain
  if chain == nil then
    return nil
  end
  local name = chain.subTitle or chain.name or chain.title or "in"
  if getmetatable(chain) == require "Chain.Patch" then
    self.ptr:startPatch(name, 1)
    return "patch"
  end
  self.ptr:startBranch(name, 1)
  return "branch"
end

function PromoteTargetView:closeContainer(kind)
  if kind == "patch" then
    self.ptr:endPatch()
  elseif kind == "branch" then
    self.ptr:endBranch()
  end
end

function PromoteTargetView:build()
  local overview = self.ptr
  self.unitById = {}
  overview:clear()

  -- Outermost first, each one opening the container that holds the next, so the
  -- drawn nesting reads as containment all the way down to the origin's unit.
  local opened = {}
  local firstId
  for i, unit in ipairs(self.ancestors) do
    local id = overview:startUnit(unit.mnemonic, unit.title, 1)
    self.unitById[id] = unit
    firstId = firstId or id
    opened[#opened + 1] = "unit"
    local inner = self.ancestors[i + 1]
    if inner then
      opened[#opened + 1] = self:openContainerFor(inner)
    end
  end
  for i = #opened, 1, -1 do
    if opened[i] == "unit" then
      overview:endUnit()
    else
      self:closeContainer(opened[i])
    end
  end
  overview:rebuild()
  -- Land on the topmost unit rather than on the chain node above it. That node
  -- is not a promotion target -- only units are -- so leaving the cursor there
  -- means every promotion starts with a downward turn to get out of a row that
  -- was never selectable.
  if firstId then
    overview:select(firstId)
  end
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

-- The sub display draws "Promote here" over button 1, so button 1 has to do it.
function PromoteTargetView:subReleased(i, shifted)
  if shifted then
    return false
  end
  if i == 1 then
    return self:enterReleased()
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

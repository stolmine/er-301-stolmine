-- [stol:promote-control-to-top-level] Control promotion.
--
-- Turn a control buried inside a container into a macro on one of its ANCESTOR
-- units, driving the original one-to-one, without changing the sound.
--
-- Full design + the three review passes behind it: planning/control-promotion-plan.md.
-- Read its CURRENT STATE header before changing anything here; several of the
-- decisions below look arbitrary until you know what they are avoiding.
--
-- This module owns every precondition. Do not re-derive "can this be promoted?"
-- at a call site -- that is exactly the copy-pasted-precondition shape that has
-- bitten this codebase before.

local app = app

local Promote = {}

-- Exact-metatable test, deliberately NOT `control.type == "GainBias"` and NOT a
-- class check. Base.Class deep-copies members into subclasses (Base/Class.lua:36-49)
-- and there is no isInstanceOf, so `type` is inherited by all ~49 habitat
-- subclasses of GainBias -- and those are exactly the ones whose semantics break
-- (mi/ModeSelector uses bias as a quantized mode index and swaps its fader label
-- to the mode name). Instances take the class table as their metatable
-- (Class.lua:80-86), so this matches plain GainBias{} only: ~509 habitat controls.
--
-- Self-consistency the chaining case depends on: the macro controls this module
-- creates are themselves plain GainBias{} (Unit/ControlBranch/GainBias.lua),
-- so a promoted macro stays promotable.
function Promote.isPromotableControl(control)
  if control == nil then return false end
  return getmetatable(control) == require "Unit.ViewControl.GainBias"
end

-- Ancestors of the unit a control sits on, innermost first, terminating at the
-- topmost unit in the chain. The origin's OWN unit is never included.
--
-- Uniform for both nesting kinds because each carries a back-pointer to the unit
-- that owns it: Chain.Branch sets `unit` via Unit:addBranch (Unit/init.lua:272,
-- Chain/Branch.lua:32) and Chain.Patch sets it at construction (Chain/Patch.lua:20).
-- The root chain has no `unit`, which is what terminates the walk.
function Promote.ancestorsOf(control)
  local out = {}
  local unit = control and control.parent
  if unit == nil then return out end
  local chain = unit.chain
  local guard = 0
  while chain and chain.unit and guard < 64 do
    local ancestor = chain.unit
    out[#out + 1] = ancestor
    chain = ancestor.chain
    guard = guard + 1
  end
  return out
end

-- Single choke point for "may this control be promoted right now?".
-- Returns true, or false plus a reason string suitable for a flash message.
--
-- `quiet` suppresses the scene-authoring flash, because the menu-build path asks
-- this on every open and must not spam the overlay; the commit path wants the
-- message and passes quiet = false.
function Promote.check(control, quiet)
  if not Promote.isPromotableControl(control) then
    return false, "Only standard fader controls can be promoted."
  end

  local ancestors = Promote.ancestorsOf(control)
  if #ancestors == 0 then
    return false, "Nothing above this unit to promote to."
  end

  local root = control.parent and control.parent.getRootChain and
                   control.parent:getRootChain()
  if root then
    -- Authoring: structural edits are refused outright, same contract as
    -- Unit:showMenu (Unit/init.lua) and the GainBias gain gate.
    if quiet then
      if root.isLockedForSceneAuthoring and root:isLockedForSceneAuthoring() then
        return false, "Locked while editing scene."
      end
    elseif root.rejectSceneAuthoringEdit and root:rejectSceneAuthoringEdit() then
      return false, nil -- rejectSceneAuthoringEdit already flashed
    end

    -- Engaged: harder, and the reason v1 refuses rather than handles it. While a
    -- scene is engaged the morpher holds a Vee item per delta-able control bound
    -- to a base snapshotted at engage time and softSets the audio parameter every
    -- frame (Chain/Root.lua:818-828, 872-894). Promotion sets the origin's bias
    -- to 0; the morpher writes the old base straight back on the next frame and
    -- the patch reads ~2B. Clearing deltas does not help -- the base snapshot is
    -- the driver. Engagement also SURVIVES leaving the Performance view
    -- (Channels/Group.lua:148-152), so this menu is genuinely reachable in that
    -- state; the gate is load-bearing, not defensive.
    if root._sceneEngaged then
      return false, "Disengage scenes before promoting."
    end
  end

  return true, nil
end

-- Create the macro INERT: right type, right name, placed in the target's
-- expanded view, but nothing wired and an empty branch. It drives nothing and is
-- driven by nothing, so it has no audio effect and CANCEL can drop it with no
-- trace. This is what makes the cancel boundary real (plan §7) -- the expensive,
-- hard-to-undo work all happens later, at commit.
function Promote.createInertMacro(control, targetUnit)
  local name = control:getCustomizableValue("name") or control.id or "macro"
  local ok = targetUnit.validateControlName and targetUnit:validateControlName(name)
  if not ok then
    -- addControlBranch REMOVES AND REPLACES a branch whose id already exists,
    -- so a collision here would silently destroy an existing control.
    name = targetUnit:generateUniqueControlName(name)
  end

  local macro = targetUnit:addControlBranch("GainBias", name)
  -- addControlBranch does not put the control in any view; deserialize pairs the
  -- two (Unit/init.lua), and without this the macro exists but is invisible.
  targetUnit:placeControl(name, "expanded")
  targetUnit:switchView("expanded")

  -- Phase 1: copy the origin's display so the macro reads in the same units,
  -- curve, precision and scaling. Everything except the name, which we just
  -- resolved against collisions above.
  -- Read each key under pcall. Not all dial maps implement the whole
  -- getCustomizableValue surface -- Test Osc's freq control uses the "freqGain"
  -- map, whose getter chain has no superCoarseStep, so a blanket copy throws.
  -- A display attribute we cannot read is one the macro simply does not inherit;
  -- that is a cosmetic shortfall, not a reason to abort a promotion.
  local snapshot = {}
  for _, key in ipairs(control:getCustomizableKeys()) do
    if key ~= "name" then
      local ok, value = pcall(control.getCustomizableValue, control, key)
      if ok and value ~= nil then
        snapshot[key] = value
      end
    end
  end
  -- customize() likewise walks the map keys it was handed; guard the apply too so
  -- one unreadable attribute cannot leave a half-built macro behind.
  pcall(macro.control.customize, macro.control, snapshot)

  return macro, name
end

-- Drop an inert macro created by createInertMacro. removeControlBranch now stops
-- the branch and removes it from unit.branches by name (both were broken; see
-- Unit/Section.lua), so this genuinely leaves no residue and can be run in a
-- create/cancel loop.
function Promote.rollback(targetUnit, name)
  if targetUnit and name then
    targetUnit:removeControlBranch(name)
  end
end

-- Step 3 of the plan's build order: pick an ancestor, then create the macro inert
-- and hand off to placement. Steps 4 (transplant) and 5 (scene clear) are not
-- wired yet; commit currently rolls back so no half-promoted state can escape.
function Promote.begin(control)
  local ok, reason = Promote.check(control, false)
  if not ok then
    if reason then
      require("Overlay").flashMainMessage(reason)
    end
    return
  end

  local ancestors = Promote.ancestorsOf(control)
  local PromoteTargetView = require "Unit.PromoteTargetView"
  local view = PromoteTargetView(control, ancestors, function(targetUnit)
    local macro, name = Promote.createInertMacro(control, targetUnit)
    -- NOT YET IMPLEMENTED: placement (plan §7 step 4) and commit (§5 transplant
    -- + §6 scene clear). Until those land, roll the inert macro straight back so
    -- the patch is never left in a half-promoted state.
    Promote.rollback(targetUnit, name)
    require("Overlay").flashMainMessage("Promote: transplant not implemented yet.")
  end)
  view:show()
end

return Promote

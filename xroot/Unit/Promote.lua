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
    -- The cursor was sitting ON the macro during placement, so removing it
    -- leaves the selection pointing at a spot handle that the next rebuild
    -- regenerates out of existence; enableSelection then falls back to
    -- selectLast and the cursor jumps to the end of the chain. Park it on the
    -- target unit's header instead, which is where the user's attention is.
    local header = targetUnit.controls and targetUnit.controls.header
    if header and targetUnit.rebuildViewFollowingControl then
      targetUnit:rebuildViewFollowingControl("expanded", header)
    end
  end
end

local function biasParamOf(control)
  return control.bias and control.bias:getParameter()
end

local function gainParamOf(control)
  return control.gain and control.gain:getParameter()
end

-- Drop the promoted control out of every scene, completely. Plan §6.
--
-- Three steps, not one. Scene:setDelta touches only `deltas`; the live
-- Parameter lives in `params` and Scene:_syncDeltasFromParams copies params
-- BACK into deltas before every serialize and every countDeltas
-- (SceneView/Scene.lua), so clearing the delta alone means the delta is
-- resurrected at the next quicksave. Root:exitSceneAuthoring does all three and
-- is the precedent this follows.
--
-- Read `root.sceneView` directly rather than getSceneView(): the latter creates
-- the container lazily, so asking through it would manufacture scene state for a
-- patch that has never had any.
--
-- Why this is necessary at all: a delta is an absolute target for the control's
-- BIAS parameter. Promotion sets that bias to 0, so a surviving delta would drag
-- the origin back to its old value the moment the scene is recalled, and the
-- patch would read roughly 2B. Scoped, honest loss: that one control stops
-- moving in every scene, every other control's scene data is untouched.
local function clearSceneState(origin)
  local unit = origin.parent
  if unit == nil or unit.getInstanceKey == nil then
    return
  end
  local root = unit.getRootChain and unit:getRootChain()
  if root == nil or root.sceneView == nil then
    return
  end
  local unitKey = unit:getInstanceKey()
  local ctrlId = origin.id
  if unitKey == nil or ctrlId == nil then
    return
  end
  for i = 1, root.sceneView:getSceneCount() do
    local scene = root.sceneView:getScene(i)
    if scene then
      scene:setDelta(unitKey, ctrlId, nil)
      local params = scene.params and scene.params[unitKey]
      if params then
        params[ctrlId] = nil
        if next(params) == nil then
          scene.params[unitKey] = nil
        end
      end
    end
  end
  -- A guaranteed no-op here, because rebuildSceneMorph early-returns unless a
  -- scene is engaged and Promote.check refuses promotion while engaged. Kept so
  -- the sequence stays correct if that refusal is ever relaxed. Do NOT read this
  -- as "the rebuild handles the engaged case" -- it does not; the morpher's base
  -- snapshot is what drives an engaged scene, not the delta.
  if root.rebuildSceneMorph then
    root:rebuildSceneMorph()
  end
end

-- The transplant. Plan §5, and the riskiest part of this feature.
--
-- End state, for origin bias B, gain G and modulation branch F:
--   macro  = bias B, gain G, branch F (moved wholesale)
--   origin = bias 0, gain 1, input source = the macro's output
-- so origin = 0 + 1*macroOut = B + G*F(S), which is what it read before.
--
-- Returns true, or false plus a reason.
function Promote.commit(origin, macroBranch)
  local Chain = require "Chain"
  local originBranch = origin.branch
  if originBranch == nil then
    return false, "That control has no modulation branch."
  end
  -- Chain:deserialize silently DROPS the right input on a channel-count
  -- mismatch, so refuse rather than half-transplant. Every ControlBranch type
  -- hardcodes channelCount = 1; this guards a stereo origin branch.
  if originBranch.channelCount ~= macroBranch.channelCount then
    return false, "Cannot promote a multi-channel modulation branch."
  end

  local macroControl = macroBranch.control
  local originBias, originGain = biasParamOf(origin), gainParamOf(origin)
  local macroBias, macroGain = biasParamOf(macroControl),
                               gainParamOf(macroControl)
  if not (originBias and originGain and macroBias and macroGain) then
    return false, "Missing bias/gain parameters."
  end

  local B = originBias:target()
  local G = originGain:target()

  -- Pinned to the Chain layer on BOTH sides, deliberately. A polymorphic
  -- origin.branch:serialize() would dispatch to ControlBranch:serialize in the
  -- chaining case (§8: promoting a control that is itself a macro), which adds
  -- t.control, t.objects, t.id and t.type -- feeding those to deserialize would
  -- rename the macro to the origin's name behind validateControlName's back and
  -- overwrite the adapter params outside the B/G assignment below.
  local payload = Chain.serialize(originBranch)
  -- The origin branch survives still holding its own chain-level key, and
  -- Chain:deserialize adopts whatever key the payload carries. Only this
  -- top-level key needs stripping; the keys INSIDE are left alone on purpose.
  payload.instanceKey = nil
  payload.selection = nil

  -- Clear FIRST, deserialize second. Instance keys are deliberately NOT
  -- regenerated -- promotion is a move, and Chain/Clipboard suppresses
  -- regeneration for exactly that reason; scene deltas belonging to units INSIDE
  -- the branch are keyed by those instance keys and regenerating orphans them
  -- permanently. Clearing first is what keeps old and new keys from coexisting,
  -- so findByInstanceKey can never bind to the wrong one.
  originBranch:clear()
  Chain.deserialize(macroBranch, payload)

  -- Macro takes the value BEFORE it is wired, so no frame sees the origin driven
  -- by an unconfigured adapter.
  macroBias:hardSet(B)
  macroGain:hardSet(G)

  -- Wiring order buys the cheaper transient. Parameter writes are not batched by
  -- the audio-thread transaction (it covers task-list changes only), so the
  -- audio thread can observe one frame mid-sequence:
  --   gain 0 first  -> out = B         (unchanged)
  --   wire          -> out = B         (unchanged, gain is 0)
  --   bias 0        -> out = 0         (ONE-FRAME DIP -- a click)
  --   gain 1        -> out = macroOut  (correct)
  -- Wiring before zeroing the gain would instead give one frame of B + G*macroOut
  -- (roughly 2B) -- a pop, and much worse on a level or a cutoff.
  originGain:hardSet(0)
  originBranch:setInputSource(1, macroBranch:getOutputSource(1))
  originBias:hardSet(0)
  originGain:hardSet(1)

  clearSceneState(origin)
  return true
end

-- Pick an ancestor, create the macro inert, place it, then commit.
--
-- The whole gesture is a chain of callbacks rather than a single function
-- because each stage is a UI window the user can walk away from. Every exit
-- before the commit leaves the patch exactly as it was: the picker mutates
-- nothing, and placement operates on a macro that is inert until commit wires it.
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
    local Placement = require "Unit.PromotePlacement"
    local started = Placement.begin{
      unit = targetUnit,
      control = macro.control,
      onCommit = function()
        local done, why = Promote.commit(control, macro)
        if not done then
          -- The macro is still inert at this point -- commit refuses before it
          -- touches anything -- so dropping it leaves the patch untouched.
          Promote.rollback(targetUnit, name)
          require("Overlay").flashMainMessage(why or "Promote failed.")
        end
      end,
      onCancel = function()
        Promote.rollback(targetUnit, name)
      end
    }
    if not started then
      -- reveal() failed, so there is no window to place on and no way for the
      -- user to reach the macro's CANCEL. Drop it rather than strand it.
      Promote.rollback(targetUnit, name)
      require("Overlay").flashMainMessage("Promote: cannot reach that unit.")
    end
  end)
  view:show()
end

return Promote

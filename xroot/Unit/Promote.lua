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

-- Which control classes can be promoted, and how their macro is built.
--
-- Promotability is a claim about ARITHMETIC, not about the widget: the control's
-- value has to compose affinely with its branch input, so that "macro carries the
-- value, origin goes neutral" is transparent. There are exactly three control
-- branch objects in the system and only two of them qualify:
--
--   ParameterAdapter  out = bias + gain*in   GainBias  -> promotable
--   ConstantOffset    out = offset + in      Pitch     -> promotable
--   Comparator        threshold, mode-dependent, nonlinear   Gate -> NOT
--
-- Gate is excluded on the arithmetic rather than out of caution. A toggle-mode
-- origin re-fed from a toggle-mode macro toggles on the macro's EDGES, which
-- halves the rate; making it work would mean forcing the origin into gate mode
-- at a fixed threshold, silently rewriting state the user set.
--
-- `value` is read through `fader:getValueParameter()` for both, which is the one
-- accessor the two classes share -- GainBias binds it to Bias (GainBias.lua) and
-- Pitch to Offset (Pitch.lua). `hasGain` is what actually differs.
local specs

-- Each entry says how to build a macro for that control class and how to move
-- the control's state onto it. Four hooks, in the order commit() runs them:
--
--   capture(origin)      read everything that makes the control sound as it does
--   apply(macro, state)  put it on the macro, BEFORE the macro is wired in
--   neutralize(origin)   make the origin a pass-through, BEFORE wiring
--   activate(origin)     the part that must happen AFTER wiring, if any
--
-- Splitting neutralize from activate is what keeps the transient safe. Every
-- prefix of the sequence has to read either the old value or silence; a step
-- ordered wrongly gives a frame of roughly double, which is a pop rather than a
-- click. GainBias needs its gain zeroed before wiring and restored to 1 after,
-- so it is the only one with a non-empty activate.
local function buildSpecs()
  local GainBias = require "Unit.ViewControl.GainBias"
  local Pitch = require "Unit.ViewControl.Pitch"
  local Gate = require "Unit.ViewControl.Gate"

  -- GainBias binds the fader's value parameter to Bias, Pitch to Offset. Reading
  -- through the fader rather than a readout is what lets the two share code.
  local function value(control)
    return control.fader and control.fader:getValueParameter()
  end
  local function gain(control)
    return control.gain and control.gain:getParameter()
  end

  return {
    -- out = bias + gain*in
    [GainBias] = {
      branchType = "GainBias",
      capture = function(c)
        return {value = value(c):target(), gain = gain(c):target()}
      end,
      apply = function(c, s)
        value(c):hardSet(s.value)
        gain(c):hardSet(s.gain)
      end,
      neutralize = function(c)
        gain(c):hardSet(0)
        value(c):hardSet(0)
      end,
      activate = function(c)
        gain(c):hardSet(1)
      end,
      ready = function(c)
        return value(c) ~= nil and gain(c) ~= nil
      end
    },

    -- out = offset + in. GainBias without the gain term.
    [Pitch] = {
      branchType = "Pitch",
      capture = function(c)
        return {value = value(c):target()}
      end,
      apply = function(c, s)
        value(c):hardSet(s.value)
      end,
      neutralize = function(c)
        value(c):hardSet(0)
      end,
      activate = function() end,
      ready = function(c)
        return value(c) ~= nil
      end
    },

    -- out = compare(in, threshold) under a mode. NOT affine, and promotable
    -- anyway -- the earlier reading of this file said otherwise and was wrong.
    --
    -- The objection was that a toggle-mode origin re-fed from a toggle-mode
    -- macro toggles on the macro's EDGES and halves the rate. True, but it
    -- assumes the origin KEEPS its mode. It does not: going neutral is exactly
    -- what bias 0 / gain 1 is for GainBias. The macro takes the mode, the
    -- threshold, the hysteresis, the inversion and the live toggle state, so it
    -- emits precisely the 0/1 signal the origin used to emit; the origin drops
    -- to plain GATE at threshold 0.5 and passes that through unchanged.
    --
    -- 0.5 is the neutral threshold because Comparator::process emits exactly
    -- 0.0f or 1.0f (od/objects/timing/Comparator.cpp), so half way between them
    -- is the one threshold no signal can sit near. Default hysteresis is 0.03,
    -- giving edges at 0.47 and 0.53 -- both crossed cleanly by a 0-to-1 step.
    --
    -- Trigger modes survive too: a one-sample pulse from the macro crosses 0.5
    -- and is passed through as a one-sample pulse.
    [Gate] = {
      branchType = "Gate",
      capture = function(c)
        local o = c.comparator
        return {
          mode = o:getMode(),
          inverted = o:isOutputInverted(),
          threshold = o:getParameter("Threshold"):target(),
          hysteresis = o:getParameter("Hysteresis"):target(),
          -- The live toggle level. Without it a toggle that is currently HIGH
          -- comes back LOW and stays inverted until the next edge.
          state = o:getOptionValue("State")
        }
      end,
      apply = function(c, s)
        local o = c.comparator
        o:setMode(s.mode)
        o:setOutputInversion(s.inverted)
        o:getParameter("Threshold"):hardSet(s.threshold)
        o:getParameter("Hysteresis"):hardSet(s.hysteresis)
        if s.state then
          o:setOptionValue("State", s.state)
        end
      end,
      neutralize = function(c)
        local o = c.comparator
        o:setMode(app.COMPARATOR_GATE)
        o:setOutputInversion(false)
        o:getParameter("Threshold"):hardSet(0.5)
        -- A Comparator's Mode option is NOT serialized by default: a builtin
        -- gate gets its mode from whatever its unit's constructor passes, every
        -- load. That is fine until promotion moves the mode onto a macro and
        -- leaves this one neutral -- reload and the unit would rebuild it in its
        -- original mode, re-triggering on the macro's edges instead of passing
        -- them through, and the patch would come back sounding different. The
        -- neutral state is now part of the patch, so it has to persist like one.
        local mode = o:getOption("Mode")
        if mode and mode.enableSerialization then
          mode:enableSerialization()
        end
      end,
      activate = function() end,
      ready = function(c)
        return c.comparator ~= nil
      end
    }
  }
end

local function specFor(control)
  if control == nil then
    return nil
  end
  if specs == nil then
    specs = buildSpecs()
  end
  -- Keyed by the class table, so this is an EXACT-metatable test, deliberately
  -- NOT `control.type == "GainBias"` and NOT a class check. Base.Class
  -- deep-copies members into subclasses (Base/Class.lua:36-49) and there is no
  -- isInstanceOf, so `type` is inherited by all 49 habitat subclasses of
  -- GainBias. Instances take the class table as their metatable
  -- (Class.lua:80-86), so this matches plain instantiations only.
  --
  -- That is narrower than it sounds. A survey of the four unit repos found the
  -- subclasses are ALL in habitat: Accents, er-301-custom-units and
  -- er-301-units contain zero subclasses of GainBias, Pitch or Gate between
  -- them and instantiate the stock classes directly, so 227 third-party
  -- GainBias controls and 20 third-party Pitch controls are already covered
  -- here. Admitting the habitat subclasses needs a class-level declaration and
  -- is filed separately as promote-control-type-spec.
  --
  -- CONSIDERED AND EXCLUDED, so nobody re-derives them:
  --
  -- BranchMeter (18 instances across the repos). It has a branch, so it passes
  -- the structural gate, and it is excluded deliberately rather than by
  -- omission. Every instance in every repo is a mixer-style AUDIO INPUT level --
  -- MixerUnit's "input", XFade's a/b, ABSwitch, Logics, Maths, FadeMixer -- and
  -- always in the same shape, `faderParam = objects.X:getParameter("Gain")` with
  -- the branch being the unit's audio input. Two reasons, either sufficient:
  --   * its branch carries the SIGNAL, not modulation. Transplanting the branch
  --     contents, which is what promotion does, would relocate the audio source
  --     itself into an ancestor. That is a different operation and one that
  --     already exists as move-to-mixer.
  --   * it hands over a bare `faderParam`, not a typed object. GainBias, Pitch
  --     and Gate each pass the OBJECT they drive, and its type is what tells us
  --     the composition law. A lone Parameter does not, so there is nothing to
  --     check an affine assumption against.
  --
  -- OptionControl, Fader, InputGate, OutputScope and the bespoke package
  -- controls are out for a simpler reason: no branch at all, so a macro would
  -- have nothing to drive them through. Promote.check tests that separately.
  return specs[getmetatable(control)]
end

-- OPT-OUT: a subclass of a promotable class is promotable unless it says
-- otherwise. Declaring `canPromote = false` on the class refuses it, in the
-- style of the existing canMove / canEdit declarations.
--
-- Opt-out rather than opt-in because the alternative couples firmware to package
-- versions: the entry would appear on core faders and not on package ones, with
-- nothing on screen to explain why. The measured risk of the other direction is
-- small -- a survey of all 11 habitat packages found no unit that reads its own
-- control's VALUE to decide anything, which is the one failure the structural
-- rule cannot see -- and no package outside habitat subclasses these classes at
-- all.
function Promote.isPromotableControl(control)
  if control ~= nil and getmetatable(control) and
      getmetatable(control).canPromote == false then
    return false
  end
  local how = Promote.classify(control)
  return how == "exact" or how == "clone" or how == "flatten"
end

-- The ControlBranch type a macro for this control must be built from, or nil if
-- the control cannot be promoted. Also the label the placement screen shows.
-- PROTOTYPE. Deliberately NOT wired into isPromotableControl or check() -- this
-- classifies, it does not admit. Ledger item promote-control-type-spec.
--
-- The question it answers: for a control that SUBCLASSES a promotable class, can
-- the macro be built as the same class, or must it fall back to a plain one?
--
-- Cloning is possible because GainBias:setDefaults stores the constructor's args
-- table verbatim on the instance, so a subclass's own arguments (modeNames,
-- discrete, the maps) are all still there. Override the four that bind a control
-- to its unit and the class constructs standalone -- verified against biome's
-- ModeSelector, whose clone comes up labelled "Fold" rather than a bare number.
--
-- When cloning is WRONG: a subclass whose extra constructor arguments are live
-- Parameter references into the origin unit's own objects. The habitat SHIFT
-- sub-layer controls are all like this (DriveControl takes args.toneAmount and
-- args.toneFreq). Clone one and the macro's shift layer would edit the ORIGIN's
-- tone control. Those want a plain macro for the promoted parameter instead.
--
-- The test is structural, so no package has to declare anything: an object-valued
-- entry in `defaults` outside the set below means the control is wired to
-- something else in its unit. `branch` is a Lua table carrying a metatable;
-- data like modeNames is a plain table, which is why the metatable test matters.
--
-- The failure direction is the safe one. An unfamiliar control with extra object
-- arguments falls back to "flatten" rather than aliasing something it should not.
local baseSpecFor

local CLONE_SAFE_KEYS = {
  branch = true,
  gainbias = true,
  range = true,
  biasMap = true,
  gainMap = true,
  offset = true,
  comparator = true
}

local function isObjectValued(v)
  local t = type(v)
  if t == "userdata" then
    return true
  end
  -- A Lua object carries a metatable; a data table like modeNames does not.
  return t == "table" and getmetatable(v) ~= nil
end

-- The spec of the promotable class a control DESCENDS from, or nil. Base.Class
-- deep-copies members, so the inherited `type` is exactly the right signal here,
-- where the whole point is to catch subclasses -- the opposite of what specFor
-- needs.
baseSpecFor = function(control)
  local class = control and getmetatable(control)
  if class == nil then
    return nil
  end
  if specs == nil then
    specs = buildSpecs()
  end
  for cls, spec in pairs(specs) do
    if cls.type == class.type then
      return spec
    end
  end
end

-- Returns "exact" | "clone" | "flatten" | nil, plus the sorted list of foreign
-- object-valued keys that forced a "flatten".
function Promote.classify(control)
  if control == nil then
    return nil
  end
  if specFor(control) then
    return "exact"
  end
  local class = getmetatable(control)
  if class == nil or specs == nil then
    return nil
  end
  -- Must descend from a promotable class. Base.Class deep-copies members, so the
  -- inherited `type` is exactly the right signal HERE, where the whole point is
  -- to catch subclasses -- the opposite of what specFor needs.
  local base = baseSpecFor(control)
  if base == nil or control.branch == nil or control.defaults == nil then
    return nil
  end
  local foreign = {}
  for k, v in pairs(control.defaults) do
    if not CLONE_SAFE_KEYS[k] and isObjectValued(v) then
      foreign[#foreign + 1] = k
    end
  end
  table.sort(foreign)
  if #foreign == 0 then
    return "clone", foreign
  end
  return "flatten", foreign
end

-- The spec that governs a control, whether it IS a promotable class or merely
-- descends from one. Every caller that acts on a control wants this; only the
-- clone/flatten decision cares about the difference.
local function effectiveSpec(control)
  return specFor(control) or baseSpecFor(control)
end

function Promote.branchTypeFor(control)
  local spec = effectiveSpec(control)
  return spec and spec.branchType
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
  if control.branch == nil then
    -- A control with no modulation branch has nothing for a macro to drive
    -- into. Both promotable classes hard-error without one at construction, so
    -- this is a belt-and-braces guard rather than a reachable case.
    return false, "That control has no modulation branch."
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

-- The name the macro will take on the target unit: the origin's, unless that
-- collides. Resolved separately from createInertMacro because the placement
-- screen shows the name before the macro exists.
--
-- addControlBranch REMOVES AND REPLACES a branch whose id already exists, so a
-- collision left unresolved would silently destroy an existing control.
function Promote.proposeName(control, targetUnit)
  local name = control:getCustomizableValue("name") or control.id or "macro"
  local ok = targetUnit.validateControlName and
                 targetUnit:validateControlName(name)
  if not ok then
    name = targetUnit:generateUniqueControlName(name)
  end
  return name
end

-- Create the macro INERT: right type, right name, placed in the target's
-- expanded view, but nothing wired and an empty branch. It drives nothing and is
-- driven by nothing, so it has no audio effect and CANCEL can drop it with no
-- trace. This is what makes the cancel boundary real (plan §7) -- the expensive,
-- hard-to-undo work all happens later, at commit.
-- `position` is the 1-based slot among the target's movable controls, as chosen
-- on the placement screen; nil appends.
function Promote.createInertMacro(control, targetUnit, position)
  local name = Promote.proposeName(control, targetUnit)

  -- Same branch type as the origin, so a promoted Pitch is a Pitch and the
  -- macro reads in cents rather than as a bare number.
  --
  -- And for a subclass that can be cloned, the same CONTROL class too, so a
  -- promoted mode selector is a mode selector rather than a numeric fader
  -- driving a quantized index. `classify` refuses to clone anything holding a
  -- reference into its own unit, which is what stops a cloned macro from
  -- editing the origin's parameters behind its back.
  local ControlClass = require "Unit.ControlClass"
  local branchData
  if Promote.classify(control) == "clone" then
    branchData = {
      controlClass = getmetatable(control),
      controlArgs = ControlClass.dataArgs(control.defaults)
    }
  end
  local macro = targetUnit:addControlBranch(Promote.branchTypeFor(control), name,
                                            branchData)
  -- addControlBranch does not put the control in any view; deserialize pairs the
  -- two (Unit/init.lua), and without this the macro exists but is invisible.
  targetUnit:placeControl(name, "expanded", position)
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
-- VALUE parameter (Bias for GainBias, Offset for Pitch). Promotion sets that to
-- 0, so a surviving delta would drag the origin back to its old value the moment
-- the scene is recalled, and the patch would read roughly twice it. Scoped,
-- honest loss: that one control stops moving in every scene, every other
-- control's scene data is untouched.
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
-- End state, for origin value V, gain G (GainBias only) and modulation branch F:
--   macro  = value V, gain G, branch F (moved wholesale)
--   origin = value 0, gain 1, input source = the macro's output
-- so origin = 0 + 1*macroOut = V + G*F(S), which is what it read before. For
-- Pitch there is no gain term and it reduces to origin = 0 + macroOut = V + F(S).
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
  -- effectiveSpec, not specFor: a subclass has no spec of its own and is governed
  -- by the one it descends from. Using the exact lookup here refused every
  -- subclass at commit while the menu happily offered it.
  local spec = effectiveSpec(origin)
  -- The macro was built from the origin's own branch type, so the two must agree
  -- on shape. Check both rather than trusting that: a mismatch means the macro is
  -- not what it should be, and wiring a half-configured object into the patch is
  -- the one outcome worth refusing outright.
  if spec == nil or effectiveSpec(macroControl) ~= spec then
    return false, "Macro does not match the control it came from."
  end
  if not (spec.ready(origin) and spec.ready(macroControl)) then
    return false, "Missing parameters."
  end

  local state = spec.capture(origin)

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

  -- Macro takes the state BEFORE it is wired, so no frame sees the origin driven
  -- by an unconfigured object.
  spec.apply(macroControl, state)
  -- A value-derived label (a mode name) is recomputed by its class only from its
  -- own init and its own encoder handler, never after a programmatic set. Without
  -- this the macro would sit showing modeNames[0] until the user turned it.
  require("Unit.ControlClass").resyncDisplay(macroControl)

  -- Ordering buys the cheaper transient. Parameter writes are not batched by the
  -- audio-thread transaction (it covers task-list changes only), so the audio
  -- thread can observe any PREFIX of this sequence:
  --   neutralize -> the origin reads 0 / sits low     one-frame DIP
  --   wire       -> still dipped, it is not active yet
  --   activate   -> reads macroOut                    correct
  -- Every prefix is either the old value or silence. The alternative orderings
  -- all admit a prefix reading value + gain*macroOut, roughly double: a pop
  -- rather than a click, and much worse on a level, a cutoff or a pitch. For a
  -- gate the dip is a frame held low, which drops an edge rather than inventing
  -- one -- again the safe direction.
  spec.neutralize(origin)
  originBranch:setInputSource(1, macroBranch:getOutputSource(1))
  spec.activate(origin)

  clearSceneState(origin)
  return true
end

-- Show the target unit and put the cursor on the macro, so the user lands on
-- what they just made rather than back where they started. The ancestor's chain
-- is normally already in the window stack, below the origin's, because that is
-- how the user descended to the origin in the first place; hideOthers pops back
-- to it. The show() fallback covers a chain that is somehow not in the stack,
-- which would otherwise make hideOthers pop the stack to nothing looking for a
-- window that is not there.
local function revealResult(targetUnit, control)
  local chain = targetUnit.chain
  if chain == nil then
    return
  end
  if chain.context then
    chain:hideOthers()
  else
    chain:show()
  end
  if targetUnit.rebuildViewFollowingControl then
    targetUnit:rebuildViewFollowingControl("expanded", control)
  end
end

-- Pick an ancestor, choose a slot on it, then create and commit.
--
-- The gesture is a chain of callbacks rather than one function because each
-- stage is a window the user can walk away from. Both stages before the commit
-- are read-only: the picker mutates nothing and the placement screen works on
-- proxy panels, so the macro does not exist until ENTER on the second screen.
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
    local PromotePlaceView = require "Unit.PromotePlaceView"
    local name = Promote.proposeName(control, targetUnit)
    local placer = PromotePlaceView(targetUnit, name,
                                    Promote.branchTypeFor(control),
                                    function(position)
      -- Re-check: two windows have been open since the menu was built and the
      -- scene state can have changed under them.
      local stillOk, why = Promote.check(control, false)
      if not stillOk then
        if why then
          require("Overlay").flashMainMessage(why)
        end
        return
      end
      local macro = Promote.createInertMacro(control, targetUnit, position)
      local done, reasonWhy = Promote.commit(control, macro)
      if done then
        revealResult(targetUnit, macro.control)
      else
        -- commit refuses before it touches anything, so the macro is still
        -- inert here and dropping it leaves the patch untouched.
        Promote.rollback(targetUnit, name)
        require("Overlay").flashMainMessage(reasonWhy or "Promote failed.")
      end
    end)
    placer:show()
  end)
  view:show()
end

return Promote

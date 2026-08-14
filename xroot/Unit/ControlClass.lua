-- [stol:promote-control-type-spec] Identify a control's class well enough to
-- rebuild it after a reload.
--
-- Promotion can build a macro as the SAME class as the control it came from, so
-- a promoted mode selector is a mode selector rather than a numeric fader. That
-- only holds up if the class survives a save/load, and a control branch records
-- only its BRANCH type ("GainBias", "Pitch", "Gate") -- enough to rebuild the
-- DSP object, not enough to rebuild the widget.
--
-- The identity used here is the module name, recovered by asking which loaded
-- module IS this class table. Package classes are `return`ed from their module,
-- so the lookup is exact and library-qualified: `biome.ModeSelector`,
-- `spreadsheet.BandControl`. Measured across all 11 habitat packages, every one
-- of the 87 subclass controls resolved to exactly one name, with none ambiguous
-- and none unresolved.
--
-- This is deliberately the same contract the unit loader already relies on
-- (`library.name .. "." .. moduleName` then a guarded `require`, see
-- Unit/Factory/init.lua). Nothing new is being asked of a package: if a unit
-- from that library can load, so can its control class.

local Utils = require "Utils"

local ControlClass = {}

-- The stock classes need no identity recorded: the branch type already implies
-- them, and writing their names into every patch would be noise.
local STOCK = {
  ["Unit.ViewControl.GainBias"] = true,
  ["Unit.ViewControl.Pitch"] = true,
  ["Unit.ViewControl.Gate"] = true
}

-- Weak keys: a class table that goes away with its package should not be pinned
-- here.
local nameCache = setmetatable({}, {
  __mode = "k"
})

function ControlClass.nameOf(class)
  if type(class) ~= "table" then
    return nil
  end
  local cached = nameCache[class]
  if cached ~= nil then
    return cached or nil
  end
  local found
  for name, module in pairs(package.loaded) do
    if module == class then
      found = name
      break
    end
  end
  -- `false` distinguishes "looked and found nothing" from "not looked yet", so
  -- an unresolvable class is not re-scanned on every serialize.
  nameCache[class] = found or false
  return found
end

function ControlClass.isStock(name)
  return name ~= nil and STOCK[name] == true
end

-- Resolve a recorded name back to a class, or nil.
--
-- nil is a normal outcome, not an error: the package may have been uninstalled
-- since the patch was saved, or renamed the module. The caller falls back to the
-- stock class, which still drives the origin correctly and merely reads as a
-- plain fader. Exactly the same degradation as a control that was never
-- clonable, so there is one failure mode to reason about rather than two.
function ControlClass.resolve(name)
  -- Promotion has the class in hand and passes it straight through; only the
  -- deserialize path arrives with a name to look up.
  if type(name) == "table" then
    return name
  end
  if type(name) ~= "string" or STOCK[name] then
    return nil
  end
  local ok, module = pcall(require, name)
  if ok and type(module) == "table" then
    return module
  end
  app.logInfo("ControlClass.resolve(%s): unavailable, falling back to stock",
              name)
  return nil
end

-- The constructor arguments that bind a control to ONE unit. A rebuilt macro
-- gets its own, so these are never carried across.
local BOUND = {
  branch = true,
  gainbias = true,
  range = true,
  offset = true,
  comparator = true,
  button = true,
  -- Rebuilt from the serialized customizations (min/max/steps), because a
  -- DialMap is userdata and cannot be written to a patch file.
  biasMap = true,
  gainMap = true
}

-- The class-specific arguments worth storing: everything that is plain data.
--
-- `modeNames` and friends arrive as constructor arguments, so a rebuilt clone
-- has no origin to copy them from and must carry its own. What makes that safe
-- is the same property that made the control clonable in the first place: a
-- clone-eligible control has no object-valued arguments outside BOUND, so
-- everything left is a number, a string, a boolean or a table of them.
function ControlClass.dataArgs(defaults)
  if type(defaults) ~= "table" then
    return nil
  end
  local out = {}
  local any = false
  for k, v in pairs(defaults) do
    if not BOUND[k] then
      local t = type(v)
      if t == "number" or t == "string" or t == "boolean" then
        out[k] = v
        any = true
      elseif t == "table" and getmetatable(v) == nil then
        -- Plain data table (a mode-name list). Copied, so a rebuilt control
        -- cannot mutate the one its origin is still using.
        out[k] = Utils.shallowCopy(v)
        any = true
      end
      -- Anything else (userdata, a table with a metatable, a function) is a live
      -- object and is dropped on purpose.
    end
  end
  return any and out or nil
end

-- Value-derived labels have to be told when their value changed behind their
-- back.
--
-- A mode selector's label is recomputed by its own updateLabel(), which its
-- class calls from init and from its encoder handler -- not after a programmatic
-- hardSet. So a promoted macro would sit showing modeNames[0] until the user
-- turned it, and would go stale again on every load. Three habitat units already
-- call updateLabel() by hand at the end of their own deserialize for exactly
-- this reason (Chime, Filterbank, Rauschen), so this follows the established
-- convention rather than inventing a probe.
function ControlClass.resyncDisplay(control)
  if control == nil or control.updateLabel == nil then
    return
  end
  pcall(control.updateLabel, control)
end

return ControlClass

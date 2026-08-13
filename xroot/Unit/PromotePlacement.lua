-- [stol:promote-control-to-top-level] Placement: hold the freshly created macro
-- under the cursor and walk it along the target unit's strip with the encoder.
--
-- Step 4 of planning/control-promotion-plan.md §7. Read its CURRENT STATE header
-- before changing anything here.
--
-- Deliberately NOT the Unit.Editor screen. The Editor is a separate SpottedStrip
-- built from ItemHeader proxies (Unit/Editor.lua), so it shows names and types,
-- not the controls themselves -- placing a macro there would mean placing it
-- blind. Only the Editor's move CALL is reused, via UnitSection:moveControl.
--
-- The macro is inert at this point (empty branch, nothing wired, see
-- Promote.createInertMacro), so every exit from here is cheap: CANCEL drops it
-- with no audio consequence and no trace in the serialized patch.
--
-- LIFETIME IS THE HARD PART, not the moving. Placement works by shadowing a few
-- handlers on ONE control instance, so a placement that outlives the gesture
-- leaves a booby-trapped control behind: turning the encoder to adjust its bias
-- walks it down the strip instead. That was a real bug (reported from the bench,
-- 2026-08-13, symptom "the whole control moves position"), and the two defences
-- against it are:
--
--   1. Placement ENDS when the control loses the cursor. It is a modal gesture
--      bound to the cursor being on the control, so navigating away cancels it
--      rather than leaving it armed and invisible.
--   2. Every shadowed handler self-heals. If it is ever reached when `active`
--      does not name its own control, it strips the shadows off that instance
--      and delegates to the class method. Belt and braces for any exit path not
--      thought of here -- a stale shadow can then misbehave at most zero times.

local app = app
local Env = require "Env"
local Encoder = require "Encoder"

local Placement = {}

local threshold = Env.EncoderThreshold.Default

-- At most one placement can be in flight: it owns the encoder and a set of
-- per-instance method overrides on one control, and two overlapping placements
-- would restore each other's overrides in the wrong order.
local active = nil

-- Every handler shadowed on the control instance. Kept in one list so install,
-- restore and the self-heal path cannot drift apart.
local SHADOWED = {
  "encoder",
  "enterReleased",
  "cancelReleased",
  "upReleased",
  "homeReleased",
  "onCursorLeave"
}

-- The class method a shadow is standing in front of. Instances take their class
-- as the metatable (Base/Class.lua:73,82), so this reaches the real handler
-- whether or not the instance field is still set.
local function classMethod(control, name)
  local class = getmetatable(control)
  return class and class[name]
end

local function unshadow(control)
  for _, name in ipairs(SHADOWED) do
    control[name] = nil
  end
end

-- Returns the live placement if it belongs to this control. Otherwise the
-- shadows are stale: strip them and return nil so the caller delegates.
local function claim(control)
  local p = active
  if p and p.control == control then
    return p
  end
  unshadow(control)
  return nil
end

local function delegate(control, name, ...)
  local f = classMethod(control, name)
  if f then
    return f(control, ...)
  end
end

-- Position of a control among the MOVABLE controls of a view -- 1-based, with
-- the insert and header controls excluded, which is the indexing
-- UnitSection:moveControl expects (Section.lua, +2 throughout).
local function positionOf(unit, control)
  local view = unit:getView("expanded")
  if view == nil then
    return nil
  end
  for i, c in ipairs(view.controls) do
    if c == control then
      return i - 2
    end
  end
end

local function movableCount(unit)
  local view = unit:getView("expanded")
  return view and (#view.controls - 2) or 0
end

-- Bring the target unit's chain to the top of the window stack and put the
-- cursor on the macro. The ancestor's chain is normally already in the stack,
-- below the origin's, because that is how the user descended to the origin in
-- the first place; hideOthers pops back to it. The show() fallback covers a
-- chain that is somehow not in the stack, which would otherwise make hideOthers
-- pop the stack to nothing looking for a window that is not there.
local function reveal(unit)
  local chain = unit.chain
  if chain == nil then
    return false
  end
  if chain.context then
    chain:hideOthers()
  else
    chain:show()
  end
  return true
end

-- Restore everything begin() took, in the reverse order it took it.
--
-- Only the grabs that were NOT already the control's are released.
-- enterReleased and homeReleased are routed to this control anyway while the
-- cursor sits on it (ViewControl:onCursorEnter), so releasing them here would
-- leave the control unable to handle its own ENTER afterwards -- dropping the
-- shadows is enough. cancelReleased was taken FROM the section
-- (UnitSection:onCursorEnter), so it is handed straight back.
local function finish()
  local p = active
  active = nil
  if p == nil then
    return
  end
  local control = p.control
  control:releaseFocus("encoder", "upReleased", "cancelReleased")
  unshadow(control)
  if control.controlGraphic then
    control.controlGraphic:setBorder(0)
  end
  if p.unit.grabFocus then
    p.unit:grabFocus("cancelReleased")
  end
  Encoder.set(Encoder.Neutral)
end

local function step(direction)
  local p = active
  local unit, control = p.unit, p.control
  local current = positionOf(unit, control)
  if current == nil then
    return
  end
  local target = current + direction
  if target < 1 or target > movableCount(unit) then
    return
  end
  -- The rebuild this triggers runs disableSelection, which fires onCursorLeave
  -- on this very control. Mark it so the leave handler does not read our own
  -- rebuild as the user navigating away and cancel the placement.
  p.internalRebuild = true
  unit:moveControlFollowingCursor(control.id, "expanded", target, current)
end

local function onEncoder(self, change, shifted)
  local p = claim(self)
  if p == nil then
    return delegate(self, "encoder", change, shifted)
  end
  p.sum = p.sum + change
  if p.sum > threshold then
    p.sum = 0
    step(1)
  elseif p.sum < -threshold then
    p.sum = 0
    step(-1)
  end
  return true
end

local function onEnter(self)
  local p = claim(self)
  if p == nil then
    return delegate(self, "enterReleased")
  end
  finish()
  if p.onCommit then
    p.onCommit()
  end
  return true
end

local function onAbort(self, shifted)
  local p = claim(self)
  if p == nil then
    return delegate(self, "cancelReleased", shifted)
  end
  if shifted then
    return false
  end
  finish()
  if p.onCancel then
    p.onCancel()
  end
  return true
end

-- UP and HOME abort rather than being ignored: both navigate away from the
-- target unit, and leaving placement live on a window the user has left would
-- strand the encoder grab and the inert macro together.
local function onAbortAlways(self)
  local p = claim(self)
  if p == nil then
    return delegate(self, "upReleased")
  end
  finish()
  if p.onCancel then
    p.onCancel()
  end
  return true
end

-- Losing the cursor ends the placement. Two cases have to be told apart:
--
--   * OUR OWN rebuild. Every encoder step reorders the view, and the rebuild
--     brackets itself with disable/enableSelection -- so a leave fires on this
--     control and a matching enter follows immediately. step() flags those;
--     the flag is consumed here, once per rebuild.
--   * The user navigating away, with a main button or any other cursor move.
--     That cancels.
--
-- The cancel is POSTED rather than run inline because this handler is reached
-- from inside disableSelection, part way through a rebuild of the very section
-- the rollback is about to remove a control from.
local function onCursorLeave(self, spotIndex, shifted)
  local p = claim(self)
  if p == nil then
    return delegate(self, "onCursorLeave", spotIndex, shifted)
  end
  if p.internalRebuild then
    p.internalRebuild = false
    return delegate(self, "onCursorLeave", spotIndex, shifted)
  end
  local onCancel = p.onCancel
  finish()
  local Application = require "Application"
  Application.post(function()
    if onCancel then
      onCancel()
    end
  end)
  return delegate(self, "onCursorLeave", spotIndex, shifted)
end

-- args: unit (the promotion target), control (the inert macro's ViewControl),
-- onCommit, onCancel.
function Placement.begin(args)
  if active then
    -- Should not happen: the fan-out menu is not reachable during placement.
    -- Abort the older one rather than interleave two sets of shadows.
    finish()
  end

  local unit, control = args.unit, args.control
  if not reveal(unit) then
    return false
  end

  -- Rebuild synchronously WITH the macro as the focus control, so the cursor
  -- lands on it. createInertMacro's placeControl only posts an unfocused
  -- rebuild, so until this runs the macro has no spot handle to select.
  unit:rebuildView("expanded", control, 1)

  active = {
    unit = unit,
    control = control,
    onCommit = args.onCommit,
    onCancel = args.onCancel,
    sum = 0
  }

  -- Per-instance shadows, not class overrides: Base.Class deep-copies members
  -- into subclasses at definition time, so touching the class would reach every
  -- GainBias control in the patch. An instance takes its class as the metatable
  -- (Class.lua:73,82), so a field set here shadows the method and clearing it in
  -- finish() restores the original.
  control.encoder = onEncoder
  control.enterReleased = onEnter
  control.cancelReleased = onAbort
  control.upReleased = onAbortAlways
  control.homeReleased = onAbortAlways
  control.onCursorLeave = onCursorLeave

  -- Grabbed AFTER the rebuild: the rebuild's disable/enableSelection cycle runs
  -- onCursorLeave, which releases the encoder grab.
  control:grabFocus("encoder", "upReleased", "cancelReleased")
  Encoder.set(Encoder.Neutral)

  if control.controlGraphic then
    -- Same "held" affordance the Editor uses for its move gesture
    -- (Unit/Editor.lua ItemHeader:subPressed).
    control.controlGraphic:setBorder(3)
  end

  -- createInertMacro's placeControl left an UNFOCUSED rebuild pending for this
  -- frame. Replace it with a focused one, and flag it, or it would knock the
  -- cursor off the macro the instant placement starts -- which now reads as the
  -- user navigating away and cancels the whole gesture.
  active.internalRebuild = true
  unit:rebuildViewFollowingControl("expanded", control)

  local Overlay = require "Overlay"
  Overlay.flashSubMessage("Place with knob. ENTER to promote.")
  return true
end

function Placement.isActive()
  return active ~= nil
end

-- Escape hatch for callers that need to tear placement down without running
-- either callback (a patch being cleared out from under it, say).
function Placement.abandon()
  finish()
end

return Placement

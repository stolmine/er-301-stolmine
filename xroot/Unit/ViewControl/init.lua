local Class = require "Base.Class"
local Base = require "SpottedStrip.Control"
local Encoder = require "Encoder"

local ViewControl = Class {}
ViewControl:include(Base)

function ViewControl:init(name)
  Base.init(self)
  self:setClassName("Unit.ViewControl")
  self:setInstanceName(name)
  self.encoderState = Encoder.Neutral
  self.pinCount = 0
end

function ViewControl:getRootChain()
  local parent = self.parent
  return parent and parent.getRootChain and parent:getRootChain()
end

function ViewControl:configureBorderShape()
  local view = self:callUp("getView")
  local controls = view.controls
  local n = #controls
  -- Usually, the first visible control is after the insert control.
  if n == 1 and self == controls[1] then
    -- added this case for the control editor
    self.controlGraphic:setCornerRadius(5, 5, 5, 5)
  elseif self == controls[2] then
    if self == controls[n] then
      -- the one and only visible control
      self.controlGraphic:setCornerRadius(5, 5, 5, 5)
    else
      -- the first visible control
      self.controlGraphic:setCornerRadius(5, 5, 0, 0)
    end
  elseif self == controls[n] then
    -- the last visible control
    self.controlGraphic:setCornerRadius(0, 0, 5, 5)
  else
    -- in the middle
    self.controlGraphic:setCornerRadius(0, 0, 0, 0)
  end
end

function ViewControl:getBranch()
  return self.branch
end

function ViewControl:serialize()
  return {}
end

function ViewControl:deserialize(t)
end

function ViewControl:onFocused()
end

function ViewControl:onUnfocused()
end

function ViewControl:rename(name)
  self:setInstanceName(name)
end

function ViewControl:getDisplayName()
  return self:getInstanceName()
end

function ViewControl:enableHighlight()
  self:configureBorderShape()
  self.controlGraphic:setBorder(1)
  if self:callUp("hasView", self.id) then
    if self.moreLeft then
      self.moreLeft:show()
    else
      local graphic = self:getControlGraphic()
      self.moreLeft = app.MoreThisWay(app.left)
      graphic:addChild(self.moreLeft)
    end
  end
  self.focused = true
end

function ViewControl:disableHighlight()
  self.controlGraphic:setBorder(0)
  Encoder.set(Encoder.Neutral)
  if self.moreLeft then
    self.moreLeft:hide()
  end
  self.focused = false
end

function ViewControl:focus(notify)
  if notify == nil then
    notify = true
  end
  self:grabFocus("encoder", "upReleased", "cancelReleased")
  self:enableHighlight()
  if notify then
    self:onFocused()
  end
end

function ViewControl:unfocus(notify)
  if notify == nil then
    notify = true
  end
  self:releaseFocus("encoder", "upReleased", "cancelReleased")
  self:disableHighlight()
  if notify then
    self:onUnfocused()
  end
end

function ViewControl:dialPressed(shifted)
  if shifted then
    return false
  end
  self.encoderState = Encoder.Neutral
  Encoder.set(self.encoderState)
  return true
end

function ViewControl:onCursorMove(spot, spot0)
  -- app.logInfo("%s.onCursorMove(%s,%s)",self,spot,spot0)
end

function ViewControl:onCursorEnter(spot)
  -- app.logInfo("%s.onCursorEnter(%s)",self,spot)
  self:addSubGraphic(self.subGraphic)
  self:grabFocus("dialPressed", "dialReleased", "subPressed", "subReleased",
                 "homeReleased", "homePressed", "zeroPressed", "enterReleased",
                 "selectReleased")
  Encoder.set(self.encoderState)
end

function ViewControl:onCursorLeave(spot)
  -- app.logInfo("%s.onCursorLeave(%s)",self,spot)
  self:removeSubGraphic(self.subGraphic)
  self:releaseFocus("dialPressed", "dialReleased", "subPressed", "subReleased",
                    "homeReleased", "homePressed", "zeroPressed",
                    "enterReleased", "cancelReleased", "upReleased",
                    "selectReleased", "encoder")
  self:disableHighlight()
end

function ViewControl:toggleContext()
  local hadFocus = self:hasFocus("encoder")
  local viewChanged = false
  -- call up context view
  if self:callUp("hasView", self.id) then
    -- a context view for this control exists
    if self:queryUp("currentViewName") == self.id then
      self:callUp("switchView", "expanded", self)
      viewChanged = true
    else
      self:callUp("leftJustify")
      self:callUp("switchView", self.id, self)
      viewChanged = true
    end
  elseif self:queryUp("currentViewName") ~= "expanded" then
    self:callUp("switchView", "expanded")
    viewChanged = true
  end
  -- Hack
  if viewChanged then
    -- switchView will fail call CursorEnter
    self:callUp("disableSelection")
    self:callUp("enableSelection")
  end
  if hadFocus and viewChanged then
    -- need to grab focus again, since switchView will lose it
    self:focus(false)
  end
end

-- [stol:promote-control-to-top-level] ------------------------------------------
-- Is this control's modulation input the output of a macro on another unit?
--
-- That is exactly the shape promotion leaves behind, and it is DERIVED rather
-- than flagged, which is the point: the branch's input source is already part of
-- the serialized patch, so this survives a reload with nothing extra written.
-- A stored flag would have to be kept in step with the wiring; this cannot drift
-- from it because it IS the wiring.
--
-- The probe is `src.object` being a ControlBranch: Chain builds its output source
-- as Source.Internal over the chain itself (Chain/init.lua), and only a
-- ControlBranch carries both `classType` and `control`.
function ViewControl:isDrivenByMacro()
  local branch = self.branch
  local source = branch and branch.getInputSource and branch:getInputSource(1)
  local object = source and source.object
  return object ~= nil and object.classType ~= nil and object.control ~= nil
end

-- Show the value actually passing through, rather than this control's own bias.
--
-- After promotion the origin holds 0 and the macro holds the value, so the
-- origin's readout would say 0 while the patch plays 440 Hz. Rebinding the
-- readout to the range object's Center makes it report what is really there.
-- This is the same swap the global `unitControlReadoutSource = "actual"` setting
-- performs at construction (GainBias.lua, Pitch.lua), applied per control and
-- only while the control is being driven.
--
-- Only the READOUT moves. The fader's target and value parameters still point at
-- the control's own bias, so the encoder keeps editing the trim and the bar keeps
-- showing it. Rebinding those too would leave the user unable to reach the offset
-- the control still owns.
--
-- No-op when the global setting is already "actual", since the readout is showing
-- the true value anyway and "restoring" it later would silently turn the setting
-- off for that control.
function ViewControl:refreshDrivenState()
  self:refreshDrivenReadout(self:isDrivenByMacro())
end

-- NO MARK on a promoted origin, decided 2026-08-13 and worth recording because
-- it looks like an omission. A control being driven while its readout shows its
-- own bias is not a special state that needs explaining: it is what EVERY
-- modulated control on this instrument already does, and users read it fluently.
-- Marking the promoted case would single out the one instance of an existing
-- convention.
function ViewControl:refreshDrivenReadout(driven)
  local fader = self.fader
  if fader == nil or fader.setControlParameter == nil then
    return
  end
  local Settings = require "Settings"
  if Settings.get("unitControlReadoutSource") == "actual" then
    return
  end
  if driven then
    if self.preMacroReadout == nil then
      local range = fader.getRangeObject and fader:getRangeObject()
      local center = range and range:getParameter("Center")
      if center == nil then
        return
      end
      self.preMacroReadout = fader:getValueParameter()
      fader:setControlParameter(center)
    end
  elseif self.preMacroReadout then
    fader:setControlParameter(self.preMacroReadout)
    self.preMacroReadout = nil
  end
end

function ViewControl:createPinMark()
  local Drawings = require "Drawings"
  local graphic = app.Drawing(0, 0, app.SECTION_PLY, 64)
  graphic:add(Drawings.Control.Pin)
  self.controlGraphic:addChildOnce(graphic)
  self.pinMark = graphic
end

-- [stol:control-shift-subdisplay-indicator] ---------------------------------
-- Does this control swap its sub display when SHIFT is held?
--
-- Structural probe, no declaration required, so every package (including
-- third-party and anything written before this existed) is covered for free.
-- It works because NO class in the ViewControl hierarchy defines shiftPressed
-- -- there is no inherited no-op for a subclass to "override" and thereby
-- false-positive on. Controls that own a shift sub display define shiftPressed
-- and grab focus for it; the same w[event] ~= nil test is already used by
-- emu/UIState.lua to build its gesture map.
--
-- Probe shiftPressed and NOT shiftReleased, deliberately:
--   * Chain.Base defines shiftReleased and is always in the focus chain.
--   * Some controls (third-party strike DualOptionControl) define shiftPressed
--     with no shiftReleased at all.
--
-- Header is the one genuine false positive in core: it grabs SHIFT purely to
-- scroll its command lists, with no sub display swap. Excluded by id.
--
-- Known miss: controls that repurpose SHIFT+encoder to scroll a list have no
-- structural signature and are not marked. That is intended -- the mark means
-- "SHIFT changes what the sub display shows", not "SHIFT does something".
function ViewControl:hasShiftLayer()
  if self.id == "header" then
    return false
  end
  return self.shiftPressed ~= nil
end

function ViewControl:refreshShiftLayerMark()
  local Settings = require "Settings"
  local wanted = Settings.get("showShiftLayerHints") == true and
                     self:hasShiftLayer()
  if wanted then
    if self.shiftLayerMark == nil then
      local Drawings = require "Drawings"
      local graphic = app.Drawing(0, 0, app.SECTION_PLY, 64)
      graphic:add(Drawings.Control.ShiftLayer)
      self.controlGraphic:addChildOnce(graphic)
      -- Hold the Lua reference or the Drawing is collected out from under the
      -- C++ child list (same reason createPinMark keeps self.pinMark).
      self.shiftLayerMark = graphic
    end
    self.shiftLayerMark:show()
  elseif self.shiftLayerMark then
    self.shiftLayerMark:hide()
  end
end

function ViewControl:onShiftLayerHintsChanged()
  self:refreshShiftLayerMark()
end

-- Resolved here rather than in init() because a control has no parent while it
-- is being constructed; onInsert runs from Unit/Section.lua after the parent is
-- attached. Habitat overrides onInsert zero times across 12 packages.
function ViewControl:onInsert()
  local Signal = require "Signal"
  Signal.weakRegister("onShiftLayerHintsChanged", self)
  self:refreshShiftLayerMark()
end

function ViewControl:onPinned()
  if self.pinCount == 0 then
    if self.pinMark == nil then
      self:createPinMark()
    end
    self.pinMark:show()
  end
  self.pinCount = self.pinCount + 1
end

function ViewControl:onUnpinned()
  if self.pinCount == 1 then
    self.pinMark:hide()
  end
  self.pinCount = self.pinCount - 1
end

function ViewControl:spotReleased(spot, shifted)
  if shifted then
    return false
  end
  if self.focused then
    self:unfocus()
  else
    self:focus()
  end
  return true
end

function ViewControl:getFloatingMenuItems()
  local t = {}
  if self:callUp("hasView", self.id) then
    if self:queryUp("currentViewName") == self.id then
      t[1] = "collapse"
    else
      t[1] = "expand"
    end
  end
  if self.canEdit then
    t[#t + 1] = "edit"
  end
  -- [stol:promote-control-to-top-level] Absent, not greyed, when it does not
  -- apply. Promote.check is the single choke point for every precondition
  -- (exact-metatable control class, at least one ancestor, scene authoring, scene
  -- engaged); do not inline any of them here. It lives on the base rather than on
  -- GainBias because Base.Class copies methods into subclasses, so an override
  -- there would be inherited by the ~49 habitat GainBias subclasses this must
  -- NOT offer -- the metatable test inside Promote.check is what excludes them.
  if require("Unit.Promote").check(self, true) then
    t[#t + 1] = "promote"
  end
  if self.getPinControl then
    local chain = self:getRootChain()
    if chain and chain.isRoot then
      local pinSetNames = chain:getPinSetNames()
      local pinned, pinCount = chain:getPinSetMembership(self)
      if #pinSetNames > 1 and #pinSetNames > pinCount then
        t[#t + 1] = "pin to all"
      end
      if pinCount > 1 then
        t[#t + 1] = "unpin from all"
      end
      for _, name in ipairs(pinSetNames) do
        if pinned[name] then
          t[#t + 1] = "unpin from " .. name
        else
          t[#t + 1] = "pin to " .. name
        end
      end
      t[#t + 1] = "pin to <new>"
    end
  end
  return t
end

function ViewControl:onFloatingMenuSelection(choice)
  local Utils = require "Utils"
  if choice == "expand" or choice == "collapse" then
    self:toggleContext()
    return true
  elseif choice == "edit" then
    self:callUp("doEditControl", self)
    return true
  elseif choice == "promote" then
    -- Re-check without `quiet`: the menu was built from a snapshot and the scene
    -- state can have changed since it opened, and here we DO want the flash.
    local Promote = require "Unit.Promote"
    local ok, reason = Promote.check(self, false)
    if not ok then
      if reason then
        local Overlay = require "Overlay"
        Overlay.flashMainMessage(reason)
      end
      return true
    end
    Promote.begin(self)
    return true
  elseif choice == "pin to all" then
    local chain = self:getRootChain()
    if chain and chain.isRoot then
      chain:pinControlToAllPinSets(self)
    end
  elseif choice == "unpin from all" then
    local chain = self:getRootChain()
    if chain and chain.isRoot then
      chain:unpinControlFromAllPinSets(self)
    end
  elseif choice == "pin to <new>" then
    local chain = self:getRootChain()
    if chain and chain.isRoot then
      local Keyboard = require "Keyboard"
      local kb = Keyboard("New PinSet", chain:suggestPinSetName(), true,
                          "NamingStuff")
      local task = function(text)
        if text then
          local pinSet = chain:addPinSet{
            name = text
          }
          pinSet:startViewModifications()
          pinSet:pinControl(self)
          pinSet:endViewModifications()
        end
      end
      kb:subscribe("done", task)
      kb:show()
    end
    return true
  elseif Utils.startsWith(choice, "pin to ") then
    local name = choice:sub(8)
    local chain = self:getRootChain()
    if chain and chain.isRoot then
      local pinSet = chain:getPinSetByName(name)
      pinSet:startViewModifications()
      pinSet:pinControl(self)
      pinSet:endViewModifications()
    end
    return true
  elseif Utils.startsWith(choice, "unpin from ") then
    local name = choice:sub(12)
    local chain = self:getRootChain()
    if chain and chain.isRoot then
      local pinSet = chain:getPinSetByName(name)
      pinSet:startViewModifications()
      pinSet:unpinControl(self)
      pinSet:endViewModifications()
    end
    return true
  else
    return Base.onFloatingMenuSelection(self, choice)
  end
end

function ViewControl:enterReleased()
  self:toggleContext()
  return true
end

function ViewControl:upReleased(shifted)
  if not shifted then
    self:unfocus()
  end
  return true
end

function ViewControl:onRemove()
  -- app.logInfo("%s:onRemove()",self)
  if self.pinCount > 0 then
    local chain = self:getRootChain()
    if chain and chain.isRoot then
      chain:unpinControlFromAllPinSets(self)
    else
      app.logInfo("%s:onRemove(): failed to get root chain.", self)
    end
  end
  Base.onRemove(self)
end

return ViewControl

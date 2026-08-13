-- [stol:promote-control-to-top-level] Placement: choose WHERE on the target
-- unit's strip the macro lands, before it exists.
--
-- Step 4 of planning/control-promotion-plan.md §7. Read its CURRENT STATE header
-- before changing anything here.
--
-- This is a proxy screen in the shape of Unit.Editor's "Edit Controls" list:
-- each existing control is a name-and-type panel, and the macro being placed is
-- one more panel that the encoder walks along the row. ENTER commits, CANCEL
-- walks away.
--
-- IT REPLACED an in-place version that created the macro first and moved the
-- REAL control around on the unit's own strip. That read as though the promotion
-- had already happened: the fader was right there, focusable, and turning the
-- encoder after focusing it made the control appear to vanish (it was being
-- moved, or the gesture was being cancelled out from under the user). Reported
-- from the bench 2026-08-13. Two things follow from doing it this way instead,
-- and both are the point rather than side effects:
--
--   * NOTHING IS CREATED UNTIL ENTER. The old version leaned on an "inert macro"
--     -- real branch, real control, just unwired -- and on rolling it back
--     cleanly. Here there is nothing to roll back from a cancel, so the cancel
--     boundary the plan's §7 worries about is structural instead of maintained.
--   * NO LIVE CONTROL TO MIS-FOCUS. The old version shadowed handlers on the
--     macro's own ViewControl to steal the encoder, which meant a placement that
--     outlived its gesture left a booby-trapped fader behind. That whole class
--     of bug does not exist here: this screen is its own window and overrides
--     its own methods.
--
-- Promote.createInertMacro and Promote.rollback still exist and are still used:
-- the macro is created at commit and rolled back only if the transplant itself
-- refuses.

local app = app
local Env = require "Env"
local Class = require "Base.Class"
local SpottedStrip = require "SpottedStrip"
local Section = require "SpottedStrip.Section"
local SpottedControl = require "SpottedStrip.Control"
local Encoder = require "Encoder"
local ply = app.SECTION_PLY

--------------------------------------------------
local Label = Class {}
Label:include(SpottedControl)

function Label:init(text, style)
  SpottedControl.init(self)
  self:setClassName("Unit.PromotePlaceView.Label")
  local panel = app.TextPanel(text, 1)
  if style == "ghost" then
    -- The one the user is holding: full-brightness border, and a thick border
    -- once selected, matching the Editor's "Place with Knob" affordance.
    panel:setBorderColor(app.WHITE)
  elseif style == "header" then
    panel:setBackgroundColor(app.GRAY2)
    panel:setOpaque(true)
  else
    -- Existing controls are context, not choices: dimmed so the held one reads
    -- as the only thing in motion.
    panel:setBorderColor(app.GRAY5)
    panel:setForegroundColor(app.GRAY7)
  end
  self.panel = panel
  self.verticalDivider = ply
  self:setControlGraphic(panel)
  self:addSpotDescriptor{
    center = 0.5 * ply,
    radius = ply
  }
end

--------------------------------------------------
local Item = Class {}
Item:include(Section)

function Item:init(text, style, sectionStyle)
  Section.init(self, sectionStyle or app.sectionNoBorder)
  self:setClassName("Unit.PromotePlaceView.Item")
  self:addView("default")
  self.label = Label(text, style)
  self:addControl("default", self.label)
  self:switchView("default")
end

--------------------------------------------------
local PromotePlaceView = Class {}
PromotePlaceView:include(SpottedStrip)

-- onPlace(position) is called with the 1-based slot among the target unit's
-- MOVABLE controls -- the indexing UnitSection:placeControl expects.
function PromotePlaceView:init(targetUnit, macroName, macroType, onPlace)
  SpottedStrip.init(self)
  self:setClassName("Unit.PromotePlaceView")
  self:setInstanceName(targetUnit.title)
  self.targetUnit = targetUnit
  self.macroName = macroName
  self.macroType = macroType or "GainBias"
  self.onPlace = onPlace
  self.sum = 0

  local Drawings = require "Drawings"
  local drawing = app.Drawing(0, 0, 128, 64)
  drawing:add(Drawings.Sub.HelpfulButtons)
  self.subGraphic:addChild(drawing)
  self.subGraphic:addChild(app.TextPanel("Place here", 1, 0.5,
                                         app.GRID5_LINE3 - 1))

  self:build()
end

function PromotePlaceView:build()
  self:clear()
  self:appendSection(Item(self.targetUnit.title, "header", app.sectionBegin))

  -- Existing controls, in strip order. The first two entries of a unit view are
  -- always the insert and header controls, which are not placeable and are not
  -- shown (Unit/Section.lua parseViewDescriptor).
  local view = self.targetUnit:getView("expanded")
  if view then
    for i, control in ipairs(view.controls) do
      if i > 2 then
        local name = control.getDisplayName and control:getDisplayName() or
                         control.id or "control"
        self:appendSection(Item(string.format("%s %s", name,
                                              control.type or "Control")))
      end
    end
  end

  self.ghost = Item(string.format("%s %s", self.macroName, self.macroType),
                    "ghost")
  self:appendSection(self.ghost)
  self:appendSection(Item("End of Unit", nil, app.sectionEnd))

  self:setSelection(self.ghost, "default",
                    self.ghost.label:getSpotValue(1, "handle"))
  self.ghost.label.controlGraphic:setBorder(3)
end

-- Section index of the held item. Position 1 is the header and the last position
-- is the end-of-unit marker, so the held item lives in [2, count-1].
function PromotePlaceView:moveGhost(direction)
  local current = self:getSelectedSectionPosition()
  local target = current + direction
  if target < 2 or target > self:getSectionCount() - 1 then
    return
  end
  -- moveSection re-applies the previous selection, so the cursor stays on the
  -- held item and the row appears to slide underneath it.
  self:moveSection(self.ghost, target)
end

local threshold = Env.EncoderThreshold.Default
function PromotePlaceView:encoder(change, shifted)
  self.sum = self.sum + change
  if self.sum > threshold then
    self.sum = 0
    self:moveGhost(1)
  elseif self.sum < -threshold then
    self.sum = 0
    self:moveGhost(-1)
  end
  return true
end

function PromotePlaceView:enterReleased()
  -- Section index minus the header gives the 1-based slot among movable
  -- controls: held item at section 2 means "before everything", position 1.
  local position = self:getSelectedSectionPosition() - 1
  self:hide()
  if self.onPlace then
    self.onPlace(position)
  end
  return true
end

-- The sub display draws "Place here" over button 1, so button 1 has to do it.
-- A label that names an action the button does not perform is worse than no
-- label.
function PromotePlaceView:subReleased(i, shifted)
  if shifted then
    return false
  end
  if i == 1 then
    return self:enterReleased()
  end
  return true
end

-- Every way out other than ENTER is a plain abandon. Nothing has been created,
-- so there is nothing to undo.
function PromotePlaceView:cancelReleased(shifted)
  if not shifted then
    self:hide()
  end
  return true
end

function PromotePlaceView:upReleased(shifted)
  self:hide()
  return true
end

function PromotePlaceView:homeReleased()
  self:hide()
  return true
end

function PromotePlaceView:onShow()
  Encoder.set(Encoder.Neutral)
end

function PromotePlaceView:onHide()
  Encoder.set(Encoder.Neutral)
end

return PromotePlaceView

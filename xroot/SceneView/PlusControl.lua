-- PlusControl: empty-slot affordance for the Performance view.
-- Renders a centered "+" glyph (Drawings.Control.Plus, two
-- crossed lines) inside a ply-wide group. Sits at the right
-- edge of the SpottedStrip section as the user's invitation to
-- add a new scene.
--
-- Performance removes this control from the section when
-- sceneCount hits kMaxScenes, and re-adds it after a delete
-- brings the count back below the cap.

local app = app
local Class = require "Base.Class"
local SpottedControl = require "SpottedStrip.Control"
local Drawings = require "Drawings"

local ply = app.SECTION_PLY

local PlusControl = Class {}
PlusControl:include(SpottedControl)

function PlusControl:init()
  SpottedControl.init(self)
  self:setClassName("SceneView.PlusControl")

  -- controlGraphic: bordered TextPanel-style container with the
  -- "+" glyph centered. Border matches the quicksave Slot pattern
  -- so the focus highlight reads as part of the same row of
  -- selectables.
  local graphic = app.Graphic(0, 0, ply, 64)

  self.panel = app.TextPanel("", 1)
  self.panel:setCornerRadius(3, 3, 3, 3)
  self.panel:setBorder(1)
  self.panel:setBorderColor(app.GRAY3)
  graphic:addChild(self.panel)

  -- Plus glyph: 9 x 9 Drawing centered on the panel (x=20,
  -- y=32 is the panel's visual center in local coords; subtract
  -- 4 to set the glyph's left/bottom).
  local glyph = app.Drawing(20 - 4, 32 - 4, 9, 9)
  glyph:add(Drawings.Control.Plus)
  graphic:addChild(glyph)

  self:setControlGraphic(graphic)
  self:addSpotDescriptor{
    center = 0.5 * ply,
    radius = 0.5 * ply
  }

  -- Sub display: "new scene -- tap M to create" message.
  local sub = app.Graphic(0, 0, 128, 64)
  local label = app.Label("new scene -- tap M to create", 10)
  label:setJustification(app.justifyLeft)
  label:setPosition(5, 53)
  sub:addChild(label)
  self.menuGraphic = sub
end

function PlusControl:onCursorEnter()
  self.panel:setBorderColor(app.WHITE)
  self:addSubGraphic(self.menuGraphic)
  self:grabFocus("subReleased")
end

function PlusControl:onCursorLeave()
  self.panel:setBorderColor(app.GRAY3)
  self:removeSubGraphic(self.menuGraphic)
  self:releaseFocus("subReleased")
end

function PlusControl:spotReleased(spotIndex, shifted)
  if shifted then return true end
  return self:callUp("addScene")
end

function PlusControl:subReleased(i, shifted)
  -- No S-key bindings on the empty placeholder; tap M to create
  -- is the only path forward.
  return false
end

return PlusControl

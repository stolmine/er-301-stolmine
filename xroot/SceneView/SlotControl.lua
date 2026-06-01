-- Per-slot widget for the scene Performance view. Wraps a
-- TextPanel (scene name on the body of the ply) with a small
-- A/B chip in the top-right marking whether the slot is bound
-- to a crossfader endpoint. The previous delta-count "Nd"
-- overlay was dropped in favor of the Performance sub-display
-- delta list, which has more room to show what's actually
-- delta'd.
--
-- One SlotControl per ply column (M2-M6 in Performance.lua). The
-- caller drives state via setScene / setEmpty; the widget owns
-- nothing beyond its rendering.

local app = app
local Class = require "Base.Class"

local SlotControl = Class {}

local ply             = app.SECTION_PLY
local kFontMain       = 9
local kFontChip       = 9
-- A/B chip position inside the ply (relative; X is added at init).
local kChipDX         = ply - 8
local kChipY          = 49

function SlotControl:init(args)
  local window = args.window or error("SlotControl: window required")
  local column = args.column or error("SlotControl: column required")
  self.column  = column
  local plyLeft = (column - 1) * ply

  -- Body: rounded transparent panel with a 1px GRAY3 border.
  -- Mirrors the QuickSaver slot UX (xroot/Persist/QuickSaver.lua)
  -- so scene slots and quicksave slots have the same visual idiom.
  -- The Performance view's cursorBox handles selection emphasis
  -- separately.
  self.panel = app.TextPanel("", column)
  self.panel:setCornerRadius(3, 3, 3, 3)
  self.panel:setBorder(1)
  self.panel:setBorderColor(app.GRAY3)
  window:addMainGraphic(self.panel)

  -- A/B chip overlay: small label at top-right of the ply.
  self.chip = app.Label("", kFontChip)
  self.chip:setJustification(app.justifyCenter)
  self.chip:setCenter(plyLeft + kChipDX, kChipY)
  self.chip:setForegroundColor(app.WHITE)
  window:addMainGraphic(self.chip)
end

-- Render an empty slot: blank text, no chip. Used both for the
-- "+" placeholder ply (Performance.lua draws its own "+" on top)
-- and for ply positions past the last occupied scene.
function SlotControl:setEmpty()
  self.panel:setText("")
  self.chip:setText("")
end

-- Render an occupied slot. `crossfaderRole` is one of "A" / "B" /
-- nil; when set the chip glyph appears in the top-right corner.
function SlotControl:setScene(scene, crossfaderRole)
  if scene == nil then
    self:setEmpty()
    return
  end
  self.panel:setText(scene:getName())
  if crossfaderRole then
    self.chip:setText(crossfaderRole)
  else
    self.chip:setText("")
  end
end

return SlotControl

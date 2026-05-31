-- Per-slot widget for the scene Performance view. Wraps a
-- TextPanel (scene name on the body of the ply) with two small
-- overlays at the corners: an A/B chip in the top-right marking
-- whether the slot is bound to a crossfader endpoint, and a
-- delta count ("Nd") in the bottom-right hinting at slot density.
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
local kFontCount      = 8
-- Overlay positions inside the ply (relative; X is added at init).
-- Top-right Y just below the ply's top edge; bottom-right Y just
-- above the slot panel's bottom. Using setCenter() positions
-- the label's bounding box midpoint, so these are eyeballed to
-- straddle the panel's corners cleanly.
local kChipDX         = ply - 8
local kChipY          = 49
local kCountDX        = ply - 12
local kCountY         = 12

function SlotControl:init(args)
  local window = args.window or error("SlotControl: window required")
  local column = args.column or error("SlotControl: column required")
  self.column  = column
  local plyLeft = (column - 1) * ply

  -- Body: unit-header-style TextPanel anchoring the slot. Text
  -- (scene name or blank) set by setScene / setEmpty.
  self.panel = app.TextPanel("", column)
  self.panel:setBackgroundColor(app.GRAY2)
  self.panel:setOpaque(true)
  window:addMainGraphic(self.panel)

  -- A/B chip overlay: small label at top-right of the ply.
  self.chip = app.Label("", kFontChip)
  self.chip:setJustification(app.justifyCenter)
  self.chip:setCenter(plyLeft + kChipDX, kChipY)
  self.chip:setForegroundColor(app.WHITE)
  window:addMainGraphic(self.chip)

  -- Delta count overlay: "Nd" at bottom-right of the ply. Hidden
  -- when scene has zero deltas (slot is empty of overrides).
  self.count = app.Label("", kFontCount)
  self.count:setJustification(app.justifyCenter)
  self.count:setCenter(plyLeft + kCountDX, kCountY)
  self.count:setForegroundColor(app.GRAY7)
  window:addMainGraphic(self.count)
end

-- Render an empty slot: blank text, no chip, no count. Used both
-- for the "+" placeholder ply (Performance.lua draws its own "+"
-- on top) and for ply positions past the last occupied scene.
function SlotControl:setEmpty()
  self.panel:setText("")
  self.chip:setText("")
  self.count:setText("")
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
  local n = scene:countDeltas()
  if n > 0 then
    self.count:setText(string.format("%dd", n))
  else
    self.count:setText("")
  end
end

return SlotControl

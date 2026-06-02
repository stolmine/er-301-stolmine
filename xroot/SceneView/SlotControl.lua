-- Per-slot widget for the scene Performance view. Wraps a
-- TextPanel (scene name on the body of the ply) with a small
-- A/B chip in the top-right marking whether the slot is bound
-- to a crossfader endpoint. The previous delta-count "Nd"
-- overlay was dropped in favor of the Performance sub-display
-- delta list, which has more room to show what's actually
-- delta'd.
--
-- A hollow circle indicator sits beneath the scene name. When
-- the slot is bound to A or B it fills in horizontally (A from
-- the left, B from the right) as the morpher's live weight
-- moves toward this slot's endpoint, giving an at-a-glance read
-- of who's contributing how much to the audio crossfade.
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
-- Bias-fill circle: small hollow ring centered horizontally on
-- the ply, sitting below the scene-name text. Radius 5 gives an
-- 11 px diameter — visible without crowding the text.
local kIndicatorRadius = 5
local kIndicatorBottom = 6

function SlotControl:init(args)
  local window = args.window or error("SlotControl: window required")
  local column = args.column or error("SlotControl: column required")
  self.column  = column
  local plyLeft = (column - 1) * ply

  -- Body: rounded transparent panel, no border. Slot plies have
  -- no top-level controls to select for editing, so they never
  -- get the editing-border treatment standard chain plies get;
  -- navigation is conveyed purely by the ▼ caret above the ply.
  self.panel = app.TextPanel("", column)
  self.panel:setCornerRadius(3, 3, 3, 3)
  window:addMainGraphic(self.panel)

  -- A/B chip overlay: small label at top-right of the ply.
  self.chip = app.Label("", kFontChip)
  self.chip:setJustification(app.justifyCenter)
  self.chip:setCenter(plyLeft + kChipDX, kChipY)
  self.chip:setForegroundColor(app.WHITE)
  window:addMainGraphic(self.chip)

  -- Bias-fill indicator: hollow circle, fills horizontally per
  -- live weight. Constructor takes (left, bottom, radius); the
  -- widget's own width/height is 2r+1 each side. Centered
  -- horizontally on the ply.
  local indicatorLeft = plyLeft + math.floor(ply / 2) - kIndicatorRadius
  self.indicator = app.SceneSlotIndicator(indicatorLeft,
                                          kIndicatorBottom,
                                          kIndicatorRadius)
  window:addMainGraphic(self.indicator)
end

-- Wire the indicator's bias source. Pass the morpher's "Weight"
-- Parameter so the indicator tracks the live crossfade weight
-- including CV. Idempotent — safe to call repeatedly.
function SlotControl:setBiasSource(weightParam)
  self.indicator:setBias(weightParam)
end

-- Render an empty slot: blank text, no chip, indicator unassigned.
-- Used both for the "+" placeholder ply (Performance.lua draws its
-- own "+" on top) and for ply positions past the last occupied
-- scene.
function SlotControl:setEmpty()
  self.panel:setText("")
  self.chip:setText("")
  self.indicator:setSide(app.SceneSlotIndicator.kSideNone)
end

-- Render an occupied slot. `crossfaderRole` is one of "A" / "B" /
-- nil; when set the chip glyph appears in the top-right corner
-- and the bias-fill indicator activates on the corresponding side.
function SlotControl:setScene(scene, crossfaderRole)
  if scene == nil then
    self:setEmpty()
    return
  end
  self.panel:setText(scene:getName())
  if crossfaderRole == "A" then
    self.chip:setText("A")
    self.indicator:setSide(app.SceneSlotIndicator.kSideA)
  elseif crossfaderRole == "B" then
    self.chip:setText("B")
    self.indicator:setSide(app.SceneSlotIndicator.kSideB)
  else
    self.chip:setText("")
    self.indicator:setSide(app.SceneSlotIndicator.kSideNone)
  end
end

return SlotControl

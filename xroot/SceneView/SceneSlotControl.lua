-- SceneSlotControl: one SpottedControl per scene in the hold-mode
-- Performance view. Replaces the column-indexed SlotControl.
--
-- Sits between M1Control (on its left) and PlusControl + later
-- SceneSlotControls (on its right) inside Performance's single
-- SpottedStrip Section. SpottedStrip pans the camera across the
-- whole row when the cursor moves past the visible viewport;
-- this control just declares its appearance and per-spot input
-- handling.
--
-- Per-control state:
--   - shifted: toggled by Performance on shift press/release.
--     Determines the S1/S2/S3 sub-display labels and which
--     action the S keys invoke.
--   - sceneIdx: the index into SceneView this control represents.
--     Updated as scenes are added / deleted (Performance rebuilds
--     the section on those events).

local app = app
local Class = require "Base.Class"
local SpottedControl = require "SpottedStrip.Control"

local ply = app.SECTION_PLY
local kFontChip       = 9
-- TextPanel positions itself with a 43 px stride internally;
-- decorations anchored to the panel's actual center stay
-- aligned across scrolled positions.
local kTextPanelStride = 43
-- Constants no longer needed: SpottedStrip section positions
-- the panel; we just declare local geometry within the
-- (0..ply) coordinate space.
local kChipDX         = ply - 8
local kChipY          = 49
local kIndicatorRadius = 5
local kIndicatorBottom = 6

-- Sub-display layout: matches Performance's prior _refreshSub.
local kSubStatusY = 53
local kSlotS1     = app.SubButton
local kSlotS2     = app.SubButton
local kSlotS3     = app.SubButton

-- Indicator-side constants (mirror od::SceneSlotIndicator's static
-- consts; kept Lua-local to avoid SWIG class-static-access
-- ambiguity across versions).
local kSideNone = 0
local kSideA    = 1
local kSideB    = 2

local SceneSlotControl = Class {}
SceneSlotControl:include(SpottedControl)

function SceneSlotControl:init(sceneIdx, scene, weightParam)
  SpottedControl.init(self)
  self:setClassName("SceneView.SceneSlotControl")
  self.sceneIdx = sceneIdx
  self.scene    = scene
  self.shifted  = false
  self.crossfaderRole = nil  -- "A" / "B" / nil

  -- controlGraphic: ply-wide group with the TextPanel (scene name)
  -- + A/B chip overlay + bias-fill indicator. Border on the
  -- TextPanel is the cursor-focus cue (GRAY3 default, WHITE on
  -- focus -- matches quicksave Slot pattern).
  local graphic = app.Graphic(0, 0, ply, 64)
  self.panel = app.TextPanel("", 1)
  self.panel:setCornerRadius(3, 3, 3, 3)
  self.panel:setBorder(1)
  self.panel:setBorderColor(app.GRAY3)
  if scene then self.panel:setText(scene:getName()) end
  graphic:addChild(self.panel)

  self.chip = app.Label("", kFontChip)
  self.chip:setJustification(app.justifyCenter)
  self.chip:setCenter(kChipDX, kChipY)
  self.chip:setForegroundColor(app.WHITE)
  graphic:addChild(self.chip)

  -- Bias-fill indicator: centered horizontally in the ply at
  -- (ply/2). Pre-attached to the morpher Weight Parameter the
  -- caller passes in.
  self.indicator = app.SceneSlotIndicator(
      math.floor(ply / 2) - kIndicatorRadius,
      kIndicatorBottom,
      kIndicatorRadius)
  if weightParam then self.indicator:setBias(weightParam) end
  graphic:addChild(self.indicator)

  self:setControlGraphic(graphic)

  self:addSpotDescriptor{
    center = 0.5 * ply,
    radius = 0.5 * ply
  }

  -- subGraphic: status line + S1/S2/S3 SubButton labels. Same
  -- content the old _refreshSub painted per-column; now owned
  -- by the control itself.
  local sub = app.Graphic(0, 0, 128, 64)
  self.subStatus = app.Label("", 10)
  self.subStatus:setJustification(app.justifyLeft)
  self.subStatus:setPosition(5, kSubStatusY)
  sub:addChild(self.subStatus)
  self.s1Button = app.SubButton("", 1)
  sub:addChild(self.s1Button)
  self.s2Button = app.SubButton("", 2)
  sub:addChild(self.s2Button)
  self.s3Button = app.SubButton("", 3)
  sub:addChild(self.s3Button)
  self.menuGraphic = sub

  self:_refreshLabels()
end

function SceneSlotControl:setScene(scene, crossfaderRole)
  self.scene = scene
  self.crossfaderRole = crossfaderRole
  if scene then
    self.panel:setText(scene:getName())
  else
    self.panel:setText("")
  end
  if crossfaderRole == "A" then
    self.chip:setText("A")
    self.indicator:setSide(kSideA)
  elseif crossfaderRole == "B" then
    self.chip:setText("B")
    self.indicator:setSide(kSideB)
  else
    self.chip:setText("")
    self.indicator:setSide(kSideNone)
  end
  self:_refreshLabels()
end

function SceneSlotControl:setShifted(shifted)
  if self.shifted == shifted then return end
  self.shifted = shifted
  self:_refreshLabels()
end

function SceneSlotControl:setBiasSource(weightParam)
  self.indicator:setBias(weightParam)
end

function SceneSlotControl:onCursorEnter()
  self.panel:setBorderColor(app.WHITE)
  self:addSubGraphic(self.menuGraphic)
  self:grabFocus("subReleased")
end

function SceneSlotControl:onCursorLeave()
  self.panel:setBorderColor(app.GRAY3)
  self:removeSubGraphic(self.menuGraphic)
  self:releaseFocus("subReleased")
  -- Reset shifted state on cursor leave: when the user comes
  -- back to this slot later, it should start in default sub
  -- display, not whatever shift toggle was last left here.
  if self.shifted then self:setShifted(false) end
end

-- Shift+M on the slot triggers delete. Plain M just selects
-- (cursor moves here via SpottedStrip dispatch; nothing else
-- to do).
function SceneSlotControl:spotReleased(spotIndex, shifted)
  if shifted then
    return self:callUp("deleteScene", self.sceneIdx)
  end
  return true
end

function SceneSlotControl:subReleased(i, shifted)
  -- effShifted = real shift held OR sub-display shift toggle.
  -- Performance keeps the toggle in sync via Signal-driven
  -- shiftPressed / shiftReleased -> setShifted(true/false).
  local eff = shifted or self.shifted
  if eff then
    if i == 1 then return self:callUp("duplicateScene", self.sceneIdx) end
    if i == 2 then return self:callUp("renameScene", self.sceneIdx) end
    if i == 3 then return self:callUp("deleteScene", self.sceneIdx) end
    return false
  end
  if i == 1 then
    return self:callUp("toggleEndpoint", self.sceneIdx, "A")
  elseif i == 2 then
    return self:callUp("toggleEndpoint", self.sceneIdx, "B")
  elseif i == 3 then
    return self:callUp("enterAuthoring", self.sceneIdx)
  end
  return false
end

------------------------------------------------------------
-- Internal: refresh the sub-display labels based on shifted
-- + crossfader-role state. Mirrors the prior _refreshSub block.

function SceneSlotControl:_refreshLabels()
  if self.scene == nil then return end
  local chip = ""
  if self.crossfaderRole then
    chip = " (" .. self.crossfaderRole .. ")"
  end
  self.subStatus:setText(string.format("scene %d: %s%s",
                                        self.sceneIdx,
                                        self.scene:getName(),
                                        chip))
  if self.shifted then
    self.s1Button:setText("copy")
    self.s2Button:setText("rename")
    self.s3Button:setText("delete")
  else
    if self.crossfaderRole == "A" then
      self.s1Button:setText("*A")
    else
      self.s1Button:setText("asgn A")
    end
    if self.crossfaderRole == "B" then
      self.s2Button:setText("*B")
    else
      self.s2Button:setText("asgn B")
    end
    self.s3Button:setText("edit")
  end
end

return SceneSlotControl

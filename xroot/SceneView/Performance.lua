-- Performance view for scene mode. Top-level Window the user
-- lands in after toggling the front-panel hold switch into scene
-- mode. Layout:
--
--   M1   M2   M3   M4   M5   M6
--   CV  [S1] [S2] [S3] [+]
--
-- M1 always hosts the CV input widget (the source the crossfader
-- reads from). M2..M6 are scene slots, populated left-to-right.
-- The first un-populated ply renders a floating "+" placeholder
-- that's the user's affordance to add a new scene; it moves
-- rightward as scenes are created.
--
-- M-keys are the PRIMARY selection mechanism (discrete tap to
-- jump). Encoder is a secondary route for cursor scrolling.
--
-- Phase 2 scope: layout + cursor + scene creation + selection.
-- S-key handlers (A/B assign, rename, enter authoring) and the
-- CV picker dive are stubbed; they land in phases 2c-2d.

local app = app
local Class = require "Base.Class"
local Window = require "Base.Window"
local Env = require "Env"
local Signal = require "Signal"
local SlotControl = require "SceneView.SlotControl"

local Performance = Class {}
Performance:include(Window)

-- Layout constants. SECTION_PLY = 42 px (one M-key column).
-- Slot ply spans the full M-key region (height 60 leaves 4 px
-- top + bottom for cursor box outline / chip area below).
local ply             = app.SECTION_PLY
local kSlotHeight     = 50
local kSlotY          = 7              -- bottom of slot panel (Y bottom-up)
local kCursorOutline  = 1
local kFontMain       = 9
local kFontSub        = 10
local kFontPlus       = 12
local kEncoderThreshold = Env.EncoderThreshold.Default

-- Per-ply X position (column-major helper). app.TextPanel takes
-- a 1-based column index and positions itself; for our cursor box
-- and floating "+" we need explicit X.
local function plyX(col) return (col - 1) * ply end

function Performance:init(sceneView)
  Window.init(self)
  self:setClassName("SceneView.Performance")
  self.sceneView = sceneView
  self.chain     = sceneView.chain

  -- cursorCol = 1..6 (1 = CV widget, 2..6 = slot positions, with
  -- the "+" ply being the first un-populated slot).
  self.cursorCol    = 1
  self.encoderAccum = 0

  -- M1: CV input widget. TextPanel with the input source's name
  -- (or "CV in" placeholder when unset).
  self.cvPanel = app.TextPanel("", 1)
  self.cvPanel:setBackgroundColor(app.GRAY2)
  self.cvPanel:setOpaque(true)
  self:addMainGraphic(self.cvPanel)

  -- M2..M6: SlotControl widgets. Each renders one scene's name +
  -- A/B chip overlay + delta count. Performance just tells each
  -- one which scene (if any) it represents on every refresh.
  self.slots = {}
  for col = 2, 6 do
    self.slots[col] = SlotControl { window = self, column = col }
  end

  -- Floating "+" placeholder: sits at the first un-populated ply
  -- (column 2 + sceneCount, capped at 6). Hidden when all 5 slots
  -- are full or when sceneCount == 0 forces it to slot 2 (which
  -- is the default empty state -- user's invitation to start).
  self.plusLabel = app.Label("+", kFontPlus)
  self.plusLabel:setJustification(app.justifyCenter)
  self:addMainGraphic(self.plusLabel)

  -- Cursor outline: 1-px border tracking the currently selected
  -- ply. Rendered over the slot panels so the user sees which
  -- column M-key would target.
  self.cursorBox = app.Graphic(0, kSlotY, ply, kSlotHeight)
  self.cursorBox:setBorder(kCursorOutline)
  self.cursorBox:setBorderColor(app.WHITE)
  self:addMainGraphic(self.cursorBox)

  -- Sub display: scene context for the currently selected ply.
  self.subStatus = app.Label("", kFontSub)
  self.subStatus:setPosition(2, app.GRID4_LINE1)
  self.subStatus:setJustification(app.justifyLeft)
  self:addSubGraphic(self.subStatus)

  self.subHint = app.Label("", kFontMain)
  self.subHint:setPosition(2, app.GRID4_LINE3)
  self.subHint:setJustification(app.justifyLeft)
  self.subHint:setForegroundColor(app.GRAY7)
  self:addSubGraphic(self.subHint)

  self:_refresh()
end

-- The "+" ply column: M2 if sceneCount == 0, else M(2+sceneCount).
-- Returns nil when scenes have filled all 5 slot positions
-- (sceneCount == 5).
function Performance:_plusCol()
  local n = self.sceneView:getSceneCount()
  if n >= 5 then return nil end
  return n + 2
end

-- Repaint everything from current state.
function Performance:_refresh()
  local sceneCount = self.sceneView:getSceneCount()

  -- M1 CV input widget text. Falls back to "CV in" when no
  -- source is bound.
  local cvRef = self.sceneView:getCvInput()
  self.cvPanel:setText(cvRef or "CV in")

  -- M2..M6 slots. SlotControl handles name + A/B chip + delta
  -- count rendering; we just hand it the scene + crossfader role.
  local a = self.sceneView:getCrossfaderA()
  local b = self.sceneView:getCrossfaderB()
  for col = 2, 6 do
    local sceneIdx = col - 1
    local scene = self.sceneView:getScene(sceneIdx)
    local role
    if scene then
      if a == sceneIdx then role = "A"
      elseif b == sceneIdx then role = "B" end
    end
    self.slots[col]:setScene(scene, role)
  end

  -- "+" placeholder position and visibility.
  local plusCol = self:_plusCol()
  if plusCol then
    -- Center the "+" inside its ply (ply center = (col-1)*ply + ply/2).
    local x = plyX(plusCol) + ply / 2
    self.plusLabel:setCenter(x, kSlotY + kSlotHeight / 2)
    self.plusLabel:show()
  else
    self.plusLabel:hide()
  end

  -- Cursor box: 1-px outline at the selected column.
  self.cursorBox:setPosition(plyX(self.cursorCol), kSlotY)

  -- Sub display: context for the currently selected ply.
  self:_refreshSub()
end

function Performance:_refreshSub()
  local col = self.cursorCol
  if col == 1 then
    self.subStatus:setText("CV input")
    local cv = self.sceneView:getCvInput()
    self.subHint:setText(cv and ("source: " .. cv) or "no source bound")
  else
    local sceneIdx = col - 1
    local scene = self.sceneView:getScene(sceneIdx)
    if scene then
      self.subStatus:setText(string.format("scene %d: %s", sceneIdx, scene:getName()))
      local a = self.sceneView:getCrossfaderA()
      local b = self.sceneView:getCrossfaderB()
      local chip = ""
      if a == sceneIdx then chip = chip .. " A" end
      if b == sceneIdx then chip = chip .. " B" end
      local deltas = scene:countDeltas()
      self.subHint:setText(string.format("%dd%s", deltas, chip))
    elseif col == self:_plusCol() then
      self.subStatus:setText("new scene")
      self.subHint:setText("tap M to create")
    else
      self.subStatus:setText("")
      self.subHint:setText("")
    end
  end
end

-- The rightmost selectable ply: M1 always; M(1+sceneCount) for
-- occupied scenes; the "+" ply if not all slots are full. Used by
-- encoder navigation to know when to stop.
function Performance:_maxSelectableCol()
  local n = self.sceneView:getSceneCount()
  local plusCol = self:_plusCol()
  if plusCol then return plusCol end
  return n + 1
end

-- ---------------------------------------------------------------------------
-- Input handlers
-- ---------------------------------------------------------------------------

function Performance:encoder(change, shifted)
  self.encoderAccum = self.encoderAccum + change
  local moved = false
  local maxCol = self:_maxSelectableCol()
  while self.encoderAccum >= kEncoderThreshold do
    self.encoderAccum = self.encoderAccum - kEncoderThreshold
    if self.cursorCol < maxCol then
      self.cursorCol = self.cursorCol + 1
      moved = true
    end
  end
  while self.encoderAccum <= -kEncoderThreshold do
    self.encoderAccum = self.encoderAccum + kEncoderThreshold
    if self.cursorCol > 1 then
      self.cursorCol = self.cursorCol - 1
      moved = true
    end
  end
  if moved then self:_refresh() end
  return true
end

function Performance:mainReleased(i, shifted)
  if shifted then return false end
  if i < 1 or i > 6 then return true end
  local plusCol = self:_plusCol()
  if i == plusCol then
    -- Tap on the "+" placeholder: create a new scene + move
    -- cursor to it.
    self.sceneView:addScene()
    self.cursorCol = i
    self:_refresh()
    return true
  end
  -- Tap on M1 or any occupied slot: just move the cursor there.
  -- Past-the-end (no scene, not the "+" ply): no-op.
  if i == 1 or self.sceneView:getScene(i - 1) then
    self.cursorCol = i
    self:_refresh()
    return true
  end
  return true
end

function Performance:homeReleased()
  self.cursorCol = 1
  self:_refresh()
  return true
end

return Performance

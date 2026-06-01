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
  if i < 1 or i > 6 then return true end
  -- shift+M on an occupied slot triggers delete-with-confirmation.
  -- shift+M on M1 / the "+" / blank plies is a no-op.
  if shifted then
    if i >= 2 then
      local sceneIdx = i - 1
      local scene = self.sceneView:getScene(sceneIdx)
      if scene then return self:_confirmDelete(sceneIdx, scene) end
    end
    return true
  end
  local plusCol = self:_plusCol()
  if i == plusCol then
    -- Tap on the "+" placeholder: create a new scene + move
    -- cursor to it.
    self.sceneView:addScene()
    self:_rebuildSceneMorph()  -- new scene appended past A/B, no-op for current items but kept for symmetry with delete
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

function Performance:_confirmDelete(sceneIdx, scene)
  local Verification = require "Verification"
  local dlg = Verification.Sub(
    string.format("Delete scene %d (%s)?", sceneIdx, scene:getName()),
    "")
  dlg:subscribe("done", function(ans)
    if ans then
      self.sceneView:removeScene(sceneIdx)
      self:_rebuildSceneMorph()
      -- Snap cursor back into bounds if we just deleted the
      -- currently-selected slot (or any slot past the now-shrunk
      -- range).
      local maxCol = self:_maxSelectableCol()
      if self.cursorCol > maxCol then self.cursorCol = maxCol end
      self:_refresh()
    end
  end)
  dlg:show()
  return true
end

function Performance:homeReleased()
  self.cursorCol = 1
  self:_refresh()
  return true
end

-- S-key dispatch depends on what's at the cursor:
--   on M1 (CV widget): S3 opens the CV input picker.
--   on a slot ply:     S1 cycles the slot's crossfader role
--                      (off -> A -> B -> off); S2 renames the
--                      slot; S3 enters Authoring view (stubbed
--                      pending phase 3).
function Performance:subReleased(i, shifted)
  if shifted then return false end
  local col = self.cursorCol
  if col == 1 then
    if i == 3 then return self:_openCvPicker() end
    return false
  end
  -- Slot plies.
  local sceneIdx = col - 1
  local scene = self.sceneView:getScene(sceneIdx)
  if scene == nil then return false end
  if i == 1 then
    return self:_cycleCrossfaderRole(sceneIdx)
  elseif i == 2 then
    return self:_renameScene(sceneIdx, scene)
  elseif i == 3 then
    return self:_enterAuthoring(sceneIdx)
  end
  return false
end

function Performance:_openCvPicker()
  local SourceChooser = require "Source.Chooser"
  local chooser = self.chain and SourceChooser(self.chain) or SourceChooser()
  chooser:subscribe("choose", function(src)
    -- Source:serialize returns a string for Externals (the CV
    -- jack name) and a richer table for Internal sources. Either
    -- form round-trips through SceneView.serialize.
    self.sceneView:setCvInput(src and src:serialize() or nil)
    self:_refresh()
  end)
  chooser:show()
  return true
end

-- Cycle the slot's crossfader role through off -> A -> B -> off.
-- If sceneIdx is already assigned to the OTHER endpoint, the
-- cycle skips over that side (e.g. if it's currently B and B is
-- taken, the next tap unsets it instead of trying to claim A
-- when A is also taken). Slot-takes-precedence: if another slot
-- currently holds A and this slot grabs A, the other slot loses
-- its role (handled by SceneView:setCrossfaderA enforcing
-- one-slot-per-endpoint via the assignment itself).
function Performance:_cycleCrossfaderRole(sceneIdx)
  local a = self.sceneView:getCrossfaderA()
  local b = self.sceneView:getCrossfaderB()
  if a == sceneIdx then
    -- Currently A -> become B (displaces any existing B).
    self.sceneView:setCrossfaderA(0)
    self.sceneView:setCrossfaderB(sceneIdx)
  elseif b == sceneIdx then
    -- Currently B -> unassign.
    self.sceneView:setCrossfaderB(0)
  else
    -- Currently off -> become A (displaces any existing A).
    self.sceneView:setCrossfaderA(sceneIdx)
  end
  self:_rebuildSceneMorph()
  self:_refresh()
  return true
end

-- Tell the chain's engine-side morpher to rebuild items per the
-- current crossfader assignments. Called from any UI gesture that
-- mutates which scene sits at A or B, or that creates / deletes
-- scenes (since the new/missing scene may affect endpoint
-- resolution for current A/B). Guarded so chains without a scene
-- morpher (engine not yet engaged this session) no-op.
function Performance:_rebuildSceneMorph()
  if self.chain and self.chain.rebuildSceneMorph then
    self.chain:rebuildSceneMorph()
  end
end

function Performance:_renameScene(sceneIdx, scene)
  local Keyboard = require "Keyboard"
  local kb = Keyboard("Rename scene", scene:getName(), true, "NamingStuff")
  kb:subscribe("done", function(text)
    if text and text ~= "" then
      scene:setName(text)
      self:_refresh()
    end
  end)
  kb:show()
  return true
end

-- Authoring view dive. Routes through Channels so the current
-- ChannelGroup builds + activates the per-scene authoring
-- context. The Authoring view's UP / shift+HOME / CANCEL handlers
-- come back here via Channels.leaveSceneAuthoring.
function Performance:_enterAuthoring(sceneIdx)
  local Channels = require "Channels"
  Channels.enterSceneAuthoring(sceneIdx)
  return true
end

return Performance

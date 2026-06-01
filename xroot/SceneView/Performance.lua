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
local Encoder = require "Encoder"
local SlotControl = require "SceneView.SlotControl"

-- GainBias sub-display layout (mirrors Unit.ViewControl.GainBias).
-- Centers + lines come from app.GRID5_* / app.BUTTON*_CENTER so
-- the readouts and SubButtons line up with the panel-paint
-- positions of S1/S2/S3.
local subLine1   = app.GRID5_LINE1
local subLine4   = app.GRID5_LINE4
local subCenter1 = app.GRID5_CENTER1
local subCenter3 = app.GRID5_CENTER3
local subCenter4 = app.GRID5_CENTER4
local subCol1    = app.BUTTON1_CENTER
local subCol2    = app.BUTTON2_CENTER
local subCol3    = app.BUTTON3_CENTER

-- mult-and-sum diagram (= GainBias unit-control's sub-display
-- instructions). Built once at module load.
local subInstructions = app.DrawingInstructions()
subInstructions:circle(subCol2, subCenter3, 8)
subInstructions:line(subCol2 - 3, subCenter3 - 3,
                     subCol2 + 3, subCenter3 + 3)
subInstructions:line(subCol2 - 3, subCenter3 + 3,
                     subCol2 + 3, subCenter3 - 3)
subInstructions:circle(subCol3, subCenter3, 8)
subInstructions:hline(subCol3 - 5, subCol3 + 5, subCenter3)
subInstructions:vline(subCol3, subCenter3 - 5, subCenter3 + 5)
subInstructions:hline(subCol1 + 20, subCol2 - 9, subCenter3)
subInstructions:triangle(subCol2 - 12, subCenter3, 0, 3)
subInstructions:hline(subCol2 + 9, subCol3 - 8, subCenter3)
subInstructions:triangle(subCol3 - 11, subCenter3, 0, 3)
subInstructions:vline(subCol3, subCenter3 + 8, subLine1 - 2)
subInstructions:triangle(subCol3, subLine1 - 2, 90, 3)

local Performance = Class {}
Performance:include(Window)

-- Layout constants. SECTION_PLY = 42 px (one M-key column).
-- M1 fader + slot TextPanels both render at full 64 height; the
-- cursor outline frames the entire ply so the selection cue is
-- consistent across the heterogeneous M1 fader and M2..M6 slots.
local ply             = app.SECTION_PLY
local kSlotHeight     = 64
local kSlotY          = 0
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

  -- M1: crossfader weight control. A Fader bound to the chain's
  -- scene-cv GainBias bias parameter. Encoder-on-M1 drives the
  -- focused readout (bias by default; S2/S3 swap between gain
  -- and bias). S1-on-M1 dives into the scene-cv branch where the
  -- user inserts CV / LFO / S&H / whatever to modulate weight.
  -- The morpher reads GainBias.Out at audio rate so manual +
  -- CV both flow into the crossfade.
  -- Full-height fader, same dimensions as a top-level unit's
  -- GainBias control (Fader 0,0,ply,64) so M1 visually matches
  -- the rest of the firmware's encoder controls. Range bar to
  -- the right of the slot tracks gb.Out via the chain's
  -- _sceneCVRange MinMax object.
  self.cvFader = app.Fader(plyX(1), 0, ply, 64)
  self.cvFader:setLabel("xfade")
  if self.chain and self.chain.getSceneCVGainBias then
    local gb = self.chain:getSceneCVGainBias()
    self._gainParam = gb:getParameter("Gain")
    self._biasParam = gb:getParameter("Bias")
    self._gainParam:enableSerialization()
    self._biasParam:enableSerialization()
    self.cvFader:setParameter(self._biasParam)
    self.cvFader:setMap(Encoder.getMap("default"))
    self.cvFader:setUnits(app.unitNone)
    self.cvFader:setPrecision(2)
    if self.chain.getSceneCVRange then
      local range = self.chain:getSceneCVRange()
      if range then self.cvFader:setRangeObject(range) end
    end
  end
  self:addMainGraphic(self.cvFader)

  -- M1 sub-display: GainBias-style. Built once and toggled
  -- via show/hide vs the slot context display in _refresh.
  self.m1SubGroup = app.Graphic(0, 0, 128, 64)
  self:addSubGraphic(self.m1SubGroup)

  if self._biasParam then
    local drawing = app.Drawing(0, 0, 128, 64)
    drawing:add(subInstructions)
    self.m1SubGroup:addChild(drawing)

    self.m1Scope = app.MiniScope(subCol1 - 20, subLine4, 40, 45)
    self.m1Scope:setBorder(1)
    self.m1Scope:setCornerRadius(3, 3, 3, 3)
    self.m1SubGroup:addChild(self.m1Scope)

    self.m1Gain = app.Readout(0, 0, ply, 10)
    self.m1Gain:setParameter(self._gainParam)
    self.m1Gain:setCenter(subCol2, subCenter4)
    self.m1Gain:setMap(Encoder.getMap("gain"))
    self.m1Gain:setUnits(app.unitNone)
    self.m1Gain:setPrecision(2)
    self.m1SubGroup:addChild(self.m1Gain)

    self.m1Bias = app.Readout(0, 0, ply, 10)
    self.m1Bias:setParameter(self._biasParam)
    self.m1Bias:setCenter(subCol3, subCenter4)
    self.m1Bias:setMap(Encoder.getMap("default"))
    self.m1Bias:setUnits(app.unitNone)
    self.m1Bias:setPrecision(2)
    self.m1SubGroup:addChild(self.m1Bias)

    local desc = app.Label("X-fade", 10)
    desc:fitToText(3)
    desc:setSize(ply * 2, desc.mHeight)
    desc:setBorder(1)
    desc:setCornerRadius(3, 0, 0, 3)
    desc:setCenter(0.5 * (subCol2 + subCol3), subCenter1 + 1)
    self.m1SubGroup:addChild(desc)

    self.m1ModButton = app.SubButton("empty", 1)
    self.m1SubGroup:addChild(self.m1ModButton)
    self.m1SubGroup:addChild(app.SubButton("gain", 2))
    self.m1SubGroup:addChild(app.SubButton("bias", 3))

    self.m1GainEncoderState = Encoder.Coarse
    self.encoderState       = Encoder.Coarse
    -- Initial focus via the helper so the readout's save() fires
    -- (needed so cancelReleased's restore() has a sane value to
    -- snap back to). Also sets the sub cursor controller.
    self:_setM1FocusedReadout(self.m1Bias)

    -- Subscribe to the scene-cv branch's contentChanged so the
    -- mod button label + scope outlet stay in sync with what
    -- the user has wired into the branch.
    if self.chain.getSceneCVBranch then
      self._sceneCVBranch = self.chain:getSceneCVBranch()
      if self._sceneCVBranch then
        self._sceneCVBranch:subscribe("contentChanged", self)
      end
    end
  end

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

  -- Slot sub-display: scene context for an M2..M6 cursor. Lives
  -- in its own container so we can flip between this and the M1
  -- GainBias-style display by show/hide on the containers.
  self.slotSubGroup = app.Graphic(0, 0, 128, 64)
  self:addSubGraphic(self.slotSubGroup)

  -- Top-left: scene name / index.
  self.subStatus = app.Label("", kFontSub)
  self.subStatus:setPosition(2, app.GRID4_LINE1)
  self.subStatus:setJustification(app.justifyLeft)
  self.slotSubGroup:addChild(self.subStatus)

  -- Slot S-button labels so the user can see what S1/S2/S3 do
  -- on a scene slot before pressing them. setText repopulates
  -- per refresh (chip text per slot's current A/B role; "edit"
  -- always on S3).
  self.slotS1 = app.SubButton("", 1)
  self.slotS2 = app.SubButton("", 2)
  self.slotS3 = app.SubButton("", 3)
  self.slotSubGroup:addChild(self.slotS1)
  self.slotSubGroup:addChild(self.slotS2)
  self.slotSubGroup:addChild(self.slotS3)

  -- Main encoder cursor starts on the M1 bias fader so the
  -- bouncing caret is visible from the moment the user lands in
  -- Performance.
  self:setMainCursorController(self.cvFader)

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

  -- M1 fader is bound directly to the GainBias bias parameter;
  -- nothing to refresh here -- the fader re-reads target() each
  -- frame from its own draw path.

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

  -- Move the bouncing main caret to track the selected ply.
  -- M1 owns the bias fader's left-of-bias caret; slot columns
  -- use their SlotControl panel so the caret hugs the slot.
  if self.cursorCol == 1 then
    self:setMainCursorController(self.cvFader)
    self:setSubCursorController(self.m1FocusedReadout or self.m1Bias)
  else
    local slot = self.slots and self.slots[self.cursorCol]
    self:setMainCursorController(slot and slot.panel or nil)
    self:setSubCursorController(nil)
  end

  -- Sub display: context for the currently selected ply.
  self:_refreshSub()
end

function Performance:_refreshSub()
  local col = self.cursorCol
  if col == 1 then
    -- M1 = GainBias-style sub display (gain readout + bias
    -- readout + branch mod button + scope). Show that, hide
    -- the slot context labels.
    if self.m1SubGroup then self.m1SubGroup:show() end
    if self.slotSubGroup then self.slotSubGroup:hide() end
    return
  end

  -- M2..M6: scene context labels. Hide M1 sub display.
  if self.m1SubGroup then self.m1SubGroup:hide() end
  if self.slotSubGroup then self.slotSubGroup:show() end

  local sceneIdx = col - 1
  local scene = self.sceneView:getScene(sceneIdx)
  if scene then
    -- Top-left: index + name + (A/B) chip when bound.
    local a = self.sceneView:getCrossfaderA()
    local b = self.sceneView:getCrossfaderB()
    local chip = ""
    if a == sceneIdx then chip = " (A)"
    elseif b == sceneIdx then chip = " (B)"
    end
    self.subStatus:setText(string.format("scene %d: %s%s",
                                          sceneIdx, scene:getName(), chip))
    -- S1: toggle A on this slot. Label flips between "asgn A"
    -- (will assign) and "*A" (already A; pressing unassigns).
    if a == sceneIdx then
      self.slotS1:setText("*A")
    else
      self.slotS1:setText("asgn A")
    end
    if b == sceneIdx then
      self.slotS2:setText("*B")
    else
      self.slotS2:setText("asgn B")
    end
    self.slotS3:setText("edit")
  elseif col == self:_plusCol() then
    self.subStatus:setText("new scene -- tap M to create")
    self.slotS1:setText("")
    self.slotS2:setText("")
    self.slotS3:setText("")
  else
    self.subStatus:setText("")
    self.slotS1:setText("")
    self.slotS2:setText("")
    self.slotS3:setText("")
  end
end

-- Signal callback: branch contents changed (user inserted /
-- removed a unit in the scene-cv branch). Update the mod-button
-- label and the scope outlet so the user sees what's wired.
function Performance:contentChanged(chain)
  if chain ~= self._sceneCVBranch then return end
  if self.m1ModButton then
    self.m1ModButton:setText(chain:mnemonic())
  end
  if self.m1Scope then
    self.m1Scope:watchOutlet(chain:getMonitoringOutput(1))
  end
end

-- Focus one of the M1 readouts so the encoder writes to it. Also
-- repoints the sub cursor controller so the bouncing caret moves
-- to the focused readout (standard GainBias UX).
function Performance:_setM1FocusedReadout(readout)
  if readout then readout:save() end
  self.m1FocusedReadout = readout
  self:setSubCursorController(readout)
end

-- Decimal keyboard for direct value entry on the gain readout.
function Performance:_m1GainSet()
  local Decimal = require "Keyboard.Decimal"
  local kb = Decimal {
    message = "CV gain into crossfader.",
    commitMessage = "CV gain updated.",
    initialValue = self.m1Gain:getValueInUnits()
  }
  local task = function(value)
    if value then
      self.m1Gain:save()
      self.m1Gain:setValueInUnits(value)
    end
  end
  kb:subscribe("done", task)
  kb:subscribe("commit", task)
  kb:show()
end

-- Standard unit-control keybinds for the focused M1 readout.
-- zero -> snap to 0.0. cancel -> restore the value the readout
-- saved when focus last entered it.
function Performance:zeroPressed()
  if self.cursorCol == 1 and self.m1FocusedReadout then
    self.m1FocusedReadout:zero()
    return true
  end
end

function Performance:cancelReleased(shifted)
  if shifted then return false end
  if self.cursorCol == 1 and self.m1FocusedReadout then
    self.m1FocusedReadout:restore()
    return true
  end
end

-- DIAL_PRESS toggles fine / coarse encoder on the focused readout
-- (same as standard GainBias / Fader controls). Bias readout
-- uses self.encoderState; gain readout has its own state.
function Performance:dialPressed(shifted)
  if self.cursorCol ~= 1 then return end
  if self.m1FocusedReadout == self.m1Gain then
    if self.m1GainEncoderState == Encoder.Coarse then
      self.m1GainEncoderState = Encoder.Fine
    else
      self.m1GainEncoderState = Encoder.Coarse
    end
    Encoder.set(self.m1GainEncoderState)
  else
    if self.encoderState == Encoder.Coarse then
      self.encoderState = Encoder.Fine
    else
      self.encoderState = Encoder.Coarse
    end
    Encoder.set(self.encoderState)
  end
  return true
end

function Performance:_m1BiasSet()
  local Decimal = require "Keyboard.Decimal"
  local kb = Decimal {
    message = "Crossfader weight bias.",
    commitMessage = "X-fade bias updated.",
    initialValue = self.m1Bias:getValueInUnits()
  }
  local task = function(value)
    if value then
      self.m1Bias:save()
      self.m1Bias:setValueInUnits(value)
    end
  end
  kb:subscribe("done", task)
  kb:subscribe("commit", task)
  kb:show()
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
  -- Cursor on M1: encoder drives the focused readout (gain or
  -- bias, swapped via S2/S3). Dedicated to readout edit while
  -- focused here; user navigates away by tapping M2..M6.
  if self.cursorCol == 1 then
    if self.m1FocusedReadout then
      local fine
      if self.m1FocusedReadout == self.m1Gain then
        fine = (self.m1GainEncoderState == Encoder.Fine)
      else
        fine = (self.encoderState == Encoder.Fine)
      end
      self.m1FocusedReadout:encoder(change, shifted, fine)
    end
    return true
  end
  -- Cursor on a slot ply: encoder navigates between M-keys.
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
  local col = self.cursorCol
  if col == 1 then
    -- M1 = GainBias-style crossfader weight control.
    -- shifted: S2 / S3 -> decimal keyboard for direct gain / bias
    -- entry (like the OG GainBias unit control). S1 unused when
    -- shifted.
    if shifted then
      if i == 2 then self:_m1GainSet(); return true
      elseif i == 3 then self:_m1BiasSet(); return true
      end
      return false
    end
    -- Unshifted:
    --   S1 dives into the scene-cv branch.
    --   S2 focuses the gain readout (encoder writes to gain). If
    --       already focused on gain, opens decimal keyboard for
    --       direct entry (matches GainBias UX).
    --   S3 focuses the bias readout, same toggle.
    if i == 1 then return self:_diveSceneCV() end
    if i == 2 then
      if self.m1FocusedReadout == self.m1Gain then
        self:_m1GainSet()
      else
        self:_setM1FocusedReadout(self.m1Gain)
      end
      return true
    end
    if i == 3 then
      if self.m1FocusedReadout == self.m1Bias then
        self:_m1BiasSet()
      else
        self:_setM1FocusedReadout(self.m1Bias)
      end
      return true
    end
    return false
  end
  -- Slot plies.
  local sceneIdx = col - 1
  local scene = self.sceneView:getScene(sceneIdx)
  if scene == nil then return false end

  -- Shifted: S2 -> rename (was previously the unshifted role).
  -- No other shifted slot bindings yet.
  if shifted then
    if i == 2 then return self:_renameScene(sceneIdx, scene) end
    return false
  end

  -- Unshifted: S1 toggle A, S2 toggle B, S3 dive into authoring.
  if i == 1 then
    return self:_toggleEndpoint(sceneIdx, "A")
  elseif i == 2 then
    return self:_toggleEndpoint(sceneIdx, "B")
  elseif i == 3 then
    return self:_enterAuthoring(sceneIdx)
  end
  return false
end

-- Show the chain's scene-cv branch window (where the user
-- inserts CV-source units that feed the GainBias.In). Mirrors
-- the GainBias-control S1 dive UX in regular unit views.
function Performance:_diveSceneCV()
  if not (self.chain and self.chain.getSceneCVBranch) then return true end
  local branch = self.chain:getSceneCVBranch()
  if branch and branch.show then
    branch:show()
  end
  return true
end

-- Toggle a slot's binding to endpoint A or B. Idempotent: if
-- the slot is already that endpoint, the press unassigns. If
-- another slot currently holds the endpoint, that slot loses
-- its role (SceneView:setCrossfader{A,B} enforces one slot per
-- endpoint via the assignment itself). If the slot was bound
-- to the OTHER endpoint, the press transfers it to the
-- requested endpoint.
function Performance:_toggleEndpoint(sceneIdx, role)
  local a = self.sceneView:getCrossfaderA()
  local b = self.sceneView:getCrossfaderB()
  if role == "A" then
    if a == sceneIdx then
      self.sceneView:setCrossfaderA(0)
    else
      if b == sceneIdx then
        -- Transferring: release B first so we don't end up at
        -- both endpoints, which the setters guard against.
        self.sceneView:setCrossfaderB(0)
      end
      self.sceneView:setCrossfaderA(sceneIdx)
    end
  else  -- B
    if b == sceneIdx then
      self.sceneView:setCrossfaderB(0)
    else
      if a == sceneIdx then
        self.sceneView:setCrossfaderA(0)
      end
      self.sceneView:setCrossfaderB(sceneIdx)
    end
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

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
local Drawings = require "Drawings"

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

  -- Horizontal scroll for the 5-wide slot viewport (M2..M6).
  -- SceneView caps at kMaxScenes (16 / chain). Visible scene at
  -- visible col N (N in [2, 6]) = scene at index N - 1 + scrollOffset.
  -- scrollOffset == 0 reproduces the legacy 5-scenes-max layout.
  self.scrollOffset = 0

  -- cursorCol = 1..6 (1 = CV widget, 2..6 = slot positions, with
  -- the "+" ply being the first un-populated slot).
  self.cursorCol    = 1
  self.encoderAccum = 0

  -- Navigation caret (downward ▼, sits above the current ply).
  -- Standalone Graphic whose only purpose is to host a cursor
  -- state the GraphicContext reads. Slots use this exclusively;
  -- M1 swaps to noCaret when its bias readout is focused (sub
  -- caret takes over with ▶ at the readout), so navigation ▼
  -- and editing ▶ are mutually exclusive like in the standard
  -- chain edit view.
  self.navCaret = app.Graphic(0, 0, 1, 1)
  self.navCaret:setCursorOrientation(0)  -- 0 = cursorDown
  self.navCaret:setCursorPosition(plyX(1) + ply // 2, 64)

  -- "No caret" placeholder controller. setCursorShow(false)
  -- suppresses the caret drawing in GraphicContext so swapping
  -- the main controller to this hides ▼ without affecting the
  -- sub controller (which keeps showing ▶ at the focused
  -- readout).
  self.noCaret = app.Graphic(0, 0, 1, 1)
  self.noCaret:setCursorShow(false)

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
    -- Bipolar -1..+1 weight range: +1 = full scene A, -1 = full
    -- scene B (matching ParamSetMorph.process's CV->weight remap).
    -- Bias starts at 0 (midpoint) so a freshly-entered Performance
    -- view sits at 50/50 unless the user has wired a CV that
    -- pulls the value to an endpoint.
    self._biasMap = app.LinearDialMap(-1, 1)
    self._biasMap:setSteps(0.5, 0.1, 0.01, 0.001)
    self.cvFader:setParameter(self._biasParam)
    self.cvFader:setMap(self._biasMap)
    self.cvFader:setUnits(app.unitNone)
    self.cvFader:setPrecision(2)
    -- Adaptive labels at the bias-range extremes: "A" replaces the
    -- numeric readout when bias is essentially +1, "B" when
    -- essentially -1. Same prior art Plaits/Canals/Rings use for
    -- their model-select faders. Threshold sits just inside the
    -- limit so the user gets the letter at the actual endpoint
    -- rather than having to overshoot.
    self.cvFader:setTextAbove(0.999, "A")
    self.cvFader:setTextBelow(-0.999, "B")
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
    self.m1Bias:setMap(self._biasMap)
    self.m1Bias:setUnits(app.unitNone)
    self.m1Bias:setPrecision(2)
    -- Same adaptive A/B label as the main-display cvFader.
    self.m1Bias:setTextAbove(0.999, "A")
    self.m1Bias:setTextBelow(-0.999, "B")
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
    self.m1S2 = app.SubButton("gain", 2)
    self.m1S3 = app.SubButton("bias", 3)
    self.m1SubGroup:addChild(self.m1S2)
    self.m1SubGroup:addChild(self.m1S3)

    self.m1GainEncoderState = Encoder.Coarse
    self.encoderState       = Encoder.Coarse
    -- Start unfocused. The user explicitly focuses a readout
    -- by pressing S2 (gain) or S3 (bias); UP unfocuses again.
    -- Until then, the encoder navigates between M1..M6 and the
    -- sub caret is hidden.
    self.m1FocusedReadout   = nil

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
  -- Live morpher weight ([-1, +1], post-CV) drives each slot's
  -- bias-fill indicator. Pull once and hand the Parameter to
  -- every slot so they all read the same source each frame.
  local weightParam = nil
  if self.chain and self.chain.getSceneMorph then
    local morph = self.chain:getSceneMorph()
    if morph then weightParam = morph:getParameter("Weight") end
  end
  for col = 2, 6 do
    self.slots[col] = SlotControl { window = self, column = col }
    if weightParam then self.slots[col]:setBiasSource(weightParam) end
  end

  -- Floating "+" placeholder: sits at the first un-populated ply
  -- (column 2 + sceneCount, scrolled into the visible range).
  -- Hidden when scenes fill the right edge or sceneCount has hit
  -- the per-chain limit. Glyph is two crossed lines (the original
  -- hold-mode look) rather than a text "+" so it reads as a
  -- proper button affordance at the panel resolution.
  self.plusGlyph = app.Drawing(0, 0, 9, 9)
  self.plusGlyph:add(Drawings.Control.Plus)
  self:addMainGraphic(self.plusGlyph)

  -- Cursor outline: 1-px border tracking the currently selected
  -- ply. Rendered over the slot panels so the user sees which
  -- column M-key would target.
  -- Selection-outline rectangle: 1px white border around the ply
  -- of the currently-focused control. Only relevant for M1 (the
  -- only ply with a focusable control); slot plies never show
  -- this since they have nothing to "edit." Hidden by default
  -- and shown / repositioned in _refresh whenever M1 has a
  -- focused readout.
  self.cursorBox = app.Graphic(0, kSlotY, ply, kSlotHeight)
  self.cursorBox:setBorder(kCursorOutline)
  self.cursorBox:setBorderColor(app.WHITE)
  self.cursorBox:hide()
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
  -- per refresh: chip text per slot's current A/B role plus
  -- "edit" on S3; under shift the labels swap to "" / "rename" /
  -- "delete" (the shifted bindings).
  self.slotS1 = app.SubButton("", 1)
  self.slotS2 = app.SubButton("", 2)
  self.slotS3 = app.SubButton("", 3)
  self.slotSubGroup:addChild(self.slotS1)
  self.slotSubGroup:addChild(self.slotS2)
  self.slotSubGroup:addChild(self.slotS3)
  -- Shift state, per-ply (habitat decision 7: shift mode persists
  -- across cursor leave/return within a session, but each
  -- control has its own mode). For Performance, "control" = ply,
  -- so we store one boolean per cursorCol. Moving the cursor
  -- shows the destination ply's stored mode; toggling shift only
  -- affects the current ply.
  --
  -- `shiftHeld` is the panel-key state (used only to distinguish
  -- tap from encoder-touched-during-hold). `shiftUsed` flags an
  -- encoder turn during the hold so the toggle is suppressed
  -- (habitat decision 1B).
  self.shiftHeld = false
  self.shiftUsed = false
  self.shiftModeByCol = {false, false, false, false, false, false}

  -- Main encoder cursor starts on the M1 bias fader so the
  -- bouncing caret is visible from the moment the user lands in
  -- Performance.
  self:setMainCursorController(self.cvFader)

  self:_refresh()
end

-- Translate a visible column (2..6) to the backing-store scene
-- index it currently maps to under the active scrollOffset.
-- Col 1 is M1 (no scene); returns 0 for that to surface a "no
-- scene" sentinel without crashing on getScene(0).
function Performance:_sceneIdxForCol(col)
  if col < 2 then return 0 end
  return col - 1 + self.scrollOffset
end

-- Largest scrollOffset that still keeps at least one slot or
-- the "+" placeholder visible at the right edge.
-- visible cols [2..6] cover sceneIdx [scrollOffset+1, scrollOffset+5].
-- "+" placeholder lives at conceptual sceneIdx (sceneCount+1).
function Performance:_maxScrollOffset()
  local n = self.sceneView:getSceneCount()
  local hasPlus = (n < self.sceneView:getMaxScenes())
  local lastIdx = n + (hasPlus and 1 or 0)
  local maxOff = lastIdx - 5
  if maxOff < 0 then maxOff = 0 end
  return maxOff
end

-- Visible column where the "+" placeholder appears, or nil
-- when scenes fill the right edge or scrollOffset has paged
-- past the "+".
function Performance:_plusCol()
  local n = self.sceneView:getSceneCount()
  if n >= self.sceneView:getMaxScenes() then return nil end
  local col = (n + 1) - self.scrollOffset + 1
  if col < 2 or col > 6 then return nil end
  return col
end

-- Repaint everything from current state.
function Performance:_refresh()
  local sceneCount = self.sceneView:getSceneCount()

  -- M1 fader is bound directly to the GainBias bias parameter;
  -- nothing to refresh here -- the fader re-reads target() each
  -- frame from its own draw path.

  -- M2..M6 slots. SlotControl handles name + A/B chip + delta
  -- count rendering; we just hand it the scene + crossfader role.
  -- scrollOffset shifts which slice of the scene list is visible.
  local a = self.sceneView:getCrossfaderA()
  local b = self.sceneView:getCrossfaderB()
  for col = 2, 6 do
    local sceneIdx = self:_sceneIdxForCol(col)
    local scene = self.sceneView:getScene(sceneIdx)
    local role
    if scene then
      if a == sceneIdx then role = "A"
      elseif b == sceneIdx then role = "B" end
    end
    self.slots[col]:setScene(scene, role)
  end

  -- "+" placeholder position and visibility. Anchored to the
  -- TextPanel's 43-stride center (same alignment fix the chip
  -- + bias indicator got in .19) so the glyph stays visually
  -- centered on the ply across all columns.
  local plusCol = self:_plusCol()
  if plusCol then
    local panelCenterX = (plusCol - 1) * 43 + 20
    self.plusGlyph:setCenter(panelCenterX, kSlotY + kSlotHeight / 2)
    self.plusGlyph:show()
  else
    self.plusGlyph:hide()
  end

  -- Selection box: only when an M1 sub-readout is focused.
  -- Slot navigation is conveyed by the ▼ caret alone -- the
  -- white border would falsely suggest the slot itself is in
  -- an editable state.
  if self.cursorCol == 1 and self.m1FocusedReadout then
    self.cursorBox:setPosition(plyX(1), kSlotY)
    self.cursorBox:show()
  else
    self.cursorBox:hide()
  end

  -- Navigation caret position: above the current ply, centered.
  self.navCaret:setCursorPosition(plyX(self.cursorCol) + ply // 2, 64)

  -- Caret protocol: ▼ above for "this ply is selected by nav",
  -- ▶ at the focused control for "actively editing." Mutually
  -- exclusive (only one of the two carets renders at a time):
  -- on M1 with bias focused, navigation ▼ disappears and editing
  -- ▶ appears at the bias readout. On slots the navigation ▼
  -- always shows since slot plies have no top-level control to
  -- focus into.
  if self.cursorCol == 1 and self.m1FocusedReadout then
    -- Editing M1: ▶ on the main display at the fader (the fader
    -- maintains its own cursorRight mCursorState at left of the
    -- bias value), and ▶ on the sub display at the focused
    -- readout. Matches the standard GainBias unit-control
    -- protocol where focusing the readout shows the bouncing
    -- caret on both displays simultaneously.
    self:setMainCursorController(self.cvFader)
    self:setSubCursorController(self.m1FocusedReadout)
  else
    -- Navigation only: ▼ above the current ply, no sub caret.
    self:setMainCursorController(self.navCaret)
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
    -- the slot context labels. Shift swaps S2/S3 labels to
    -- "set gain"/"set bias" (decimal-keyboard entry).
    if self.m1SubGroup then self.m1SubGroup:show() end
    if self.slotSubGroup then self.slotSubGroup:hide() end
    -- M1 SubButton labels stay "gain" / "bias" regardless of
    -- shift mode -- they name the readout the button focuses,
    -- and that semantic is the same whether the user is in
    -- shift-mode (where a tap opens the numeric keyboard) or
    -- not (where a tap focuses the readout for encoder edit,
    -- and a second tap opens the keyboard). This matches stock
    -- GainBias unit-control labeling.
    if self.m1S2 then self.m1S2:setText("gain") end
    if self.m1S3 then self.m1S3:setText("bias") end
    return
  end

  -- M2..M6: scene context labels. Hide M1 sub display.
  if self.m1SubGroup then self.m1SubGroup:hide() end
  if self.slotSubGroup then self.slotSubGroup:show() end

  local sceneIdx = self:_sceneIdxForCol(col)
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
    if self.shiftModeByCol[col] then
      -- Shifted bindings: S1 = duplicate, S2 = rename, S3 = delete.
      self.slotS1:setText("copy")
      self.slotS2:setText("rename")
      self.slotS3:setText("delete")
    else
      -- Unshifted: S1 toggle A, S2 toggle B, S3 edit.
      -- "*" prefix means the slot already holds that endpoint
      -- and a press unassigns; otherwise the label reads as the
      -- pending action.
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
    end
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

-- Focus one of the M1 readouts so the encoder writes to it.
-- Routes through _refresh so the main caret (▼ nav <-> ▶ at the
-- fader bias), the sub caret (none <-> ▶ at the readout), and
-- the selection border around the M1 ply all flip in lockstep
-- with the focus state. The previous implementation updated
-- only the sub controller; the main caret stayed as ▼ above the
-- ply even after focus, conflating selection and navigation.
-- See docs/planning/cursor-selection-conventions.md.
function Performance:_setM1FocusedReadout(readout)
  if readout then readout:save() end
  self.m1FocusedReadout = readout
  self:_refresh()
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

-- Shift is a tap-toggle, not a held-preview, per the habitat
-- shift-handling convention (planning/shift-handling.md): the
-- canonical Pattern A uses tap-shift to flip the sub-display
-- between two modes. We track shiftUsed so an encoder turn
-- during the hold suppresses the toggle (Decision 1 B).
function Performance:shiftPressed()
  self.shiftHeld   = true
  self.shiftUsed   = false
  return true
end

function Performance:shiftReleased()
  if self.shiftHeld and not self.shiftUsed then
    -- Per-ply toggle (habitat decision 7 mirror). M1 is
    -- exempted: its labels and S-key actions don't change
    -- between modes, so toggling it would silently change
    -- behavior (S2/S3 going straight to keyboard instead of
    -- focus-then-keyboard) with no visual feedback. Only
    -- slot plies have a real second mode (rename/delete vs
    -- asgn A/B/edit), so only they participate.
    local col = self.cursorCol
    if col ~= 1 then
      self.shiftModeByCol[col] = not self.shiftModeByCol[col]
      self:_refreshSub()
    end
  end
  self.shiftHeld = false
  return true
end

-- Standard unit-control keybinds for the focused M1 readout.
-- zero -> snap to 0.0. cancel -> restore the value the readout
-- saved when focus last entered it. UP releases focus (the
-- deselect protocol that built-in faders follow: once focused
-- via S2/S3 the user can step back out without selecting a
-- different readout).
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

function Performance:upReleased(shifted)
  if shifted then return false end
  if self.cursorCol == 1 and self.m1FocusedReadout then
    self:_setM1FocusedReadout(nil)
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

-- The rightmost selectable ply within the visible viewport.
-- M1 always selectable; visible occupied slots up to col 6;
-- the visible "+" if present. Encoder uses this to decide
-- when to stop advancing the cursor (vs scrolling).
function Performance:_maxSelectableCol()
  local n = self.sceneView:getSceneCount()
  -- Rightmost occupied col in the current viewport: clamped to 6.
  -- (n - scrollOffset) is the count of scenes from scrollOffset+1
  -- onwards; +1 because col 2 holds the first visible scene.
  local lastOccupied = n - self.scrollOffset + 1
  if lastOccupied < 1 then lastOccupied = 1 end  -- M1 always selectable
  if lastOccupied > 6 then lastOccupied = 6 end
  local plusCol = self:_plusCol()
  if plusCol and plusCol > lastOccupied then
    return plusCol
  end
  return lastOccupied
end

-- ---------------------------------------------------------------------------
-- Input handlers
-- ---------------------------------------------------------------------------

function Performance:encoder(change, shifted)
  -- Habitat Decision 1 (B): any encoder touch during shift hold
  -- suppresses the tap-shift toggle, so a deliberate value nudge
  -- doesn't accidentally flip the sub-display mode.
  if self.shiftHeld then self.shiftUsed = true end
  -- Cursor on M1 + a readout focused: encoder drives that
  -- readout. M1 with no focus falls through to the navigation
  -- path so the encoder still scrolls the cursor between
  -- M1..M6 -- focus is opt-in (S2/S3 focus, UP unfocuses).
  if self.cursorCol == 1 and self.m1FocusedReadout then
    local fine
    if self.m1FocusedReadout == self.m1Gain then
      fine = (self.m1GainEncoderState == Encoder.Fine)
    else
      fine = (self.encoderState == Encoder.Fine)
    end
    self.m1FocusedReadout:encoder(change, shifted, fine)
    return true
  end
  -- Cursor on a slot ply: encoder navigates between M-keys.
  -- At the right edge (col 6) with more scenes off-screen,
  -- advance scrollOffset instead of clamping. At the left edge
  -- of the slot viewport (col 2) with scrollOffset > 0, retreat
  -- the scroll before stepping cursor to M1; this means the
  -- only way back to M1 from a scrolled view is to first
  -- unscroll. Acceptable tradeoff: gives the user a direct
  -- way to page through 16 scenes via the encoder alone.
  self.encoderAccum = self.encoderAccum + change
  local moved = false
  while self.encoderAccum >= kEncoderThreshold do
    self.encoderAccum = self.encoderAccum - kEncoderThreshold
    local maxCol = self:_maxSelectableCol()
    if self.cursorCol < maxCol then
      self.cursorCol = self.cursorCol + 1
      moved = true
    elseif self.cursorCol == 6 and
           self.scrollOffset < self:_maxScrollOffset() then
      self.scrollOffset = self.scrollOffset + 1
      -- Reset shift state on visible slots when scrolling so a
      -- stale shifted toggle doesn't bleed onto a scene that
      -- just slid under the cursor's slot column.
      for c = 2, 6 do self.shiftModeByCol[c] = false end
      moved = true
    end
  end
  while self.encoderAccum <= -kEncoderThreshold do
    self.encoderAccum = self.encoderAccum + kEncoderThreshold
    if self.cursorCol == 2 and self.scrollOffset > 0 then
      self.scrollOffset = self.scrollOffset - 1
      for c = 2, 6 do self.shiftModeByCol[c] = false end
      moved = true
    elseif self.cursorCol > 1 then
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
      local sceneIdx = self:_sceneIdxForCol(i)
      local scene = self.sceneView:getScene(sceneIdx)
      if scene then return self:_confirmDelete(sceneIdx, scene) end
    end
    return true
  end
  local plusCol = self:_plusCol()
  if i == plusCol then
    -- Tap on the "+" placeholder: create a new scene + move
    -- cursor to it. Reset shift state on the just-occupied
    -- slot so the new scene starts on its default unshifted
    -- sub display (asgn A / asgn B / edit) rather than
    -- inheriting whatever toggle state the slot column had
    -- when it was previously empty.
    self.sceneView:addScene()
    self:_rebuildSceneMorph()
    if self.shiftModeByCol[i] ~= nil then
      self.shiftModeByCol[i] = false
    end
    -- New scene lives at the conceptual "+" position; keep
    -- the cursor on that visible column. If the "+" was at
    -- col 6 and there are now more scenes than visible cols,
    -- bump scrollOffset so the freshly-created scene stays
    -- visible (and the "+" advances to col 6 again if more
    -- scenes can still be added).
    self.cursorCol = i
    local maxScroll = self:_maxScrollOffset()
    if self.scrollOffset < maxScroll and i == 6 then
      self.scrollOffset = self.scrollOffset + 1
    end
    self:_refresh()
    return true
  end
  -- Tap on M1. Two states cycled by repeated taps:
  --   1. cursor elsewhere -> move cursor to M1 AND focus the
  --      bias readout in the same gesture (encoder is
  --      immediately writing the indicator the user just
  --      visually landed on). Matches the user-edit GainBias
  --      gesture where clicking a control's M key auto-grabs
  --      bias.
  --   2. cursor on M1 + focused -> unfocus (back to nav state).
  --      Tapping again from unfocused re-grabs bias.
  if i == 1 then
    if self.cursorCol ~= 1 then
      self.cursorCol = 1
      if self.m1Bias then self:_setM1FocusedReadout(self.m1Bias) end
    elseif self.m1FocusedReadout then
      self:_setM1FocusedReadout(nil)
    elseif self.m1Bias then
      self:_setM1FocusedReadout(self.m1Bias)
    end
    self:_refresh()
    return true
  end
  if self.sceneView:getScene(self:_sceneIdxForCol(i)) then
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
      -- Delete shifts subsequent slot indices down, so a freshly
      -- positioned slot at the deleted index inherits the deleted
      -- slot's column. Reset all slot shift modes to the default
      -- unshifted so the inherited column doesn't show stale
      -- rename/delete labels on the new occupant.
      for col = 2, 6 do self.shiftModeByCol[col] = false end
      -- Clamp scrollOffset: if delete reduced sceneCount enough
      -- that scrollOffset is past the new max, walk it back so
      -- the right edge of the viewport always shows content.
      local maxScroll = self:_maxScrollOffset()
      if self.scrollOffset > maxScroll then self.scrollOffset = maxScroll end
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
  -- "Shifted" for binding-selection purposes is the OR of the
  -- panel-key state (`shifted` arg) and the persistent tap-toggle
  -- (`shiftMode`). Both routes lead to the same shifted bindings
  -- so the user can use whichever feels natural.
  -- effShifted: OR the panel-key state with the persistent
  -- per-ply shift mode. M1 (cursorCol 1) is never put into
  -- shift mode by shiftReleased (see comment there), so its
  -- effShifted is purely the panel `shifted` arg. Slots can
  -- be in either via the toggle.
  local effShifted = shifted
  if self.cursorCol ~= 1 then
    effShifted = effShifted or self.shiftModeByCol[self.cursorCol]
  end
  local col = self.cursorCol
  if col == 1 then
    -- M1 = GainBias-style crossfader weight control.
    -- shifted: S2 / S3 -> decimal keyboard for direct gain / bias
    -- entry (like the OG GainBias unit control). S1 unused when
    -- shifted.
    if effShifted then
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
  local sceneIdx = self:_sceneIdxForCol(col)
  local scene = self.sceneView:getScene(sceneIdx)
  if scene == nil then return false end

  -- Shifted: S1 -> duplicate, S2 -> rename, S3 -> delete
  -- (parallels the sub-display SubButton labels in shiftMode).
  if effShifted then
    if i == 1 then return self:_duplicateScene(sceneIdx, scene) end
    if i == 2 then return self:_renameScene(sceneIdx, scene) end
    if i == 3 then return self:_confirmDelete(sceneIdx, scene) end
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

-- Duplicate the source scene to a fresh slot at the end of the
-- scene list. The copy carries the source's deltas verbatim but
-- starts unassigned to either crossfader endpoint -- the user
-- almost always wants to either keep working from the copy with
-- a different A/B assignment, or use it as a starting point for
-- further edits.
--
-- Naming: source name + " N" with the lowest N starting at 2
-- that doesn't collide with any existing scene name. Bails after
-- 99 to avoid an unbounded loop on pathological state.
function Performance:_duplicateScene(sceneIdx, scene)
  -- Make sure any live Parameter edits land in deltas before the
  -- copy reads from them. countDeltas does this as a side effect;
  -- explicit _syncDeltasFromParams keeps the intent obvious.
  if scene._syncDeltasFromParams then
    scene:_syncDeltasFromParams()
  end

  -- Find a non-colliding name.
  local srcName = scene:getName() or "scene"
  local nameInUse = {}
  for i = 1, self.sceneView:getSceneCount() do
    local s = self.sceneView:getScene(i)
    if s then nameInUse[s:getName()] = true end
  end
  local newName = srcName
  if nameInUse[srcName] then
    for n = 2, 99 do
      local candidate = string.format("%s %d", srcName, n)
      if not nameInUse[candidate] then
        newName = candidate
        break
      end
    end
  end

  local newScene, newIdx = self.sceneView:addScene(newName)
  if newScene == nil then return true end  -- max scenes reached, silent no-op

  -- Deep-copy deltas. Two nested tables: deltas[unitKey][ctrlId] = float.
  for unitKey, perUnit in pairs(scene.deltas) do
    for ctrlId, value in pairs(perUnit) do
      newScene:setDelta(unitKey, ctrlId, value)
    end
  end

  -- The new scene exists in the SceneView; the morpher's items
  -- need a rebuild only if the new scene happens to land at an
  -- A/B-assigned index (impossible here -- addScene appends, and
  -- the new index is fresh). Rebuild for safety anyway since
  -- _buildSceneMorphItems is cheap and idempotent and keeps the
  -- view consistent with any future logic that might depend on
  -- scene-count changes.
  self:_rebuildSceneMorph()

  -- Move cursor + scroll viewport so the new scene is in view.
  -- newIdx == sceneCount post-add. Visible col for newIdx is
  -- newIdx - scrollOffset + 1. If that's > 6, advance scroll
  -- until it fits at col 6.
  local newCol = newIdx - self.scrollOffset + 1
  while newCol > 6 and self.scrollOffset < self:_maxScrollOffset() do
    self.scrollOffset = self.scrollOffset + 1
    newCol = newIdx - self.scrollOffset + 1
  end
  -- Reset shift toggles on visible cols: the user just left the
  -- source scene in shifted mode (that's how they got to "copy"),
  -- and we don't want the new scene's slot showing rename/delete
  -- labels by inheritance.
  for c = 2, 6 do self.shiftModeByCol[c] = false end
  self.cursorCol = newCol
  self:_refresh()
  return true
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

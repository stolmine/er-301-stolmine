-- ER-301 stolmine L2 cell editor modal.
--
-- Forked from the Keyboard.Decimal pattern: six tap-to-focus slots
-- laid out across the main display, each aligned to an M-key. Encoder
-- rotates the focused slot's value; sub display shows live preview +
-- NL gloss. ENTER commits via seq:setL2 and closes; shift+ENTER
-- commits + advances focusHead + reloads the next row's state (Habitat-
-- fluid sweep). CANCEL/UP/HOME close without commit. shift+HOME resets
-- the modal to the starter "%2 : +1 host".
--
-- Slot order (left to right): predColA, predOp, predOperand,
--                             actTarget, actOp, actOperand.
-- "Ops between constants" so each side reads naturally like A=3.5
-- and B+1.

local app = app
local Class = require "Base.Class"
local Window = require "Base.Window"
local Env = require "Env"

local CellEditor = Class {}
CellEditor:include(Window)

-- ---------------------------------------------------------------------------
-- Engine enum mirrors (must match od/sequencer/Sequencer.h)
-- ---------------------------------------------------------------------------

local PRED_NONE        = 0
local PRED_MODULO      = 1
local PRED_EQ          = 2
local PRED_GT          = 3
local PRED_LT          = 4
local PRED_PROBABILITY = 5
local PRED_APPROX      = 6
local PRED_FIRE        = 7   -- ! : slot-level (any-gate OR)
local PRED_CHANGED     = 8
-- PRED_STEP_RANGE (9) deferred (needs operand2).
local PRED_FIRE1       = 10  -- !1 : gate1 edge this tick
local PRED_FIRE2       = 11  -- !2 : gate2 edge this tick

local ACTION_NONE        = 0
local ACTION_ADD         = 1
local ACTION_SUB         = 2
local ACTION_SET         = 3
local ACTION_MUL         = 4
local ACTION_DIV         = 5
local ACTION_FIRE        = 6   -- ! : v0.1 alias for ACTION_FIRE1 (hits gate1)
local ACTION_RAND        = 7
local ACTION_MUTE        = 8
local ACTION_JUMP_THIS   = 9
local ACTION_JUMP_GLOBAL = 10
local ACTION_JUMP_SELF   = 11
local ACTION_FIRE1       = 12  -- !1 : retrigger gate1 (explicit)
local ACTION_FIRE2       = 13  -- !2 : retrigger gate2

-- Cyclic option lists for the choice slots. PRED_FIRE / FIRE1 / FIRE2
-- all surface separately so the user can author slot-level "any gate"
-- detection alongside per-gate detection. On the action side, the
-- bare ACTION_FIRE is omitted from the cycle (functionally identical
-- to ACTION_FIRE1); v0.1 quicksaves with ACTION_FIRE still render
-- as "!" and execute correctly, but new authoring lands on FIRE1/2.
local kPredOpList = {
  PRED_MODULO, PRED_EQ, PRED_GT, PRED_LT,
  PRED_PROBABILITY, PRED_APPROX,
  PRED_FIRE, PRED_FIRE1, PRED_FIRE2,
  PRED_CHANGED,
}
local kActOpList = {
  ACTION_ADD, ACTION_SUB, ACTION_SET, ACTION_MUL, ACTION_DIV,
  ACTION_FIRE1, ACTION_FIRE2,
  ACTION_RAND, ACTION_MUTE,
  ACTION_JUMP_THIS, ACTION_JUMP_GLOBAL, ACTION_JUMP_SELF,
}

-- Symbol per op, mirroring the grid-view L2 cell formatter.
local kPredSymbol = {
  [PRED_MODULO]      = "%",
  [PRED_EQ]          = "=",
  [PRED_GT]          = ">",
  [PRED_LT]          = "<",
  [PRED_PROBABILITY] = "?",
  [PRED_APPROX]      = "~",
  [PRED_FIRE]        = "!",
  [PRED_FIRE1]       = "!1",
  [PRED_FIRE2]       = "!2",
  [PRED_CHANGED]     = "c",
}
local kActSymbol = {
  [ACTION_ADD]         = "+",
  [ACTION_SUB]         = "-",
  [ACTION_SET]         = "=",
  [ACTION_MUL]         = "*",
  [ACTION_DIV]         = "/",
  [ACTION_FIRE]        = "!",   -- legacy v0.1 render (engine == gate1)
  [ACTION_FIRE1]       = "!1",
  [ACTION_FIRE2]       = "!2",
  [ACTION_RAND]        = "?",
  [ACTION_MUTE]        = "M",
  [ACTION_JUMP_THIS]   = "j",
  [ACTION_JUMP_GLOBAL] = "J",
  [ACTION_JUMP_SELF]   = ".",
}

local kColLetters = { "A", "B", "C", "D", "E", "F" }

-- ---------------------------------------------------------------------------
-- Slot-relevance rules
-- ---------------------------------------------------------------------------

-- Returns true when the M1 (predColA) slot should render "-" and skip
-- focus. Modulo / probability ignore colA (slot-level / not used);
-- the gate-fire detectors (FIRE / FIRE1 / FIRE2) are slot-level and
-- don't inspect a column either.
local function predColASkipped(predOp)
  return predOp == PRED_MODULO
      or predOp == PRED_PROBABILITY
      or predOp == PRED_FIRE
      or predOp == PRED_FIRE1
      or predOp == PRED_FIRE2
end

-- Returns true when the M3 (predOperand) slot should render "-".
local function predOperandSkipped(predOp)
  return predOp == PRED_FIRE
      or predOp == PRED_FIRE1
      or predOp == PRED_FIRE2
      or predOp == PRED_CHANGED
end

-- M4 (action target) is forced for the jump family (jumps target a
-- fixed scope: self / global) and the gate-fire actions (slot-level).
local function actTargetSkipped(actOp)
  return actOp == ACTION_FIRE
      or actOp == ACTION_FIRE1
      or actOp == ACTION_FIRE2
      or actOp == ACTION_JUMP_THIS
      or actOp == ACTION_JUMP_GLOBAL
      or actOp == ACTION_JUMP_SELF
end

-- M6 (action operand) skips for ops that act on the target without
-- a numeric operand: FIRE retriggers gate (1 / 2), RAND draws
-- randomly, MUTE zeroes the target cell.
local function actOperandSkipped(actOp)
  return actOp == ACTION_FIRE
      or actOp == ACTION_FIRE1
      or actOp == ACTION_FIRE2
      or actOp == ACTION_RAND
      or actOp == ACTION_MUTE
end

-- ---------------------------------------------------------------------------
-- Operand encoder pacing per op (fine / coarse / super variants)
-- ---------------------------------------------------------------------------

-- Returns step + clamp range for the focused operand slot, based on
-- which op is currently selected on the same side (pred or action)
-- and the current stepMode (fine / coarse). `super` = shift held.
local function predOperandStep(predOp, stepMode, super)
  if predOp == PRED_MODULO then
    if stepMode == "coarse" then return super and 16 or 4 end
    return super and 1 or 1                 -- integers; no sub-1 super
  elseif predOp == PRED_PROBABILITY then
    if stepMode == "coarse" then return super and 25 or 10 end
    return super and 1 or 1
  end
  -- value comparators: float CV-style
  if stepMode == "coarse" then return super and 10.0 or 1.0 end
  return super and 0.01 or 0.1
end

local function predOperandClamp(predOp, v)
  if predOp == PRED_MODULO then
    if v < 1 then return 1 end
    if v > 64 then return 64 end
    return math.floor(v + 0.5)
  elseif predOp == PRED_PROBABILITY then
    if v < 0 then return 0 end
    if v > 100 then return 100 end
    return math.floor(v + 0.5)
  end
  if v < -64.0 then return -64.0 end
  if v > 64.0 then return 64.0 end
  return v
end

local function actOperandStep(actOp, stepMode, super)
  if actOp == ACTION_JUMP_THIS
     or actOp == ACTION_JUMP_GLOBAL
     or actOp == ACTION_JUMP_SELF then
    if stepMode == "coarse" then return super and 32 or 8 end
    return super and 1 or 1
  end
  if stepMode == "coarse" then return super and 10.0 or 1.0 end
  return super and 0.01 or 0.1
end

local function actOperandClamp(actOp, v)
  if actOp == ACTION_JUMP_THIS
     or actOp == ACTION_JUMP_GLOBAL
     or actOp == ACTION_JUMP_SELF then
    if v < 0 then return 0 end
    if v > 63 then return 63 end
    return math.floor(v + 0.5)
  end
  if v < -64.0 then return -64.0 end
  if v > 64.0 then return 64.0 end
  return v
end

-- ---------------------------------------------------------------------------
-- NL templates (kept short to fit ~21 chars at font 10 in a sub ply)
-- ---------------------------------------------------------------------------

-- Tight templates: drop "when", "step", "row" so each side fits well
-- inside a sub ply (~21 chars at font 10). The column identifier
-- already carries pin info as "E52" vs "E" (see colName), and the
-- IF / THEN prefixes added at render time supply the conditional
-- structure. Examples:
--   PRED_CHANGED on E52 -> "IF E52 change"
--   ACTION_ADD on B07   -> "THEN B07 += 1"
local kPredTpl = {
  [PRED_MODULO]      = "every %s passes",
  [PRED_EQ]          = "%s = %s",
  [PRED_GT]          = "%s > %s",
  [PRED_LT]          = "%s < %s",
  [PRED_PROBABILITY] = "%s%% chance",
  [PRED_APPROX]      = "%s near %s",
  [PRED_FIRE]        = "any gate fires",
  [PRED_FIRE1]       = "gate1 fires",
  [PRED_FIRE2]       = "gate2 fires",
  [PRED_CHANGED]     = "%s change",
}
local kActTpl = {
  [ACTION_ADD]         = "%s += %s",
  [ACTION_SUB]         = "%s -= %s",
  [ACTION_SET]         = "%s = %s",
  [ACTION_MUL]         = "%s *= %s",
  [ACTION_DIV]         = "%s /= %s",
  [ACTION_FIRE]        = "retrigger gate1",  -- legacy alias (= ACTION_FIRE1)
  [ACTION_FIRE1]       = "retrigger gate1",
  [ACTION_FIRE2]       = "retrigger gate2",
  [ACTION_RAND]        = "randomize %s",
  [ACTION_MUTE]        = "mute %s",
  [ACTION_JUMP_THIS]   = "host -> %s",
  [ACTION_JUMP_GLOBAL] = "all -> %s",
  [ACTION_JUMP_SELF]   = "self -> %s",
}

local function colName(c, hostCol, row)
  local base
  if c < 0 then
    if hostCol == nil then base = "host"
    else base = kColLetters[hostCol + 1] or "?" end
  else
    base = kColLetters[c + 1] or "?"
  end
  -- Cell-pinned form is the short "E52" used in the compact preview,
  -- matched in the NL gloss so the user sees the same identifier in
  -- both lines (no "row" prefix bloating S2 / S3).
  if row and row >= 0 then
    return string.format("%s%02d", base, row)
  end
  return base
end

local function fmtNum(v)
  if v == math.floor(v) then return tostring(math.floor(v)) end
  return string.format("%.2f", v)
end

local function nlPredicate(values, hostCol)
  local tpl = kPredTpl[values.predOp]
  if not tpl then return "" end
  local col = colName(values.predColA, hostCol, values.predColARow)
  local val = fmtNum(values.predVal)
  -- Templates use one or two %s slots. string.format handles either.
  local _, n = tpl:gsub("%%s", "")
  if n == 0 then return tpl end
  if n == 1 then
    if values.predOp == PRED_MODULO
       or values.predOp == PRED_PROBABILITY then
      return string.format(tpl, val)
    end
    return string.format(tpl, col)
  end
  return string.format(tpl, col, val)
end

local function nlAction(values, hostCol)
  local tpl = kActTpl[values.actOp]
  if not tpl then return "" end
  local tgt = colName(values.actTarget, hostCol, values.actTargetRow)
  local val = fmtNum(values.actVal)
  local _, n = tpl:gsub("%%s", "")
  if n == 0 then return tpl end
  if n == 1 then
    -- Single-%s templates use either the value (for jumps and other
    -- value-bearing actions) or the target column (for unary ops on
    -- a target like rand / mute).
    if values.actOp == ACTION_JUMP_THIS
       or values.actOp == ACTION_JUMP_GLOBAL
       or values.actOp == ACTION_JUMP_SELF then
      return string.format(tpl, val)
    end
    return string.format(tpl, tgt)
  end
  -- 2-%s templates are all "<target> step <op> <value>" form, so the
  -- target precedes the value in the format args.
  return string.format(tpl, tgt, val)
end

-- Column ref text for the compact preview: host (-1) resolves to the
-- host column's letter so the preview reads identically to the main
-- slot and the sub NL gloss (no "h" marker anywhere). Row pin appends
-- as 2 digits when set.
local function compactColRef(col, row, hostCol)
  local resolved = (col < 0) and (hostCol or 0) or col
  local s = kColLetters[resolved + 1] or "?"
  if row and row >= 0 then
    s = s .. string.format("%02d", row)
  end
  return s
end

-- Compact "pred:action" rendering for the live preview on S1.
-- Mirrors the format used by GridView's L2 cell render so the user
-- sees exactly what the cell will look like in the grid. The row
-- pin (when set) is appended to the column letter so e.g. PRED_EQ
-- on A pinned to row 15 renders as "A15=3.5". hostCol resolves the
-- host sentinel (col == -1) to the cell's own column letter.
local function compactPreview(values, hostCol)
  local p = kPredSymbol[values.predOp] or "?"
  if not predColASkipped(values.predOp) then
    local ref = compactColRef(values.predColA, values.predColARow, hostCol)
    p = ref .. p
  end
  if not predOperandSkipped(values.predOp) then
    p = p .. fmtNum(values.predVal)
  end
  local a = kActSymbol[values.actOp] or "?"
  if not actTargetSkipped(values.actOp) then
    local ref = compactColRef(values.actTarget, values.actTargetRow, hostCol)
    a = ref .. a
  end
  if not actOperandSkipped(values.actOp) then
    a = a .. fmtNum(values.actVal)
  end
  return p .. ":" .. a
end

-- ---------------------------------------------------------------------------
-- Starter / defaults
-- ---------------------------------------------------------------------------

local kStarter = {
  predOp       = PRED_MODULO,
  predColA     = -1,             -- host
  predColARow  = -1,             -- "use colA's playhead" (default)
  predVal      = 2,
  actOp        = ACTION_ADD,
  actTarget    = -1,             -- host
  actTargetRow = -1,             -- "use target's playhead"
  actVal       = 1,
}

-- ---------------------------------------------------------------------------
-- Slot layout helpers
-- ---------------------------------------------------------------------------

-- Slot kinds: which slot index maps to which value field, and whether
-- it's a "choice" (cycles a fixed list at default encoder pacing) or
-- "number" (fine/coarse-paced numerical input).
-- Slot kinds:
--   cellref: a column-letter + optional row index. Encoder bare =
--            increment row; encoder + S3 held = cycle column; HOME =
--            clear row (back to "use playhead").
--   predOp / actOp: cycle their fixed op list.
--   number:  literal float operand for the comparator / arithmetic
--            op; fine / coarse / super stepping per op.
local kSlotKind = {
  [1] = { field = "predColA",  rowField = "predColARow",  kind = "cellref" },
  [2] = { field = "predOp",    kind = "predOp" },
  [3] = { field = "predVal",   kind = "number" },
  [4] = { field = "actTarget", rowField = "actTargetRow", kind = "cellref" },
  [5] = { field = "actOp",     kind = "actOp"  },
  [6] = { field = "actVal",    kind = "number" },
}

local function slotSkipped(slotIdx, values)
  if slotIdx == 1 then return predColASkipped(values.predOp) end
  if slotIdx == 3 then return predOperandSkipped(values.predOp) end
  if slotIdx == 4 then return actTargetSkipped(values.actOp) end
  if slotIdx == 6 then return actOperandSkipped(values.actOp) end
  return false
end

local function slotRenderText(slotIdx, values, hostCol)
  if slotSkipped(slotIdx, values) then return "-" end
  local cfg = kSlotKind[slotIdx]
  local v = values[cfg.field]
  if cfg.kind == "cellref" then
    -- Host (-1) resolves to the host column's letter so the slot
    -- reads the same as the sub NL gloss and the compact preview
    -- ("A" everywhere when this cell lives on cv1). Row pin appends
    -- as 2 digits.
    local resolved = (v < 0) and (hostCol or 0) or v
    local colChar = kColLetters[resolved + 1] or "?"
    local r = values[cfg.rowField]
    if r and r >= 0 then
      return string.format("%s%02d", colChar, r)
    end
    return colChar
  elseif cfg.kind == "predOp" then
    return kPredSymbol[v] or "?"
  elseif cfg.kind == "actOp" then
    return kActSymbol[v] or "?"
  elseif cfg.kind == "number" then
    return fmtNum(v)
  end
  return "?"
end

-- Slot pixel layout. Each slot is centered on its M-key button
-- center (app.getButtonCenter(i) = (i-1)*43+20) and 40 px wide.
-- That puts slot 1 at x=0..40 and slot 6 at x=215..255, fitting
-- the 256-px main display exactly.
local kSlotWidth  = 40
local kSlotHeight = 52
local kSlotY      = 6
local function slotX(i) return (i - 1) * 43 end
local function slotCenterX(i) return slotX(i) + kSlotWidth / 2 end

-- ---------------------------------------------------------------------------
-- Modal class
-- ---------------------------------------------------------------------------

function CellEditor:init(slotIdx, col, row)
  Window.init(self)
  self:setClassName("Sequencer.CellEditor")
  self.suppressQuickSave = true

  self.slot = slotIdx or 0
  self.col  = col or 0
  self.row  = row or 0

  self:_loadState()
  self.focused  = 2          -- start on predOp; dominant choice slot
  self.stepMode = "fine"

  -- Main display: six slot boxes + labels.
  self.slotBoxes  = {}
  self.slotLabels = {}
  for i = 1, 6 do
    local box = app.Graphic(slotX(i), kSlotY, kSlotWidth, kSlotHeight)
    box:setBorder(1)
    box:setBorderColor(app.GRAY7)
    self:addMainGraphic(box)
    self.slotBoxes[i] = box

    local lbl = app.Label("", 12)
    lbl:setJustification(app.justifyCenter)
    lbl:setCenter(slotCenterX(i), kSlotY + kSlotHeight / 2)
    self:addMainGraphic(lbl)
    self.slotLabels[i] = lbl
  end

  -- Sub display: live preview (S1) + IF / THEN NL glosses (S2 / S3).
  -- All three labels lay across the top of the sub display so the
  -- user reads them like a three-column status bar.
  self.previewLabel = app.Label("", 12)
  self.previewLabel:setPosition(2, app.GRID4_LINE1)
  self.previewLabel:setJustification(app.justifyLeft)
  self:addSubGraphic(self.previewLabel)

  self.ifLabel = app.Label("", 10)
  self.ifLabel:setPosition(2, app.GRID4_LINE3)
  self.ifLabel:setJustification(app.justifyLeft)
  self:addSubGraphic(self.ifLabel)

  self.thenLabel = app.Label("", 10)
  self.thenLabel:setPosition(2, app.GRID4_LINE4)
  self.thenLabel:setJustification(app.justifyLeft)
  self:addSubGraphic(self.thenLabel)

  -- Step-mode chip (FINE / COARSE) so the user can see which
  -- numerical pacing the next encoder turn will use. Only shown
  -- when the focused slot is a number kind.
  self.stepChip = app.Label("", 10)
  self.stepChip:setPosition(90, app.GRID4_LINE1)
  self.stepChip:setJustification(app.justifyLeft)
  self:addSubGraphic(self.stepChip)

  -- Persistent S3 hint -- the modal otherwise has no labelled
  -- softkeys, so the "hold S3 + encoder = cycle column letter on
  -- the focused cell-ref slot" gesture would be invisible to a new
  -- user. The chip stays put whether or not S3 is held; it just
  -- explains what S3 does.
  self.s3Hint = app.SubButton("col", 3)
  self:addSubGraphic(self.s3Hint)

  self.encoderAccum = 0
  self:_refresh()
end

-- Populate `self.values` from the engine if the cell is already
-- present, otherwise copy the starter table.
function CellEditor:_loadState()
  self.values = {}
  local seq = app.AudioThread.getSequencerTask()
  if seq and seq:l2Present(self.slot, self.col, self.row) then
    self.values.predOp       = seq:l2PredOp(self.slot, self.col, self.row)
    self.values.predColA     = seq:l2PredColA(self.slot, self.col, self.row)
    self.values.predColARow  = seq:l2PredColARow(self.slot, self.col, self.row)
    self.values.predVal      = seq:l2PredVal(self.slot, self.col, self.row)
    self.values.actOp        = seq:l2ActOp(self.slot, self.col, self.row)
    self.values.actTarget    = seq:l2ActTgt(self.slot, self.col, self.row)
    self.values.actTargetRow = seq:l2ActTgtRow(self.slot, self.col, self.row)
    self.values.actVal       = seq:l2ActVal(self.slot, self.col, self.row)
  else
    for k, v in pairs(kStarter) do self.values[k] = v end
  end
end

-- Snap focused slot back to a non-skipped one if the current focus is
-- now invalid (e.g. after an op change that skipped the focused field).
function CellEditor:_ensureFocusValid()
  if not slotSkipped(self.focused, self.values) then return end
  for offset = 1, 5 do
    local i = ((self.focused - 1 + offset) % 6) + 1
    if not slotSkipped(i, self.values) then
      self.focused = i
      return
    end
  end
end

-- Re-render all labels + borders + sub display from current state.
function CellEditor:_refresh()
  self:_ensureFocusValid()

  for i = 1, 6 do
    self.slotLabels[i]:setText(slotRenderText(i, self.values, self.col))
    if i == self.focused then
      self.slotBoxes[i]:setBorderColor(app.WHITE)
    elseif slotSkipped(i, self.values) then
      self.slotBoxes[i]:setBorderColor(app.GRAY3)
    else
      self.slotBoxes[i]:setBorderColor(app.GRAY7)
    end
  end

  self.previewLabel:setText(compactPreview(self.values, self.col))
  self.ifLabel:setText("IF " .. nlPredicate(self.values, self.col))
  self.thenLabel:setText("THEN " .. nlAction(self.values, self.col))

  local kind = kSlotKind[self.focused].kind
  if kind == "number" then
    self.stepChip:setText(self.stepMode == "coarse" and "COARSE" or "FINE")
  else
    self.stepChip:setText("")
  end

  -- "col" hint is only meaningful on cell-ref slots (M1 predColA,
  -- M4 actTarget) -- those are the only places where S3-held +
  -- encoder cycles the column letter. Blank the chip text on op /
  -- number slots so it doesn't mislead the user into thinking S3
  -- does something there. (Empty text is the convention here for a
  -- SubButton you want to render as nothing, see GridView.)
  self.s3Hint:setText(kind == "cellref" and "col" or "")
end

-- ---------------------------------------------------------------------------
-- Encoder dispatch
-- ---------------------------------------------------------------------------

local kThresholdChoice = Env.EncoderThreshold.SlidingList
local kThresholdNumber = Env.EncoderThreshold.Default

function CellEditor:_rotateChoice(dir)
  local f = self.focused
  local cfg = kSlotKind[f]
  if cfg.kind == "cellref" then
    -- Bare encoder on a cell-ref slot: increment the row pin. If the
    -- pin is currently -1 ("use playhead"), seed it on the first tick
    -- so the user can see immediate progress. HOME clears it back to
    -- -1. Column cycling is handled by S3-held branch in encoder().
    local r = self.values[cfg.rowField] or -1
    if r < 0 then
      r = (dir > 0) and 0 or 63
    else
      r = r + dir
      if r < 0 then r = 63 elseif r > 63 then r = 0 end
    end
    self.values[cfg.rowField] = r
  elseif cfg.kind == "predOp" then
    -- Find current index in kPredOpList.
    local current = self.values.predOp
    local idx = 1
    for i, op in ipairs(kPredOpList) do
      if op == current then idx = i; break end
    end
    idx = idx + dir
    if idx < 1 then idx = #kPredOpList elseif idx > #kPredOpList then idx = 1 end
    self.values.predOp = kPredOpList[idx]
  elseif cfg.kind == "actOp" then
    local current = self.values.actOp
    local idx = 1
    for i, op in ipairs(kActOpList) do
      if op == current then idx = i; break end
    end
    idx = idx + dir
    if idx < 1 then idx = #kActOpList elseif idx > #kActOpList then idx = 1 end
    self.values.actOp = kActOpList[idx]
  end
end

-- Column cycle on a cell-ref slot (M1 / M4) when S3 is held. Cycles
-- through -1 (host) and 0..5 (columns A..F).
function CellEditor:_rotateCellRefColumn(dir)
  local cfg = kSlotKind[self.focused]
  if cfg.kind ~= "cellref" then return end
  local v = self.values[cfg.field] + dir
  if v < -1 then v = 5 elseif v > 5 then v = -1 end
  self.values[cfg.field] = v
end

function CellEditor:_rotateNumber(dir, super)
  local f = self.focused
  if f == 3 then
    local step = predOperandStep(self.values.predOp, self.stepMode, super)
    self.values.predVal = predOperandClamp(self.values.predOp,
                                           self.values.predVal + dir * step)
  elseif f == 6 then
    local step = actOperandStep(self.values.actOp, self.stepMode, super)
    self.values.actVal = actOperandClamp(self.values.actOp,
                                         self.values.actVal + dir * step)
  end
end

function CellEditor:encoder(change, shifted)
  local kind = kSlotKind[self.focused].kind
  local threshold = (kind == "number") and kThresholdNumber or kThresholdChoice

  self.encoderAccum = self.encoderAccum + change
  local moved = false

  local function step(dir)
    if kind == "number" then
      -- Shift on a number slot = super step. Otherwise fine/coarse
      -- per stepMode (dial-toggled).
      self:_rotateNumber(dir, shifted)
    elseif kind == "cellref" then
      -- Cell-ref slot: S3 held = cycle column letter; otherwise
      -- increment row pin. shift+encoder on cell-ref is a no-op.
      if shifted then return end
      if self.s3Held then
        self:_rotateCellRefColumn(dir)
      else
        self:_rotateChoice(dir)   -- cellref-row path; lives in _rotateChoice
      end
    elseif shifted then
      -- Shift on an op slot is intentionally a no-op (per user
      -- decision; super-step on choice slots isn't meaningful and we
      -- don't want it overloaded with slot-navigation either).
    else
      self:_rotateChoice(dir)
    end
  end

  while self.encoderAccum >= threshold do
    self.encoderAccum = self.encoderAccum - threshold
    step(1)
    moved = true
  end
  while self.encoderAccum <= -threshold do
    self.encoderAccum = self.encoderAccum + threshold
    step(-1)
    moved = true
  end

  if moved then self:_refresh() end
  return true
end

-- ---------------------------------------------------------------------------
-- Hard-button handlers
-- ---------------------------------------------------------------------------

-- S3 hold + encoder = cycle the column part of a focused cell-ref
-- slot (M1 / M4). Tracked as a flag so encoder() can branch on the
-- held state. Other sub buttons currently no-op inside the modal.
function CellEditor:subPressed(i, shifted)
  if i == 3 then
    self.s3Held = true
    return true
  end
  return false
end

function CellEditor:subReleased(i, shifted)
  if i == 3 then
    self.s3Held = false
    return true
  end
  return false
end

-- M1-M6 tap: focus that slot. Skipped slots silently refuse focus.
function CellEditor:mainReleased(i, shifted)
  if shifted then return false end
  if i < 1 or i > 6 then return false end
  if slotSkipped(i, self.values) then return true end
  self.focused = i
  self:_refresh()
  return true
end

-- Dial button toggles fine <-> coarse for numerical slots. On choice
-- slots it's a no-op (returns false so the firmware's global dial
-- behavior can run).
function CellEditor:dialPressed(shifted)
  local kind = kSlotKind[self.focused].kind
  if kind ~= "number" then return false end
  self.stepMode = (self.stepMode == "fine") and "coarse" or "fine"
  self:_refresh()
  return true
end

-- Write the current `values` to the engine.
function CellEditor:_commitToEngine()
  local seq = app.AudioThread.getSequencerTask()
  if not seq then return end
  seq:setL2(self.slot, self.col, self.row,
            self.values.predOp,
            self.values.predColA, self.values.predColARow,
            self.values.predVal,
            self.values.actOp,
            self.values.actTarget, self.values.actTargetRow,
            self.values.actVal)
end

-- ENTER: commit + close.
function CellEditor:enterReleased(shifted)
  if shifted then return false end
  self:_commitToEngine()
  self:hide()
  self:emitSignal("done", self.values)
  return true
end

-- shift+ENTER (dispatched as commitReleased per Application.lua):
-- commit + advance focusHead + reload state for new row + stay open.
-- The actual focusHead advance happens in GridView (which owns it);
-- we emit a signal asking the parent to bump the row, then it calls
-- :reloadForCell on us.
function CellEditor:commitReleased()
  self:_commitToEngine()
  self:emitSignal("commitAndAdvance")
  return true
end

-- Called by GridView after it advances focusHead. Re-targets us at
-- the new (col, row) and refreshes from the engine.
function CellEditor:reloadForCell(col, row)
  self.col = col
  self.row = row
  self:_loadState()
  self:_ensureFocusValid()
  self.encoderAccum = 0
  self:_refresh()
end

-- CANCEL: close without committing.
function CellEditor:cancelReleased(shifted)
  if shifted then return false end
  self:hide()
  self:emitSignal("done", nil)
  return true
end

-- UP: alias for CANCEL.
function CellEditor:upReleased(shifted)
  if shifted then return false end
  self:hide()
  self:emitSignal("done", nil)
  return true
end

-- HOME: when focused on a cell-ref slot, clears the row pin (back
-- to "use playhead"). Otherwise behaves like CANCEL -- closes without
-- committing. This is a deliberate departure from Keyboard.Decimal's
-- always-close HOME so cell-ref pins are easy to un-pin without
-- losing the rest of the edit.
function CellEditor:homeReleased()
  local cfg = kSlotKind[self.focused]
  if cfg and cfg.kind == "cellref" then
    self.values[cfg.rowField] = -1
    self:_refresh()
    return true
  end
  self:hide()
  self:emitSignal("done", nil)
  return true
end

-- shift+HOME (zeroReleased): reset all six slots to the starter
-- `%2 : +1 host`. Useful for "throw away what's here and start
-- fresh" without leaving the modal.
function CellEditor:zeroReleased()
  for k, v in pairs(kStarter) do self.values[k] = v end
  self.focused  = 2
  self.stepMode = "fine"
  self:_refresh()
  return true
end

return CellEditor

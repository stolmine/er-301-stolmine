-- Phase-2 dense unit picker. Replaces the Mondrian rectangle-per-
-- unit layout with a 2-column scrolling list. Row cursor highlights
-- both cells on the focused row; M1 picks the left cell, M4 picks
-- the right. See docs/planning/unit-picker-overhaul.md for the full
-- design rationale and layout math.
--
-- First-cut scope:
--   - 2 cols x 5 rows = 10 visible units (font 9, row pitch 9)
--   - Row cursor (encoder moves it)
--   - M1 / M4 pick
--   - ENTER aliases M1
--   - CANCEL / UP closes
--   - Sub display shows focused-unit info
--   - All units flat list, sorted by recents-then-alpha
--
-- Next iterations (separate commits) add:
--   - Alphabet ribbon at top
--   - M2 sort cycle, M3 type filter cycle
--   - M5 hidden visibility, M6 favorite toggle
--   - Section dividers for type/package/keyword sorts
--   - Sparkline + type glyph on each row

local app = app
local Class = require "Base.Class"
local Window = require "Base.Window"
local Env = require "Env"
local Factory = require "Unit.Factory"
local Glyph = require "Unit.Chooser.Glyph"
local Sparkline = require "Unit.Chooser.Sparkline"

local Dense = Class {}
Dense:include(Window)

-- ---------------------------------------------------------------------------
-- Layout constants (grounded in Sequencer/GridView.lua pixel math)
-- ---------------------------------------------------------------------------

local kFontMain      = 9
local kFontSub       = 10
local kFontTitle     = 12
local kRowHeight     = 9
local kVisibleRows   = 5
local kColLeftX      = 4         -- left column label X
local kColRightX     = 132       -- right column label X
local kCursorIndent  = 2         -- pad between row cursor and label
local kCursorHeight  = 10
local kColWidth      = 120       -- visual width per column cell

-- Y baselines (bottom-up). Five rows, top to bottom visually.
local kRowYs = { 44, 35, 26, 17, 8 }

local kEncoderThreshold = Env.EncoderThreshold.Default

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

function Dense:init(ring)
  Window.init(self)
  self:setClassName("Unit.Chooser.Dense")
  self.ring = ring

  -- Cursor state.
  self.units       = {}         -- filtered + sorted loadInfo list
  self.cursorRow   = 0
  self.viewTop     = 0
  self.encoderAccum = 0

  -- Row label widgets (left col + right col, one per visible row).
  self.leftLabels  = {}
  self.rightLabels = {}
  for r = 1, kVisibleRows do
    local lblL = app.Label("", kFontMain)
    lblL:setJustification(app.justifyLeft)
    lblL:setPosition(kColLeftX, kRowYs[r])
    self:addMainGraphic(lblL)
    self.leftLabels[r] = lblL

    local lblR = app.Label("", kFontMain)
    lblR:setJustification(app.justifyLeft)
    lblR:setPosition(kColRightX, kRowYs[r])
    self:addMainGraphic(lblR)
    self.rightLabels[r] = lblR
  end

  -- Row-cursor box: a 1-px border around BOTH cells of the focused
  -- row (full 256 px wide). Drawn behind labels so labels still read
  -- clearly. Positioned per refresh based on cursorRow vs viewTop.
  self.cursorBox = app.Graphic(0, 0, 256, kCursorHeight)
  self.cursorBox:setBorder(1)
  self.cursorBox:setBorderColor(app.GRAY7)
  self:addMainGraphic(self.cursorBox)

  -- Vertical hairline between the two columns. Drawn as a 1-px
  -- DrawingInstructions vline since it's static. The color call is
  -- separate from the geometry call (matches GridView usage).
  self.divider = app.Drawing(0, 0, 256, 64)
  local instr  = app.DrawingInstructions()
  instr:color(app.GRAY3)
  instr:vline(128, 4, 50)
  self.divider:add(instr)
  self:addMainGraphic(self.divider)

  -- Sub display: focused-unit info.
  self.subTitle = app.Label("", kFontTitle)
  self.subTitle:setPosition(2, app.GRID4_LINE1)
  self.subTitle:setJustification(app.justifyLeft)
  self:addSubGraphic(self.subTitle)

  self.subLib = app.Label("", kFontSub)
  self.subLib:setPosition(2, app.GRID4_LINE2)
  self.subLib:setJustification(app.justifyLeft)
  self:addSubGraphic(self.subLib)

  self.subInfo = app.Label("", kFontSub)
  self.subInfo:setPosition(2, app.GRID4_LINE3)
  self.subInfo:setJustification(app.justifyLeft)
  self:addSubGraphic(self.subInfo)

  self.subKeywords = app.Label("", kFontMain)
  self.subKeywords:setPosition(2, app.GRID4_LINE4)
  self.subKeywords:setJustification(app.justifyLeft)
  self:addSubGraphic(self.subKeywords)

  self:_rebuildUnitList()
  self:_refresh()
end

-- ---------------------------------------------------------------------------
-- Unit list management
-- ---------------------------------------------------------------------------

-- Pull all units from Factory, filter by channel count, then sort.
-- First-cut sort: by recency count (desc), then alpha.
function Dense:_rebuildUnitList()
  local channelCount = self.ring and self.ring:getChannelCount() or nil
  local all = Factory.getUnits(nil, channelCount)
  table.sort(all, function(a, b)
    local aTitle = a.title or ""
    local bTitle = b.title or ""
    local aRec = #Sparkline.ordinals(aTitle)
    local bRec = #Sparkline.ordinals(bTitle)
    if aRec ~= bRec then return aRec > bRec end
    return aTitle:upper() < bTitle:upper()
  end)
  self.units = all
  if self.cursorRow >= self:_rowCount() then
    self.cursorRow = math.max(0, self:_rowCount() - 1)
  end
end

function Dense:_rowCount()
  return math.ceil(#self.units / 2)
end

-- Returns (leftLoadInfo, rightLoadInfo) for row index r (0-based).
-- Either may be nil if the row is empty or partial.
function Dense:_unitsForRow(r)
  local leftIdx  = r * 2 + 1
  local rightIdx = r * 2 + 2
  return self.units[leftIdx], self.units[rightIdx]
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

-- Format a unit as "glyph name" truncated to colWidth chars. Keeps
-- the same glyph dispatch the classic view uses for visual continuity.
local kMaxLabelChars = 22  -- ~110 px at font 9 average glyph width
local function formatRowCell(loadInfo)
  if loadInfo == nil then return "" end
  local glyph = Glyph.forLoadInfo(loadInfo)
  local text  = glyph .. " " .. (loadInfo.title or "?")
  if #text > kMaxLabelChars then
    text = text:sub(1, kMaxLabelChars - 1) .. "."
  end
  return text
end

function Dense:_refresh()
  -- Adjust view window so cursor stays visible.
  if self.cursorRow < self.viewTop then
    self.viewTop = self.cursorRow
  elseif self.cursorRow >= self.viewTop + kVisibleRows then
    self.viewTop = self.cursorRow - (kVisibleRows - 1)
  end
  if self.viewTop < 0 then self.viewTop = 0 end

  -- Paint visible rows.
  for r = 1, kVisibleRows do
    local rowIdx = self.viewTop + (r - 1)
    local left, right = self:_unitsForRow(rowIdx)
    self.leftLabels[r]:setText(formatRowCell(left))
    self.rightLabels[r]:setText(formatRowCell(right))
  end

  -- Position cursor box on the focused row.
  -- An app.Label at baseline y renders text from y+4 to y+textHeight+3.
  -- Per the sequencer's empirical tuning (GridView.lua:262), the
  -- cursor wraps the glyph cleanly when mBottom = labelY+3 and the
  -- box height = 10.
  local visIdx = self.cursorRow - self.viewTop  -- 0..kVisibleRows-1
  if visIdx < 0 or visIdx >= kVisibleRows then
    self.cursorBox:hide()
  else
    local y = kRowYs[visIdx + 1]
    self.cursorBox:setPosition(0, y + 3)
    self.cursorBox:show()
  end

  -- Sub-display: focused unit info.
  local focusLeft, focusRight = self:_unitsForRow(self.cursorRow)
  local focus = focusLeft or focusRight  -- default to left cell
  self:_refreshSub(focus)
end

function Dense:_refreshSub(loadInfo)
  if loadInfo == nil then
    self.subTitle:setText("")
    self.subLib:setText("")
    self.subInfo:setText("")
    self.subKeywords:setText("")
    return
  end
  self.subTitle:setText(loadInfo.title or "?")
  self.subLib:setText(loadInfo.libraryName or "")
  local ord = #Sparkline.ordinals(loadInfo.title or "")
  self.subInfo:setText(string.format("used %dx", ord))
  -- Keywords: comma-separated, truncated to fit sub display width.
  local kws = loadInfo.keywords or ""
  if kws == "" then kws = "(untagged)" end
  if #kws > 22 then kws = kws:sub(1, 21) .. "." end
  self.subKeywords:setText(kws)
end

-- ---------------------------------------------------------------------------
-- Input handlers
-- ---------------------------------------------------------------------------

function Dense:encoder(change, shifted)
  self.encoderAccum = self.encoderAccum + change
  local moved = false
  while self.encoderAccum >= kEncoderThreshold do
    self.encoderAccum = self.encoderAccum - kEncoderThreshold
    if self.cursorRow < self:_rowCount() - 1 then
      self.cursorRow = self.cursorRow + 1
      moved = true
    end
  end
  while self.encoderAccum <= -kEncoderThreshold do
    self.encoderAccum = self.encoderAccum + kEncoderThreshold
    if self.cursorRow > 0 then
      self.cursorRow = self.cursorRow - 1
      moved = true
    end
  end
  if moved then self:_refresh() end
  return true
end

-- Pick the unit in column `side` ("L" or "R") on the focused row.
-- Records the pick into Sparkline + triggers the ring's load.
function Dense:_pick(side)
  local left, right = self:_unitsForRow(self.cursorRow)
  local target = (side == "L") and left or right
  if target == nil then return true end
  Sparkline.recordUse(target.title)
  Sparkline.flushIfDirty()
  self.ring:load(target)
  return true
end

function Dense:mainReleased(i, shifted)
  if shifted then return false end
  if i == 1 then
    return self:_pick("L")
  elseif i == 4 then
    return self:_pick("R")
  end
  return true
end

function Dense:enterReleased(shifted)
  if shifted then return false end
  return self:_pick("L")
end

function Dense:cancelReleased(shifted)
  return self.ring:cancelReleased(shifted)
end

function Dense:upReleased(shifted)
  return self.ring:upReleased(shifted)
end

function Dense:homeReleased()
  self.cursorRow = 0
  self.viewTop = 0
  self:_refresh()
  return true
end

return Dense

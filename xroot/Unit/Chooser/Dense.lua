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

-- Alphabet ribbon: 28 positions across the top row. Index 0 is the
-- null position (no filter); 1..26 are A..Z; 27 is # (numerics +
-- specials). No wrap on scroll, so the user can blast either
-- direction and stop at an extreme. HOME snaps to null;
-- shift+HOME snaps to #.
local kRibbonCount   = 28
local kRibbonY       = 54
local kRibbonNullCh  = "*"        -- placeholder for the null position
local kRibbonHashCh  = "#"
local kRibbonStep    = 9          -- 256 / 28 = ~9 px per cell
local function ribbonChar(i)
  if i == 0 then return kRibbonNullCh end
  if i == kRibbonCount - 1 then return kRibbonHashCh end
  return string.char(string.byte("A") + i - 1)
end
local function ribbonX(i) return i * kRibbonStep end

-- Decide which ribbon index a unit belongs to from its title's
-- first character. Returns 0 (null) is only used as the "no filter
-- match" sentinel; real units always return 1..27.
local function ribbonIndexForTitle(title)
  if title == nil or title == "" then return kRibbonCount - 1 end
  local c = title:sub(1, 1):upper()
  if c >= "A" and c <= "Z" then
    return c:byte() - string.byte("A") + 1
  end
  return kRibbonCount - 1
end

local kEncoderThreshold = Env.EncoderThreshold.Default

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

function Dense:init(ring)
  Window.init(self)
  self:setClassName("Unit.Chooser.Dense")
  self.ring = ring

  -- Cursor state.
  self.units        = {}         -- filtered + sorted loadInfo list
  self.allUnits     = nil        -- cached unfiltered list (for ribbon counts)
  self.cursorRow    = 0
  self.viewTop      = 0
  self.encoderAccum = 0
  self.ribbonIdx    = 0          -- 0 = null (no filter)
  self.ribbonCounts = nil        -- [0..27] = match count, lazily filled

  -- Alphabet ribbon labels. One Label per position; brightness is
  -- updated each refresh based on selection state + match count.
  self.ribbonLabels = {}
  for i = 0, kRibbonCount - 1 do
    local lbl = app.Label(ribbonChar(i), kFontMain)
    lbl:setPosition(ribbonX(i), kRibbonY)
    lbl:setJustification(app.justifyLeft)
    self:addMainGraphic(lbl)
    self.ribbonLabels[i] = lbl
  end

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

  -- Sub display: BOTH focused units side-by-side, mirroring the
  -- row cursor (which selects both cells). Left half = left-column
  -- unit (M1 picks), right half = right-column unit (M4 picks).
  -- Vertical hairline divider at x=64 keeps the split readable.
  -- Per column: M1/M4 header label, unit title, library, "used Nx".
  self.subDivider = app.Drawing(0, 0, 128, 64)
  local sdInstr = app.DrawingInstructions()
  sdInstr:color(app.GRAY3)
  sdInstr:vline(64, 4, 50)
  self.subDivider:add(sdInstr)
  self:addSubGraphic(self.subDivider)

  self.subLeft  = { header = "M1" }
  self.subRight = { header = "M4" }
  local function buildSide(side, xBase)
    side.label = app.Label(side.header, kFontMain)
    side.label:setPosition(xBase, app.GRID4_LINE1)
    side.label:setJustification(app.justifyLeft)
    side.label:setForegroundColor(app.GRAY7)
    self:addSubGraphic(side.label)

    side.title = app.Label("", kFontSub)
    side.title:setPosition(xBase, app.GRID4_LINE2)
    side.title:setJustification(app.justifyLeft)
    self:addSubGraphic(side.title)

    side.lib = app.Label("", kFontMain)
    side.lib:setPosition(xBase, app.GRID4_LINE3)
    side.lib:setJustification(app.justifyLeft)
    self:addSubGraphic(side.lib)

    side.used = app.Label("", kFontMain)
    side.used:setPosition(xBase, app.GRID4_LINE4)
    side.used:setJustification(app.justifyLeft)
    self:addSubGraphic(side.used)
  end
  buildSide(self.subLeft,  2)
  buildSide(self.subRight, 68)

  self:_rebuildUnitList()
  self:_refresh()
end

-- ---------------------------------------------------------------------------
-- Unit list management
-- ---------------------------------------------------------------------------

-- Pull all units from Factory once + cache. Sort by recency-then-
-- alpha. Apply the current ribbon filter (if any) to produce
-- self.units. Cache also feeds the ribbon's per-letter match counts.
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
  self.allUnits = all
  self:_recomputeRibbonCounts()
  self:_applyFilters()
end

-- Re-derive self.units from self.allUnits applying the active
-- ribbon filter. Cheap to call; runs on ribbon position change.
function Dense:_applyFilters()
  local idx = self.ribbonIdx
  if idx == 0 then
    self.units = self.allUnits
  else
    local out = {}
    for _, u in ipairs(self.allUnits) do
      if ribbonIndexForTitle(u.title) == idx then
        out[#out + 1] = u
      end
    end
    self.units = out
  end
  if self.cursorRow >= self:_rowCount() then
    self.cursorRow = math.max(0, self:_rowCount() - 1)
  end
  if self.cursorRow < 0 then self.cursorRow = 0 end
end

-- Lazy per-letter match counts. Called on rebuild (and later on
-- sort / type-filter changes, when they exist). Read-only by the
-- ribbon render path -- shift+encoder navigation reads the cache.
function Dense:_recomputeRibbonCounts()
  local counts = {}
  for i = 0, kRibbonCount - 1 do counts[i] = 0 end
  counts[0] = #(self.allUnits or {})  -- null = all
  for _, u in ipairs(self.allUnits or {}) do
    local i = ribbonIndexForTitle(u.title)
    counts[i] = counts[i] + 1
  end
  self.ribbonCounts = counts
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

  -- Paint ribbon: selected position bright, empty letters dim,
  -- others mid-gray.
  local counts = self.ribbonCounts or {}
  for i = 0, kRibbonCount - 1 do
    local color
    if i == self.ribbonIdx then
      color = app.WHITE
    elseif (counts[i] or 0) == 0 then
      color = app.GRAY3
    else
      color = app.GRAY7
    end
    self.ribbonLabels[i]:setForegroundColor(color)
  end

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

  -- Sub-display: both row units, side-by-side.
  local focusLeft, focusRight = self:_unitsForRow(self.cursorRow)
  self:_refreshSubSide(self.subLeft,  focusLeft)
  self:_refreshSubSide(self.subRight, focusRight)
end

-- Each sub-display half is ~62 px wide = ~11 chars at font 10,
-- ~12 chars at font 9. Truncate aggressively so nothing wraps into
-- the divider.
local kSubColChars = 12
local function clip(s)
  if s == nil then s = "" end
  if #s > kSubColChars then return s:sub(1, kSubColChars - 1) .. "." end
  return s
end

function Dense:_refreshSubSide(side, loadInfo)
  if loadInfo == nil then
    side.title:setText("")
    side.lib:setText("")
    side.used:setText("")
    return
  end
  side.title:setText(clip(loadInfo.title))
  side.lib:setText(clip(loadInfo.libraryName or ""))
  local ord = #Sparkline.ordinals(loadInfo.title or "")
  side.used:setText(string.format("used %dx", ord))
end

-- ---------------------------------------------------------------------------
-- Input handlers
-- ---------------------------------------------------------------------------

function Dense:encoder(change, shifted)
  self.encoderAccum = self.encoderAccum + change
  local moved = false
  if shifted then
    -- Ribbon nav: step one position per threshold, no wrap, skip
    -- empty letters (positions with 0 matches).
    while self.encoderAccum >= kEncoderThreshold do
      self.encoderAccum = self.encoderAccum - kEncoderThreshold
      if self:_stepRibbon(1) then moved = true end
    end
    while self.encoderAccum <= -kEncoderThreshold do
      self.encoderAccum = self.encoderAccum + kEncoderThreshold
      if self:_stepRibbon(-1) then moved = true end
    end
  else
    -- Row cursor nav: step one row per threshold, no wrap.
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
  end
  if moved then self:_refresh() end
  return true
end

-- Advance ribbon by `dir` positions (+/-1) skipping empties. No
-- wrap at extremes. Returns true if position actually changed.
function Dense:_stepRibbon(dir)
  local counts = self.ribbonCounts or {}
  local i = self.ribbonIdx + dir
  while i >= 0 and i < kRibbonCount do
    if (counts[i] or 0) > 0 then
      self.ribbonIdx = i
      self:_applyFilters()
      return true
    end
    i = i + dir
  end
  return false
end

-- Jump ribbon directly to position `i`. Used by HOME / shift+HOME.
function Dense:_setRibbon(i)
  if i < 0 then i = 0 elseif i >= kRibbonCount then i = kRibbonCount - 1 end
  if self.ribbonIdx == i then return end
  self.ribbonIdx = i
  self.cursorRow = 0
  self.viewTop = 0
  self:_applyFilters()
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

-- HOME snaps the ribbon to the null position (clears any letter
-- filter and resets the cursor to the top). shift+HOME (zeroReleased
-- in firmware-speak) snaps to the # tail position for fast access
-- to non-alphabetic titles.
function Dense:homeReleased()
  self:_setRibbon(0)
  self:_refresh()
  return true
end

function Dense:zeroReleased()
  self:_setRibbon(kRibbonCount - 1)
  self:_refresh()
  return true
end

return Dense

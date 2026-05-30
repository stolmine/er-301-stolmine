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
local kRibbonY       = 53        -- matches sequencer's kHeaderY: y=54 clips the top edge
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
-- Sort modes
-- ---------------------------------------------------------------------------

-- Comparator factories per sort mode. Each returns a function fit
-- for table.sort that produces total order over loadInfo entries.
-- Recency / favorite reads pull from Sparkline.ordinals and the
-- shared favorites hash via the classic Default chooser.

local function _alpha(a, b)
  return (a.title or ""):upper() < (b.title or ""):upper()
end

local function _byRecency(a, b)
  local aRec = #Sparkline.ordinals(a.title or "")
  local bRec = #Sparkline.ordinals(b.title or "")
  if aRec ~= bRec then return aRec > bRec end
  return _alpha(a, b)
end

local function _byGlyph(a, b)
  local ag = Glyph.forLoadInfo(a)
  local bg = Glyph.forLoadInfo(b)
  if ag ~= bg then return ag < bg end
  return _alpha(a, b)
end

local function _byPackage(a, b)
  local ap = a.libraryName or ""
  local bp = b.libraryName or ""
  if ap ~= bp then return ap < bp end
  return _alpha(a, b)
end

local function _primaryKeyword(loadInfo)
  local kws = loadInfo.keywords
  if kws == nil or kws == "" then return "~unknown" end
  return (kws:match("^%s*([^,]-)%s*,") or kws:match("^%s*(.-)%s*$") or ""):lower()
end

local function _byKeyword(a, b)
  local ak = _primaryKeyword(a)
  local bk = _primaryKeyword(b)
  if ak ~= bk then return ak < bk end
  return _alpha(a, b)
end

local function _byFavoritesFirst(a, b)
  -- Pulled from the classic chooser so the favorite hash is shared.
  local Default = require "Unit.Chooser.Default"
  local af = Default.favoriteHash[a.title or ""] and 1 or 0
  local bf = Default.favoriteHash[b.title or ""] and 1 or 0
  if af ~= bf then return af > bf end
  return _byRecency(a, b)
end

-- Ordered cycle the M2 button walks. Each entry: { id, label, cmp }.
local kSortModes = {
  { id = "recents",     label = "recents",   cmp = _byRecency        },
  { id = "alpha",       label = "alpha",     cmp = _alpha            },
  { id = "type",        label = "type",      cmp = _byGlyph          },
  { id = "package",     label = "package",   cmp = _byPackage        },
  { id = "keyword",     label = "keyword",   cmp = _byKeyword        },
  { id = "favorites",   label = "favs",      cmp = _byFavoritesFirst },
}

local function sortModeAt(idx)
  return kSortModes[((idx - 1) % #kSortModes) + 1]
end

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
  self.sortIdx      = 1          -- index into kSortModes; M2 advances
  self.typeFilter   = nil        -- nil = off; else a Glyph.* constant

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

  -- Status strip across the top of the sub display: shows the
  -- active sort mode label so the user sees what M2 will cycle.
  self.subStatus = app.Label("", kFontMain)
  self.subStatus:setPosition(2, app.GRID4_LINE1)
  self.subStatus:setJustification(app.justifyLeft)
  self.subStatus:setForegroundColor(app.GRAY10)
  self:addSubGraphic(self.subStatus)

  self.subLeft  = { header = "M1" }
  self.subRight = { header = "M4" }
  local function buildSide(side, xBase)
    side.label = app.Label(side.header, kFontMain)
    side.label:setPosition(xBase, app.GRID4_LINE2)
    side.label:setJustification(app.justifyLeft)
    side.label:setForegroundColor(app.GRAY7)
    self:addSubGraphic(side.label)

    side.title = app.Label("", kFontSub)
    side.title:setPosition(xBase, app.GRID4_LINE3)
    side.title:setJustification(app.justifyLeft)
    self:addSubGraphic(side.title)

    side.lib = app.Label("", kFontMain)
    side.lib:setPosition(xBase, app.GRID4_LINE4)
    side.lib:setJustification(app.justifyLeft)
    self:addSubGraphic(side.lib)
  end
  buildSide(self.subLeft,  2)
  buildSide(self.subRight, 68)

  self:_rebuildUnitList()
  self:_refresh()
end

-- ---------------------------------------------------------------------------
-- Unit list management
-- ---------------------------------------------------------------------------

-- Pull all units from Factory once + cache. Apply the active sort
-- comparator. Apply the current ribbon filter (if any) to produce
-- self.units. Cache also feeds the ribbon's per-letter match counts.
function Dense:_rebuildUnitList()
  local channelCount = self.ring and self.ring:getChannelCount() or nil
  local all = Factory.getUnits(nil, channelCount)
  table.sort(all, sortModeAt(self.sortIdx).cmp)
  self.allUnits = all
  self:_applyFilters()
end

-- Re-sort the cached unit list (without re-querying Factory) and
-- re-apply ribbon filter. Cheap; runs on M2 sort cycle.
function Dense:_resort()
  if self.allUnits == nil then return self:_rebuildUnitList() end
  table.sort(self.allUnits, sortModeAt(self.sortIdx).cmp)
  self:_applyFilters()
end

-- Re-derive self.rows from self.allUnits applying the active
-- ribbon filter, type filter, and packing into row entries. Cheap
-- to call; runs on ribbon position, sort cycle, or type filter.
function Dense:_applyFilters()
  -- Step 1: apply ribbon filter + type filter together (single pass).
  local idx = self.ribbonIdx
  local tf  = self.typeFilter
  local filtered = {}
  for _, u in ipairs(self.allUnits or {}) do
    local keep = true
    if idx ~= 0 and ribbonIndexForTitle(u.title) ~= idx then keep = false end
    if keep and tf ~= nil and not Glyph.loadInfoMatchesGlyph(u, tf) then
      keep = false
    end
    if keep then filtered[#filtered + 1] = u end
  end

  -- Step 2: pack into row entries (with section dividers if the
  -- active sort mode supports them AND dividers are enabled).
  self.rows = self:_packIntoRows(filtered)

  -- Recompute ribbon counts so empty-letter dimming reflects the
  -- type filter too: when filter is "$ modulate", letters with no
  -- modulate units dim out.
  self:_recomputeRibbonCounts()

  -- Step 3: snap cursor in-bounds and move off any divider row
  -- (encoder cursor never sits on a non-selectable row).
  if self.cursorRow >= #self.rows then
    self.cursorRow = math.max(0, #self.rows - 1)
  end
  if self.cursorRow < 0 then self.cursorRow = 0 end
  self.cursorRow = self:_nextSelectableRow(self.cursorRow, 1)
                or self:_nextSelectableRow(self.cursorRow, -1)
                or 0
end

-- Walk `filtered` in order, emitting divider rows at primary-key
-- boundaries (when applicable) and packing pairs of units into
-- "pair" rows. Returns a list of { type = "divider", label = X }
-- and { type = "pair", left = L, right = R } entries.
function Dense:_packIntoRows(filtered)
  local mode = sortModeAt(self.sortIdx)
  local Settings = require "Settings"
  local dividersOn = Settings.get("pickerSectionDividers") ~= "no"
  local keyFn = self:_dividerKeyFnFor(mode.id)

  local rows = {}
  local lastKey = nil
  local pending = nil  -- one half-row buffered while we look for a partner
  local function flushPending()
    if pending then
      rows[#rows + 1] = { type = "pair", left = pending, right = nil }
      pending = nil
    end
  end
  for _, u in ipairs(filtered) do
    local key = keyFn and keyFn(u) or nil
    if dividersOn and keyFn and key ~= lastKey then
      -- Section boundary: flush any half-row from the previous
      -- section so the next section starts cleanly on its own row.
      flushPending()
      rows[#rows + 1] = { type = "divider", label = key }
      lastKey = key
    end
    if pending == nil then
      pending = u
    else
      rows[#rows + 1] = { type = "pair", left = pending, right = u }
      pending = nil
    end
  end
  flushPending()
  return rows
end

-- Returns a function (loadInfo) -> section-key for sort modes that
-- group naturally. Modes without natural grouping return nil so
-- _packIntoRows skips divider emission.
function Dense:_dividerKeyFnFor(modeId)
  if modeId == "type" then
    -- "glyph  label" so users learn the legend by repeated exposure
    -- (e.g. "~  source", ">  effect"). The double space sets the
    -- glyph apart visually inside the divider's "- ... -" frame.
    return function(u)
      local g = Glyph.forLoadInfo(u)
      return g .. "  " .. Glyph.labelFor(g)
    end
  elseif modeId == "package" then
    return function(u) return u.libraryName or "" end
  elseif modeId == "keyword" then
    return _primaryKeyword
  end
  return nil
end

-- Skip past divider rows in the given direction. Returns the next
-- selectable row index, or nil if none exists in that direction.
function Dense:_nextSelectableRow(start, dir)
  local i = start
  while i >= 0 and i < #self.rows do
    if self.rows[i + 1] and self.rows[i + 1].type == "pair" then
      return i
    end
    i = i + dir
  end
  return nil
end

-- Per-letter match counts, honoring the active type filter so the
-- ribbon's empty-letter dim reflects what the user will actually
-- see. Recomputed on every _applyFilters call (rebuild, ribbon
-- move, sort cycle, type filter change). Bounded O(units) work.
function Dense:_recomputeRibbonCounts()
  local counts = {}
  for i = 0, kRibbonCount - 1 do counts[i] = 0 end
  local tf = self.typeFilter
  local total = 0
  for _, u in ipairs(self.allUnits or {}) do
    if tf == nil or Glyph.loadInfoMatchesGlyph(u, tf) then
      local i = ribbonIndexForTitle(u.title)
      counts[i] = counts[i] + 1
      total = total + 1
    end
  end
  counts[0] = total  -- null = total under current type filter
  self.ribbonCounts = counts
end

function Dense:_rowCount()
  return self.rows and #self.rows or 0
end

-- Returns the row entry for index r (0-based). May be nil if r is
-- out of range, a "pair" row with left/right loadInfos, or a
-- "divider" row with a label.
function Dense:_rowEntry(r)
  return self.rows and self.rows[r + 1] or nil
end

-- Returns (leftLoadInfo, rightLoadInfo) for the focused row. Both
-- nil if the row is a divider or out of range.
function Dense:_unitsForRow(r)
  local entry = self:_rowEntry(r)
  if entry == nil or entry.type ~= "pair" then return nil, nil end
  return entry.left, entry.right
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

  -- Paint visible rows. Divider rows render their label across the
  -- whole left-column slot (clearing the right column) at GRAY7;
  -- pair rows render left + right unit text as usual.
  for r = 1, kVisibleRows do
    local rowIdx = self.viewTop + (r - 1)
    local entry = self:_rowEntry(rowIdx)
    if entry == nil then
      self.leftLabels[r]:setText("")
      self.rightLabels[r]:setText("")
    elseif entry.type == "divider" then
      self.leftLabels[r]:setText("- " .. (entry.label or "") .. " -")
      self.leftLabels[r]:setForegroundColor(app.GRAY7)
      self.rightLabels[r]:setText("")
    else
      self.leftLabels[r]:setText(formatRowCell(entry.left))
      self.leftLabels[r]:setForegroundColor(app.WHITE)
      self.rightLabels[r]:setText(formatRowCell(entry.right))
      self.rightLabels[r]:setForegroundColor(app.WHITE)
    end
  end

  -- Position cursor box on the focused row.
  -- An app.Label at baseline y renders text from y+4 to y+textHeight+3.
  -- Per the sequencer's empirical tuning (GridView.lua:262), the
  -- cursor wraps the glyph cleanly when mBottom = labelY+3 and the
  -- box height = 10. Hidden when cursor lands off-screen or on a
  -- divider (which shouldn't happen normally; safety net).
  local visIdx = self.cursorRow - self.viewTop  -- 0..kVisibleRows-1
  local entry  = self:_rowEntry(self.cursorRow)
  if visIdx < 0 or visIdx >= kVisibleRows
     or entry == nil or entry.type ~= "pair" then
    self.cursorBox:hide()
  else
    local y = kRowYs[visIdx + 1]
    self.cursorBox:setPosition(0, y + 3)
    self.cursorBox:show()
  end

  -- Sub-display top status: active sort mode (M2 cycles) + active
  -- type filter (M3 cycles) when on.
  local mode = sortModeAt(self.sortIdx)
  local txt = string.format("sort:%s", mode.label)
  if self.typeFilter then
    txt = txt .. string.format("  type:%s", self.typeFilter)
  end
  self.subStatus:setText(txt)

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
    return
  end
  side.title:setText(clip(loadInfo.title))
  side.lib:setText(clip(loadInfo.libraryName or ""))
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
    -- Row cursor nav: step one row per threshold, no wrap. Divider
    -- rows are non-selectable, so each step lands on the next
    -- "pair" row (which may be 2+ raw rows away when a divider
    -- sits between).
    while self.encoderAccum >= kEncoderThreshold do
      self.encoderAccum = self.encoderAccum - kEncoderThreshold
      local target = self:_nextSelectableRow(self.cursorRow + 1, 1)
      if target then
        self.cursorRow = target
        moved = true
      end
    end
    while self.encoderAccum <= -kEncoderThreshold do
      self.encoderAccum = self.encoderAccum + kEncoderThreshold
      local target = self:_nextSelectableRow(self.cursorRow - 1, -1)
      if target then
        self.cursorRow = target
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
  if i == 1 then
    if shifted then return false end
    return self:_pick("L")
  elseif i == 2 then
    -- Cycle sort mode (shifted = reverse cycle).
    local dir = shifted and -1 or 1
    self.sortIdx = ((self.sortIdx - 1 + dir) % #kSortModes) + 1
    self.cursorRow = 0
    self.viewTop = 0
    self:_resort()
    self:_refresh()
    return true
  elseif i == 3 then
    -- Cycle type filter: off -> ~ -> > -> $ -> * -> . -> ? -> off.
    -- Overlap-aware: filter selects units whose keyword list
    -- CONTAINS the target class, so a unit tagged "effect,
    -- container" appears under both > and . filters.
    self:_cycleTypeFilter(shifted and -1 or 1)
    return true
  elseif i == 4 then
    if shifted then return false end
    return self:_pick("R")
  end
  return true
end

function Dense:_cycleTypeFilter(dir)
  local order = Glyph.cycleOrder
  -- Index 0 = off; 1..#order map to the cycle glyphs.
  local cur = 0
  if self.typeFilter then
    for i, g in ipairs(order) do
      if g == self.typeFilter then cur = i; break end
    end
  end
  local n = #order + 1   -- +1 for the "off" slot
  cur = (cur + dir) % n
  if cur < 0 then cur = cur + n end
  self.typeFilter = (cur == 0) and nil or order[cur]
  self.cursorRow = 0
  self.viewTop = 0
  self:_applyFilters()
  self:_refresh()
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

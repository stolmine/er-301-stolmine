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
local Signal = require "Signal"
local Factory = require "Unit.Factory"
local Encoder = require "Encoder"
local Glyph = require "Unit.Chooser.Glyph"
local Sparkline = require "Unit.Chooser.Sparkline"
local Hidden = require "Unit.Chooser.Hidden"

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
local kCursorIndent  = 2         -- pad between row cursor and label
local kCursorHeight  = 10
local kColWidth      = 120       -- visual width per column cell

-- Each column splits into 3 fixed slots so the eye perceives 6
-- aligned sub-columns across the picker. Left column = slots
-- 1L (glyph) / 2L (name) / 3L (fav). Right column = mirror at
-- x=128. Glyph and fav are single-char positions; name owns the
-- middle bulk of the row.
local kLeftGlyphX  = 4
local kLeftNameX   = 14
local kLeftFavX    = 121
local kRightGlyphX = 132
local kRightNameX  = 142
local kRightFavX   = 249
-- Max name slot width in chars (font 9, ~5 px/char). Roughly the
-- gap between name X and fav X for each column.
local kMaxNameChars = 20

-- Y baselines (bottom-up). Five visible rows + one extra slot at
-- y=-1 used as the "slide-in" row during a smooth scroll: when
-- scrollFrac eases between integer startRow values, subPx > 0
-- shifts every row upward, and the extra slot at the bottom comes
-- into view as the top slot exits behind the ribbon.
local kRowYs       = { 44, 35, 26, 17, 8, -1 }
local kPaintRows   = 6
-- Where the cursor "wants" to sit in the visible window: row 3
-- of 5 (zero-indexed: targetStart = cursorRow - 2). Matches the
-- sequencer's "focus head sits at the 3rd visible row" pattern.
local kCursorOffset = 2

-- Footer chip baseline. Matches the sequencer's bottom-row pattern
-- (kRowYs ends at -1 for the same reason: setPosition sets the
-- BOTTOM of the label's bounding box, not the glyph baseline, so
-- y=-1 puts the actual glyph at y=3..11 which clears the bottom
-- edge for ascender-only text).
local kFooterY = -1

-- M-key chip centers from app.getButtonCenter(i) = (i-1)*43 + 20.
-- M1=20, M2=63, M3=106, M4=149, M5=192, M6=235.
local kMKeyX = { 20, 63, 106, 149, 192, 235 }
-- Half-width estimate per chip (font 9 monospace, ~5 px/char). For
-- 4-char chips ("sort", "type", "hide", etc.) the visible glyphs
-- span ~20 px, so subtract 10 from the M-key center to find the
-- left edge. We use setPosition (bottom-of-bbox) NOT setCenter so
-- the Y semantics match the sequencer's cell rows.
local kChipHalfWidth = 10

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

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Easing constants (aped from sequencer GridView.lua:558-580).
-- 55 Hz refresh; 0.4 lerp converges to ~95% in 6 frames (~110 ms).
-- Snap thresholds (kCursorSnapEps / kScrollSnapRows) prevent
-- sub-pixel jitter near the target.
local kCursorEase    = 0.4
local kCursorSnapEps = 0.5
local kCursorJumpPx  = 5     -- > kJumpPx delta enters easing mode; smaller deltas snap (used during smooth scroll)
local kScrollLerp    = 0.4
local kScrollSnapRows = 1 / kRowHeight

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

-- Reverse lookup: sort-mode id ("recents" / "alpha" / ...) ->
-- index into kSortModes. Returns 1 (recents) for unknown ids.
local function sortIdxFor(id)
  for i, m in ipairs(kSortModes) do
    if m.id == id then return i end
  end
  return 1
end

-- ---------------------------------------------------------------------------
-- M-key chip labels per edit mode. Index 1..6 = M1..M6.
-- ---------------------------------------------------------------------------

local kChipLabels = {
  pick = { "pick", "sort", "type", "pick", "hide", "fav"  },
  hide = { "tagL", "sort", "type", "tagR", "done", "fav"  },
  fav  = { "tagL", "sort", "type", "tagR", "hide", "done" },
}

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

function Dense:init(ring)
  Window.init(self)
  self:setClassName("Unit.Chooser.Dense")
  self.ring = ring

  -- Cursor + scroll state.
  self.units         = {}         -- filtered + sorted loadInfo list
  self.allUnits      = nil        -- cached unfiltered list (for ribbon counts)
  self.cursorRow     = 0
  self.encoderAccum  = 0
  self.ribbonIdx     = 0          -- 0 = null (no filter)
  self.ribbonCounts  = nil        -- [0..27] = match count, lazily filled
  -- Sort mode index; M2 advances. Defaults to the user's admin
  -- pickerDefaultSort preference (falls back to recents).
  local Settings = require "Settings"
  self.sortIdx       = sortIdxFor(Settings.get("pickerDefaultSort"))
  self.typeFilter    = nil        -- nil = off; else a Glyph.* constant
  self.editMode      = "pick"     -- "pick" | "hide" | "fav"
  self.encoderState  = Encoder.Fine -- toggled by dial press/release
  -- Animation state. Nil values snap on first paint after onShow.
  self.scrollFrac    = nil        -- float row index of top visible slot
  self.cursorAnimY   = nil
  self.cursorEasingY = false

  -- Per painted row, six separate labels: glyph + name + fav for
  -- each of the two columns. Splitting them gives fixed horizontal
  -- alignment across the picker (the eye sees 6 sub-columns even
  -- though logical cells are 2). The fav '+' marker is always
  -- visible (independent of edit mode) so users see fav state at
  -- a glance. kPaintRows = kVisibleRows + 1 so the extra row at
  -- y=-1 acts as the slide-in position during smooth scroll.
  self.leftGlyphs  = {}
  self.leftNames   = {}
  self.leftFavs    = {}
  self.rightGlyphs = {}
  self.rightNames  = {}
  self.rightFavs   = {}
  local function makeLabel(x, y)
    local lbl = app.Label("", kFontMain)
    lbl:setJustification(app.justifyLeft)
    lbl:setPosition(x, y)
    self:addMainGraphic(lbl)
    return lbl
  end
  -- Fav marker uses setCenter so its glyph midpoint aligns with
  -- the cursor box's vertical midpoint (cursor bottom = labelY+3,
  -- height 10 -> midpoint = labelY+8). Each refresh re-runs
  -- setCenter to keep alignment as rows slide.
  local function makeFav(x, y)
    local lbl = app.Label("", kFontMain)
    lbl:setJustification(app.justifyCenter)
    lbl:setCenter(x, y + 8)
    self:addMainGraphic(lbl)
    return lbl
  end
  for r = 1, kPaintRows do
    local y = kRowYs[r]
    self.leftGlyphs[r]  = makeLabel(kLeftGlyphX,  y)
    self.leftNames[r]   = makeLabel(kLeftNameX,   y)
    self.leftFavs[r]    = makeFav  (kLeftFavX,    y)
    self.rightGlyphs[r] = makeLabel(kRightGlyphX, y)
    self.rightNames[r]  = makeLabel(kRightNameX,  y)
    self.rightFavs[r]   = makeFav  (kRightFavX,   y)
  end

  -- Row-cursor box: a 1-px border around BOTH cells of the focused
  -- row (full 256 px wide). Drawn behind labels so labels still read
  -- clearly. Positioned per refresh based on cursorRow vs scrollFrac.
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

  -- Occluder rectangles for the ribbon row (top) and the chip row
  -- (bottom). Without these, smooth-scrolling rows visually poke
  -- into the ribbon and chip text bands. The masks are drawn AFTER
  -- the row labels (so they erase the slide-over text) and BEFORE
  -- the ribbon / footer labels (so those still render on top).
  --
  -- Implementation: app.Graphic with setOpaque(true) +
  -- setBackgroundColor(BLACK). Graphic::draw routes that combo to
  -- fb.clear() which TRULY erases pixels (set, not blend).
  -- DrawingInstructions:fill with BLACK is a no-op because fb.fill
  -- uses blend semantics (OR), and ORing 0 leaves the pixel as-is.
  -- Top mask starts at y=57 (text-bottom of the ribbon glyphs and
  -- 1 px above row 1's text top at y=56), so row 1 is fully visible
  -- when not sliding but any pixels that slide ABOVE y=56 get
  -- erased before the ribbon labels draw on top.
  self.topMask = app.Graphic(0, 57, 256, 7)
  self.topMask:setOpaque(true)
  self.topMask:setBackgroundColor(app.BLACK)
  self:addMainGraphic(self.topMask)

  self.botMask = app.Graphic(0, 0, 256, 10)
  self.botMask:setOpaque(true)
  self.botMask:setBackgroundColor(app.BLACK)
  self:addMainGraphic(self.botMask)

  -- Alphabet ribbon labels. Re-created AFTER the occluder mask so
  -- they render on top of it. One Label per position; brightness
  -- updated each refresh based on selection + match count.
  self.ribbonLabels = {}
  for i = 0, kRibbonCount - 1 do
    local lbl = app.Label(ribbonChar(i), kFontMain)
    lbl:setPosition(ribbonX(i), kRibbonY)
    lbl:setJustification(app.justifyLeft)
    self:addMainGraphic(lbl)
    self.ribbonLabels[i] = lbl
  end

  -- Footer chip labels above M1-M6 showing what each key does.
  -- Updated by _refresh based on current edit mode. Positioned
  -- using setPosition (bottom-of-bbox semantics) at y=kFooterY,
  -- with X pre-offset by half the chip width so the visible
  -- glyphs straddle the M-key center.
  self.footerLabels = {}
  for i = 1, 6 do
    local lbl = app.Label("", kFontMain)
    lbl:setJustification(app.justifyLeft)
    lbl:setPosition(kMKeyX[i] - kChipHalfWidth, kFooterY)
    lbl:setForegroundColor(app.GRAY10)
    self:addMainGraphic(lbl)
    self.footerLabels[i] = lbl
  end

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
  -- Step 1: apply ribbon filter + type filter + hidden filter
  -- together. Hidden units are excluded in "pick" mode, INCLUDED in
  -- "hide" mode (so the user can unhide), and excluded in "fav"
  -- mode (favoriting a hidden unit makes no sense).
  -- Type filter is strict glyph match: a unit shows up under the
  -- filter ONLY if its displayed glyph (= first keyword) equals
  -- the filter. WYSIWYG: what the row label shows is what the
  -- filter pulls in.
  local idx = self.ribbonIdx
  local tf  = self.typeFilter
  local showHidden = self.editMode == "hide"
  local filtered = {}
  for _, u in ipairs(self.allUnits or {}) do
    local keep = true
    if idx ~= 0 and ribbonIndexForTitle(u.title) ~= idx then keep = false end
    if keep and tf ~= nil and Glyph.forLoadInfo(u) ~= tf then
      keep = false
    end
    if keep and not showHidden and Hidden.isHidden(u.title) then
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
  elseif modeId == "alpha" then
    -- One divider per starting letter. Non-letter titles (digits,
    -- underscores) collapse into a single "#" section that sits
    -- at the natural sort position before "A".
    return function(u)
      local t = u.title or ""
      local c = t:sub(1, 1):upper()
      if c >= "A" and c <= "Z" then return c end
      return "#"
    end
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
    if tf == nil or Glyph.forLoadInfo(u) == tf then
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

-- Each cell renders into 3 separate slots (glyph / name / fav),
-- so the picker reads as 6 vertically-aligned sub-columns across
-- both halves of the screen. Glyph + name are split into their
-- own labels; fav is rendered separately via favMarkerFor.

local function glyphCellFor(loadInfo)
  if loadInfo == nil then return "" end
  return Glyph.forLoadInfo(loadInfo)
end

local function nameCellFor(loadInfo)
  if loadInfo == nil then return "" end
  local title = loadInfo.title or "?"
  if #title > kMaxNameChars then
    title = title:sub(1, kMaxNameChars - 1) .. "."
  end
  return title
end

-- Right-edge marker text: '+' if the unit is favorited, blank
-- otherwise. Always visible (not gated on edit mode) so the user
-- sees fav state at a glance from any view.
local function favMarkerFor(loadInfo)
  if loadInfo == nil then return "" end
  local Default = require "Unit.Chooser.Default"
  return Default.favoriteHash[loadInfo.title or ""] and "+" or ""
end

-- Per-cell color reflecting edit-mode state. In hide mode, units
-- that are already hidden render dim (GRAY5) so the user sees the
-- toggle state without needing a separate badge. In fav mode the
-- "+" marker carries the signal; color stays WHITE.
local function rowColorFor(loadInfo, editMode)
  if loadInfo == nil then return app.WHITE end
  if editMode == "hide" and Hidden.isHidden(loadInfo.title or "") then
    return app.GRAY5
  end
  return app.WHITE
end

-- Glyph slot visibility + brightness rules:
--   * alpha sort hides the glyph entirely (alpha is a "scan by
--     name" mode, glyph adds noise)
--   * type sort or active type filter -> WHITE (glyph is the
--     primary semantic axis in that view)
--   * everything else -> GRAY7 (present but quiet)
-- Returns nil to suppress the glyph entirely, or a color constant.
local function glyphColorFor(sortId, typeFilter)
  if sortId == "alpha" then return nil end
  if sortId == "type" or typeFilter ~= nil then return app.WHITE end
  return app.GRAY7
end

function Dense:_refresh()
  -- Smooth-scroll target: keep cursor at row 3 of 5 visible (per
  -- kCursorOffset) except when clamped at the list extremes.
  local maxStart = math.max(0, self:_rowCount() - kVisibleRows)
  local targetStart = clamp(self.cursorRow - kCursorOffset, 0, maxStart)
  if self.scrollFrac == nil then
    self.scrollFrac = targetStart
  else
    self.scrollFrac = self.scrollFrac * (1 - kScrollLerp)
                       + targetStart * kScrollLerp
    if math.abs(self.scrollFrac - targetStart) < kScrollSnapRows then
      self.scrollFrac = targetStart
    end
  end
  local startRow = math.floor(self.scrollFrac)
  local subPx    = (self.scrollFrac - startRow) * kRowHeight

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

  -- Paint kPaintRows rows. Each slot's Y is its base position plus
  -- the smooth-scroll subPx offset, so all rows slide vertically
  -- in sync during a scroll transition. Slot kPaintRows (bottom,
  -- y=-1 at rest) becomes visible at y=8 when subPx reaches the
  -- row pitch, providing the slide-in row.
  local glyphSortId = sortModeAt(self.sortIdx).id
  for r = 1, kPaintRows do
    local rowIdx = startRow + (r - 1)
    local entry  = self:_rowEntry(rowIdx)
    local y      = kRowYs[r] + subPx
    -- All 6 sub-cell labels share the same Y for the row. Glyph
    -- and name use setPosition (left-justified at fixed X); fav
    -- uses setCenter so its glyph midpoint stays at the cursor-
    -- box midpoint (y+8) regardless of row position.
    self.leftGlyphs[r]:setPosition(kLeftGlyphX,  y)
    self.leftNames[r]:setPosition(kLeftNameX,    y)
    self.leftFavs[r]:setCenter(kLeftFavX,        y + 8)
    self.rightGlyphs[r]:setPosition(kRightGlyphX, y)
    self.rightNames[r]:setPosition(kRightNameX,   y)
    self.rightFavs[r]:setCenter(kRightFavX,       y + 8)
    if entry == nil then
      self.leftGlyphs[r]:setText("")
      self.leftNames[r]:setText("")
      self.leftFavs[r]:setText("")
      self.rightGlyphs[r]:setText("")
      self.rightNames[r]:setText("")
      self.rightFavs[r]:setText("")
    elseif entry.type == "divider" then
      -- Divider spans the left column (glyph slot blank, name slot
      -- holds "- label -"), right column blank. No favs on dividers.
      self.leftGlyphs[r]:setText("")
      self.leftNames[r]:setText("- " .. (entry.label or "") .. " -")
      self.leftNames[r]:setForegroundColor(app.GRAY7)
      self.rightGlyphs[r]:setText("")
      self.rightNames[r]:setText("")
      self.leftFavs[r]:setText("")
      self.rightFavs[r]:setText("")
    else
      local leftColor  = rowColorFor(entry.left,  self.editMode)
      local rightColor = rowColorFor(entry.right, self.editMode)
      local glyphColor = glyphColorFor(glyphSortId, self.typeFilter)
      if glyphColor == nil then
        -- alpha sort: glyph slot blank, alignment preserved.
        self.leftGlyphs[r]:setText("")
        self.rightGlyphs[r]:setText("")
      else
        self.leftGlyphs[r]:setText(glyphCellFor(entry.left))
        self.leftGlyphs[r]:setForegroundColor(glyphColor)
        self.rightGlyphs[r]:setText(glyphCellFor(entry.right))
        self.rightGlyphs[r]:setForegroundColor(glyphColor)
      end
      self.leftNames[r]:setText(nameCellFor(entry.left))
      self.leftNames[r]:setForegroundColor(leftColor)
      self.rightNames[r]:setText(nameCellFor(entry.right))
      self.rightNames[r]:setForegroundColor(rightColor)
      self.leftFavs[r]:setText(favMarkerFor(entry.left))
      self.rightFavs[r]:setText(favMarkerFor(entry.right))
    end
  end

  -- Position cursor box on the focused row. Target Y tracks the
  -- (already smooth-scrolling) row baselines so the cursor slides
  -- with the data during a scroll transition. The cursorEasingY
  -- flag controls when to ease vs snap (per sequencer's pattern):
  --   * small deltas (within kCursorJumpPx) snap directly, which
  --     keeps the cursor glued to its row as subPx slides ~1.8
  --     px/frame.
  --   * big deltas (row jump on boundary or HOME) enter easing
  --     mode and lerp at kCursorEase per frame until within
  --     kCursorSnapEps, then snap + exit easing mode. This is the
  --     "settle" feel the sequencer has.
  local visIdx = self.cursorRow - startRow  -- 0..kPaintRows-1
  local entry  = self:_rowEntry(self.cursorRow)
  if visIdx < 0 or visIdx >= kPaintRows
     or entry == nil or entry.type ~= "pair" then
    self.cursorBox:hide()
  else
    local targetY = kRowYs[visIdx + 1] + subPx + 3
    if self.cursorAnimY == nil then
      self.cursorAnimY   = targetY
      self.cursorEasingY = false
    else
      local delta = targetY - self.cursorAnimY
      if math.abs(delta) > kCursorJumpPx then
        self.cursorEasingY = true
      end
      if self.cursorEasingY then
        self.cursorAnimY = self.cursorAnimY + delta * kCursorEase
        if math.abs(self.cursorAnimY - targetY) < kCursorSnapEps then
          self.cursorAnimY   = targetY
          self.cursorEasingY = false
        end
      else
        self.cursorAnimY = targetY
      end
    end
    self.cursorBox:setPosition(0, math.floor(self.cursorAnimY + 0.5))
    self.cursorBox:show()
  end

  -- Sub-display top status: active sort mode (M2 cycles) + active
  -- type filter (M3 cycles) when on + edit mode when non-pick.
  local mode = sortModeAt(self.sortIdx)
  local txt = string.format("sort:%s", mode.label)
  if self.typeFilter then
    txt = txt .. string.format("  type:%s", self.typeFilter)
  end
  if self.editMode ~= "pick" then
    txt = txt .. string.format("  edit:%s", self.editMode)
  end
  self.subStatus:setText(txt)

  -- Footer M-key chips per current edit mode. The active edit
  -- mode's M-key (M5 in hide, M6 in fav) renders at WHITE so the
  -- "tap again to exit" target stands out.
  local chips = kChipLabels[self.editMode] or kChipLabels.pick
  for i = 1, 6 do
    self.footerLabels[i]:setText(chips[i])
    local isExit = (self.editMode == "hide" and i == 5)
                or (self.editMode == "fav"  and i == 6)
    self.footerLabels[i]:setForegroundColor(isExit and app.WHITE or app.GRAY10)
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
    return
  end
  side.title:setText(clip(loadInfo.title))
  side.lib:setText(clip(loadInfo.libraryName or ""))
end

-- ---------------------------------------------------------------------------
-- Input handlers
-- ---------------------------------------------------------------------------

function Dense:onShow()
  -- Re-assert encoder rate on each picker open so the previous
  -- window's setting doesn't carry over.
  Encoder.set(self.encoderState)
  -- Drive the per-frame refresh (55 Hz) so the cursor + scroll
  -- easings animate instead of only updating on input events.
  -- Snap all easing state so the first paint after a hide+show
  -- doesn't animate in from the stale last-on-screen position.
  self.cursorAnimY   = nil
  self.cursorEasingY = false
  self.scrollFrac    = nil
  self.frameCallback = function() self:_refresh() end
  Signal.register("onDisplayFrame", self.frameCallback)
end

function Dense:onHide()
  if self.frameCallback then
    Signal.remove("onDisplayFrame", self.frameCallback)
    self.frameCallback = nil
  end
end

function Dense:dialPressed(shifted)
  self.encoderState = Encoder.Coarse
  Encoder.set(self.encoderState)
  return true
end

function Dense:dialReleased(shifted)
  self.encoderState = Encoder.Fine
  Encoder.set(self.encoderState)
  return true
end

-- Jump cursor to the first selectable row of the next section in
-- `dir` (+1 / -1). Section boundaries are the divider rows.
--
-- Going DOWN: the first divider below the cursor IS the next
-- section's divider, so landing on "first selectable past it" is
-- the correct first hit.
--
-- Going UP: the first divider above the cursor is the CURRENT
-- section's divider, whose landing position equals where we
-- already are (top of our own section). Skip those and keep
-- walking up until the landing position is strictly above the
-- current cursor row.
function Dense:_jumpToHeader(dir)
  if self.rows == nil or #self.rows == 0 then return false end
  local i = self.cursorRow + dir
  while i >= 0 and i < #self.rows do
    if self.rows[i + 1].type == "divider" then
      local target = self:_nextSelectableRow(i + 1, 1)
      if target then
        local progress = (dir > 0) and (target > self.cursorRow)
                                   or  (target < self.cursorRow)
        if progress then
          self.cursorRow = target
          return true
        end
      end
    end
    i = i + dir
  end
  -- No more dividers in this direction: snap to the extreme
  -- selectable row.
  local extreme = (dir > 0) and (#self.rows - 1) or 0
  local target = self:_nextSelectableRow(extreme, -dir)
  if target and target ~= self.cursorRow then
    self.cursorRow = target
    return true
  end
  return false
end

function Dense:encoder(change, shifted)
  self.encoderAccum = self.encoderAccum + change
  local moved = false

  -- Coarse mode: jump cursor by section header in sort modes that
  -- have dividers. Falls back to per-row stepping in modes without
  -- dividers so the dial isn't a no-op anywhere.
  if self.encoderState == Encoder.Coarse and not shifted then
    while self.encoderAccum >= kEncoderThreshold do
      self.encoderAccum = self.encoderAccum - kEncoderThreshold
      if self:_jumpToHeader(1) then moved = true end
    end
    while self.encoderAccum <= -kEncoderThreshold do
      self.encoderAccum = self.encoderAccum + kEncoderThreshold
      if self:_jumpToHeader(-1) then moved = true end
    end
    if moved then self:_refresh() end
    return true
  end

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
  self.ribbonIdx  = i
  self.cursorRow  = 0
  self.scrollFrac = nil
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

-- Toggle hide on the cell in column `side` of the focused row.
-- Refreshes in place (the unit stays visible because we're in
-- "hide" mode); rebuild not needed.
function Dense:_toggleHide(side)
  local left, right = self:_unitsForRow(self.cursorRow)
  local target = (side == "L") and left or right
  if target == nil then return true end
  Hidden.toggle(target.title)
  Hidden.flushIfDirty()
  self:_refresh()
  return true
end

-- Toggle favorite on the cell in column `side` of the focused row.
-- Delegates to the classic chooser's favorite hash so the two
-- views share favorites.
function Dense:_toggleFav(side)
  local left, right = self:_unitsForRow(self.cursorRow)
  local target = (side == "L") and left or right
  if target == nil then return true end
  local Default = require "Unit.Chooser.Default"
  Default:toggleFavorite(target)
  Default:saveFavoritesIfDirty()
  self:_refresh()
  return true
end

function Dense:mainReleased(i, shifted)
  if i == 1 then
    if shifted then return false end
    if self.editMode == "hide" then return self:_toggleHide("L") end
    if self.editMode == "fav"  then return self:_toggleFav("L")  end
    return self:_pick("L")
  elseif i == 2 then
    -- Cycle sort mode (shifted = reverse cycle).
    local dir = shifted and -1 or 1
    self.sortIdx = ((self.sortIdx - 1 + dir) % #kSortModes) + 1
    self.cursorRow  = 0
    self.scrollFrac = nil
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
    if self.editMode == "hide" then return self:_toggleHide("R") end
    if self.editMode == "fav"  then return self:_toggleFav("R")  end
    return self:_pick("R")
  elseif i == 5 then
    -- Toggle hide-edit mode; if already in fav-edit, swap directly.
    self.editMode = (self.editMode == "hide") and "pick" or "hide"
    self.cursorRow  = 0
    self.scrollFrac = nil
    self:_applyFilters()
    self:_refresh()
    return true
  elseif i == 6 then
    self.editMode = (self.editMode == "fav") and "pick" or "fav"
    self.cursorRow  = 0
    self.scrollFrac = nil
    self:_applyFilters()
    self:_refresh()
    return true
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
  self.cursorRow  = 0
  self.scrollFrac = nil
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

-- HOME = cursor to top of the CURRENT view (filters / sort stay
-- intact). shift+HOME (zeroReleased) = full reset to the user's
-- starting state: ribbon to null, type filter off, sort restored
-- to the pickerDefaultSort admin preference, cursor to top.
function Dense:homeReleased()
  self.cursorRow  = self:_nextSelectableRow(0, 1) or 0
  self.scrollFrac = nil
  self:_refresh()
  return true
end

function Dense:zeroReleased()
  local Settings = require "Settings"
  self.ribbonIdx  = 0
  self.typeFilter = nil
  self.sortIdx    = sortIdxFor(Settings.get("pickerDefaultSort"))
  self.cursorRow  = 0
  self.scrollFrac = nil
  self:_resort()
  self:_refresh()
  return true
end

return Dense

-- Recency sparkline for the unit picker. Owns both the per-unit
-- use-history data store (~/.od/rear/recencyHistory.lua) and the
-- 5-char string renderer that produces the trailing sparkline on
-- each picker row.
--
-- The firmware Lua sandbox has no `os` library, so we can't use
-- wall-clock time. Instead we maintain a monotonic "use ordinal"
-- counter that increments on every recordUse and persist it
-- alongside the per-unit history. Each per-unit entry stores the
-- ordinal values (newest first, ring-trimmed to 32) at which that
-- unit was picked.
--
-- The sparkline collapses the ordinal list into 5 recency buckets
-- by computing each entry's delta from the current global ordinal:
--   bucket 1: delta <=  5    (used within the last 5 picker actions)
--   bucket 2: delta <= 20
--   bucket 3: delta <= 50
--   bucket 4: delta <= 200
--   bucket 5: older
-- This is ordinal-time, not wall-time, but tracks user activity in
-- a way that is effectively "recent in your workflow."

local app = app
local Persist = require "Persist"

local Sparkline = {}

local kHistoryPath  = app.roots.rear .. "/recencyHistory.lua"
local kRingMax      = 32
local kBucketBounds = { 5, 20, 50, 200, math.huge }
local kDensityChars = { [0] = " ", ".", ":", ":", "|" }

-- In-memory state. nextOrdinal is the value that will be stamped
-- on the NEXT recordUse; units[title] is a newest-first ordinal
-- list trimmed to kRingMax.
local state = nil
local dirty = false

local function ensureLoaded()
  if state ~= nil then return end
  local t = Persist.readTable(kHistoryPath)
  if t and t.nextOrdinal and t.units then
    state = { nextOrdinal = t.nextOrdinal, units = t.units }
  else
    state = { nextOrdinal = 1, units = {} }
  end
end

-- Append a use-event for `title`. Trims the per-unit ring to
-- kRingMax. Marks the store dirty; caller should flushIfDirty()
-- later (typically right after, to be safe). No-op on nil / empty.
function Sparkline.recordUse(title)
  if title == nil or title == "" then return end
  ensureLoaded()
  local ord = state.nextOrdinal
  local list = state.units[title]
  if list == nil then
    state.units[title] = { ord }
  else
    table.insert(list, 1, ord)
    while #list > kRingMax do table.remove(list) end
  end
  state.nextOrdinal = ord + 1
  dirty = true
end

-- Write the history back to disk if anything has changed. Returns
-- true if a write happened, false otherwise. Cheap to call.
function Sparkline.flushIfDirty()
  if not dirty then return false end
  Persist.writeTable(kHistoryPath, state)
  dirty = false
  return true
end

-- Drop all stored history. Used by an admin "clear recency" button.
function Sparkline.clear()
  ensureLoaded()
  state.units = {}
  -- Keep nextOrdinal monotonic across a clear so any in-flight
  -- references in this session don't suddenly point past the end.
  dirty = true
end

-- Raw ordinal list (newest first) for a given title. Returns an
-- empty list (not nil) for unknown titles so callers can iterate
-- without guarding.
function Sparkline.ordinals(title)
  ensureLoaded()
  return state.units[title] or {}
end

-- Number of recorded uses for `title` within the last `window`
-- ordinals. Used by the picker's row-border intensity. Pass
-- math.huge for the total count.
function Sparkline.countWithin(title, window)
  ensureLoaded()
  local list = state.units[title]
  if list == nil then return 0 end
  local cutoff = state.nextOrdinal - window
  local n = 0
  for _, ord in ipairs(list) do
    if ord >= cutoff then n = n + 1 else break end  -- newest first
  end
  return n
end

-- Render a 5-char sparkline string for `title`.
function Sparkline.render(title)
  ensureLoaded()
  local list = state.units[title]
  if list == nil or #list == 0 then return "     " end
  local now = state.nextOrdinal
  local counts = { 0, 0, 0, 0, 0 }
  for _, ord in ipairs(list) do
    local delta = now - ord
    if delta < 0 then delta = 0 end
    for b = 1, 5 do
      if delta <= kBucketBounds[b] then
        counts[b] = counts[b] + 1
        break
      end
    end
  end
  local chars = {}
  for b = 1, 5 do
    local n = counts[b]
    chars[b] = kDensityChars[n] or kDensityChars[4]
  end
  return table.concat(chars)
end

return Sparkline

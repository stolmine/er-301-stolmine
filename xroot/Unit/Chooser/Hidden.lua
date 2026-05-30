-- Hidden-units persistence for the dense picker. Mirrors the
-- favorites file pattern in Default.lua: an in-memory hash plus a
-- dirty flag, persisted as ~/.od/rear/hidden.lua.
--
-- Hide by `title` rather than module id so the state survives
-- package version bumps (a renamed unit becomes visible again,
-- which matches user expectation).

local app = app
local Persist = require "Persist"

local Hidden = {}

local kHiddenPath = app.roots.rear .. "/hidden.lua"
local state       = nil   -- { hash = { [title] = true }, list = { titles... } }
local dirty       = false

local function ensureLoaded()
  if state ~= nil then return end
  local t = Persist.readTable(kHiddenPath)
  local list = (t and t.titles) or {}
  local hash = {}
  for _, title in ipairs(list) do hash[title] = true end
  state = { list = list, hash = hash }
end

function Hidden.isHidden(title)
  if title == nil or title == "" then return false end
  ensureLoaded()
  return state.hash[title] == true
end

-- Toggle hide for a title. Returns the new state (true = now hidden).
function Hidden.toggle(title)
  if title == nil or title == "" then return false end
  ensureLoaded()
  if state.hash[title] then
    state.hash[title] = nil
    for i, t in ipairs(state.list) do
      if t == title then
        table.remove(state.list, i)
        break
      end
    end
    dirty = true
    return false
  else
    state.hash[title] = true
    table.insert(state.list, title)
    dirty = true
    return true
  end
end

function Hidden.list()
  ensureLoaded()
  return state.list
end

function Hidden.clearAll()
  ensureLoaded()
  state.list = {}
  state.hash = {}
  dirty = true
end

function Hidden.flushIfDirty()
  if not dirty then return false end
  Persist.writeTable(kHiddenPath, { titles = state.list })
  dirty = false
  return true
end

return Hidden

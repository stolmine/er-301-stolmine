local app = app

-- [stol:ui-model-introspect]
-- EMULATION-only runtime UI introspection (ui-model plan, Layer 1).
--
-- Answers "describe the current UI + what gestures are available here" as a
-- deterministic, read-only snapshot, callable from the test harness via the
-- existing `lua` control command:
--
--   lua return require('emu.UIState').json()
--
-- returns ONE @-reply line of byte-deterministic JSON. No C++ bridge change is
-- needed: everything is reflected from the live Lua object graph the dispatcher
-- already walks. This module is pure-function/read-only -- it reflects
-- `obj[event] ~= nil` and reads geometry, it NEVER calls an event handler.
--
-- The reflection mirrors the real dispatch path exactly:
--   * current context   = Application:getVisibleContext()          (Application.lua notify)
--   * top window         = context:top()                            (Base/Context.lua:80)
--   * per-event focus    = window:getFocusedWidget(event)           (Base/Window.lua:77-79
--                          = focus.all or focus[event] or window)
--   * affordance walk    = context handler first, then the focus chain leaf->window
--                          (Base/Context.lua:226-235 notify + Base/Widget.lua:181-201
--                          sendUpHelper, which recurses self -> self.parent).
--   * M1..M6 slot map    = for MAIN button i, screen x = app.getButtonCenter(i)
--                          = (i-1)*43+20 (xroot/boot/app-setup.lua:20); the control
--                          under that column is resolved with the SAME C++ geometry
--                          the router uses in SpottedStrip:mainPressed
--                          (xroot/SpottedStrip/init.lua:212-221):
--                          findSectionByScreenLocation -> findSpotIdByScreenLocation
--                          -> Section:getControlFromSpotHandle. So `main<i>` reports
--                          the leaf control that a MAIN<i> press would route its
--                          spotPressed/spotReleased to -- the semantically meaningful
--                          affordance, not the always-present router on the window.
--
-- Anything the manifest sibling (Layer 2) publishes as a static affordance for a
-- screen must be a SUPERSET of what this returns live, so live gestures ⊆ manifest.

local UIState = {}

-- Hard EMULATION guard: on a hardware build this module is never required (the
-- control channel that reaches it is itself EMULATION-only), but keep the guard
-- explicit so an accidental require degrades to empty rather than reflecting.
if not app.EMULATION then
  function UIState.describe() return {} end
  function UIState.json() return "{}" end
  return UIState
end

-- ─────────────────────────── deterministic JSON ───────────────────────────
-- Tiny stdlib-only encoder. Object keys are SORTED; arrays keep index order.
-- Identical UI state -> byte-identical output (no dependence on pairs() order).

local function fmtNumber(n)
  if n ~= n then return "null" end                        -- NaN
  if n == math.huge or n == -math.huge then return "null" end
  if math.type and math.type(n) == "integer" then
    return string.format("%d", n)
  end
  if n == math.floor(n) and math.abs(n) < 1e15 then
    return string.format("%d", n)
  end
  return string.format("%.6g", n)
end

local escMap = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
  ['\b'] = '\\b',
  ['\f'] = '\\f'
}

local function escString(s)
  s = tostring(s):gsub('[%z\1-\31\\"]', function(c)
    return escMap[c] or string.format('\\u%04x', string.byte(c))
  end)
  return '"' .. s .. '"'
end

local function encode(v)
  local t = type(v)
  if v == nil then
    return "null"
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "number" then
    return fmtNumber(v)
  elseif t == "string" then
    return escString(v)
  elseif t == "table" then
    local n = #v
    local count = 0
    for _ in pairs(v) do count = count + 1 end
    if count == n then
      -- dense sequence -> JSON array (also covers the empty table -> [])
      local parts = {}
      for i = 1, n do parts[i] = encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      -- map -> JSON object with sorted keys
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      local parts = {}
      for _, k in ipairs(keys) do
        parts[#parts + 1] = escString(k) .. ":" .. encode(v[k])
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

-- ─────────────────────────── reflection helpers ───────────────────────────

local function className(o)
  if o and o.getClassName then
    local ok, n = pcall(o.getClassName, o)
    if ok and n then return n end
  end
  return tostring(o)
end

local function instanceName(o)
  if o and o.getInstanceName then
    local ok, n = pcall(o.getInstanceName, o)
    if ok and n ~= nil and n ~= "" then return n end
  end
  return nil
end

-- The focus chain for `event`, leaf -> window, matching Widget:sendUpHelper's
-- self -> self.parent recursion (Base/Widget.lua:181-201). The window is the top
-- (parent == nil). Guard against a broken/cyclic parent link.
local function focusChain(window, event)
  local chain = {}
  local w = window:getFocusedWidget(event)
  local guard = 0
  while w and guard < 64 do
    chain[#chain + 1] = w
    if w.isWindow then break end
    w = w.parent
    guard = guard + 1
  end
  return chain
end

-- Ordered list of objects that DEFINE a non-nil handler for `event`, in dispatch
-- order: context first (Context:notify checks self[e] before the focus chain),
-- then the focus chain leaf -> window. Read-only: only tests `[event] ~= nil`.
local function handlersFor(context, window, event)
  local out = {}
  if context[event] ~= nil then
    out[#out + 1] = { by = className(context), where = "context" }
  end
  for _, w in ipairs(focusChain(window, event)) do
    if w[event] ~= nil then
      out[#out + 1] = { by = className(w), where = "chain" }
    end
  end
  return out
end

-- Resolve the leaf control under MAIN button i on a SpottedStrip window using
-- the exact geometry the router uses. Returns (control, section) or nil.
local function slotControl(window, i)
  local pDisplay = window.pDisplay
  if not (pDisplay and pDisplay.findSectionByScreenLocation) then return nil end
  local x = app.getButtonCenter(i)
  local pSection = pDisplay:findSectionByScreenLocation(x)
  if not pSection then return nil end
  local sections = window.sections
  local section = sections and sections[pSection:handle()]
  if not section then return nil end
  local spotHandle = pSection:findSpotIdByScreenLocation(x)
  local ok, control = pcall(section.getControlFromSpotHandle, section,
                            section.currentViewName, spotHandle)
  if ok then return control, section end
  return nil
end

-- Best-effort, read-only current value of a control's primary readout. Many
-- ViewControls carry an app.Fader/Readout in `.fader` (or `.readout`) whose
-- value() is a cheap float. pcall-guarded; returns nil when not cheaply available.
local function readValue(control)
  local r = control.fader or control.readout
  if r and r.value then
    local ok, v = pcall(r.value, r)
    if ok and type(v) == "number" then return v end
  end
  return nil
end

-- Known modal flags, discovered generically by name across {context, window,
-- focus chain}. Best-effort -- a fixed, non-overfit list of the flags the fork's
-- terminal/exclusive modes actually set (verified via grep of self.<flag>).
local KNOWN_MODAL_FLAGS = {
  "editingL1",         -- Sequencer.GridView inline L1 cell edit (terminal modal)
  "bpmLatched",        -- Sequencer.GridView BPM latch (encoder owner)
  "markingMode",       -- Sequencer.GridView mark/select mode
  "selectionActive",   -- Sequencer.GridView active selection range
  "favoritesEditMode"  -- Unit.Chooser favorites-tagging mode
}

-- ─────────────────────────── gesture vocabulary ───────────────────────────
-- The SHARED §1 vocabulary. Non-indexed tokens map 1:1 to a notify event name.
local NONINDEXED = {
  "shiftPressed", "shiftReleased", "encoder",
  "upPressed", "upReleased", "upRepeated",
  "homePressed", "homeReleased", "homeRepeated",
  "zeroPressed", "zeroReleased", "zeroRepeated",
  "enterPressed", "enterReleased", "enterRepeated",
  "commitPressed", "commitReleased", "commitRepeated",
  "cancelPressed", "cancelReleased", "cancelRepeated",
  "dialPressed", "dialReleased", "dialRepeated"
}
-- Indexed families: {name, count, releaseEvent, pressEvent}. A hardware button
-- gesture is a press+release cycle, collapsed here to one bare token per index
-- (e.g. "main3"); the release handler is the activation seam so it is preferred.
local INDEXED = {
  { name = "main", count = 6, release = "mainReleased", press = "mainPressed" },
  { name = "sub", count = 3, release = "subReleased", press = "subPressed" },
  { name = "select", count = 4, release = "selectReleased", press = "selectPressed" }
}

-- ─────────────────────────── describe() ───────────────────────────

function UIState.describe()
  local Application = require "Application"
  local context = Application:getVisibleContext()
  local out = {
    context = {},
    stack = {},
    focus = {},
    controls = {},
    gestures = {},
    modals = {}
  }
  if not context then
    return out
  end

  out.context = {
    name = instanceName(context) or "",
    class = className(context)
  }

  -- stack: window classNames, top -> bottom
  local stack = context.stack or {}
  for i = #stack, 1, -1 do
    out.stack[#out.stack + 1] = className(stack[i])
  end

  local window = context:top()
  if not window then
    return out
  end

  -- focus: the canonical cursor focus (the "encoder" focus, which Context uses
  -- for the cursor controller) plus its full chain leaf -> window.
  local encChain = focusChain(window, "encoder")
  local focusLeaf = encChain[1]
  out.focus = {
    class = focusLeaf and className(focusLeaf) or "",
    name = (focusLeaf and instanceName(focusLeaf)) or "",
    chain = {}
  }
  for _, w in ipairs(encChain) do
    out.focus.chain[#out.focus.chain + 1] = className(w)
  end

  -- selection: the SpottedStrip cursor. For a chain/list window the sendUp focus
  -- above is always the window itself (SpottedStrip handles encoder at the window
  -- level), so the *selected* section+control is the real "what is focused here"
  -- signal -- e.g. which unit the cursor sits on. Read-only via getSelection.
  if window.getSelection then
    local ok, section, viewName, spotHandle = pcall(window.getSelection, window)
    if ok and section then
      local sel = {
        section = className(section),
        sectionName = instanceName(section) or "",
        view = viewName or ""
      }
      if section.getControlFromSpotHandle then
        local ok2, control = pcall(section.getControlFromSpotHandle, section,
                                   viewName, spotHandle)
        if ok2 and control then
          sel.control = className(control)
          sel.controlName = instanceName(control) or ""
        end
      end
      out.selection = sel
    end
  end

  -- controls: the leaf control under each MAIN column M1..M6 (SpottedStrip only).
  for i = 1, 6 do
    local control = slotControl(window, i)
    if control then
      local entry = {
        slot = "M" .. i,
        class = className(control),
        name = instanceName(control) or ""
      }
      local v = readValue(control)
      if v ~= nil then entry.value = v end
      out.controls[#out.controls + 1] = entry
    end
  end

  -- gestures: the affordance set. Sorted by token (string order) for determinism.
  local gestures = {}
  for _, event in ipairs(NONINDEXED) do
    local hs = handlersFor(context, window, event)
    local primary = hs[1]
    local chain = {}
    for _, h in ipairs(hs) do chain[#chain + 1] = h.by end
    gestures[#gestures + 1] = {
      token = event,
      handled = primary ~= nil,
      by = primary and primary.by or "",
      method = event,
      chain = chain
    }
  end
  for _, fam in ipairs(INDEXED) do
    for i = 1, fam.count do
      local token = fam.name .. i
      if fam.name == "main" then
        -- slot-aware: the control a MAIN<i> press routes to.
        local control = slotControl(window, i)
        if control then
          local method = (control.spotReleased ~= nil and "spotReleased") or
                         (control.spotPressed ~= nil and "spotPressed") or "spot"
          gestures[#gestures + 1] = {
            token = token,
            handled = control.spotReleased ~= nil or control.spotPressed ~= nil,
            by = className(control),
            method = method,
            slot = "M" .. i,
            chain = { className(control) }
          }
        else
          -- non-SpottedStrip window: fall back to the generic router affordance.
          local method = fam.release
          local hs = handlersFor(context, window, fam.release)
          if #hs == 0 then
            hs = handlersFor(context, window, fam.press)
            method = fam.press
          end
          local primary = hs[1]
          local chain = {}
          for _, h in ipairs(hs) do chain[#chain + 1] = h.by end
          gestures[#gestures + 1] = {
            token = token,
            handled = primary ~= nil,
            by = primary and primary.by or "",
            method = method,
            chain = chain
          }
        end
      else
        -- sub / select: generic reflection on the release then press method.
        local hs = handlersFor(context, window, fam.release)
        local method = fam.release
        if #hs == 0 then
          hs = handlersFor(context, window, fam.press)
          method = fam.press
        end
        local primary = hs[1]
        local chain = {}
        for _, h in ipairs(hs) do chain[#chain + 1] = h.by end
        gestures[#gestures + 1] = {
          token = token,
          handled = primary ~= nil,
          by = primary and primary.by or "",
          method = method,
          chain = chain
        }
      end
    end
  end
  table.sort(gestures, function(a, b) return a.token < b.token end)
  out.gestures = gestures

  -- modals: known flags that are truthy on context / window / focus chain.
  local scanned = { context, window }
  for _, w in ipairs(encChain) do scanned[#scanned + 1] = w end
  local active = {}
  for _, flag in ipairs(KNOWN_MODAL_FLAGS) do
    for _, o in ipairs(scanned) do
      if o[flag] then
        active[flag] = true
        break
      end
    end
  end
  local modalList = {}
  for flag in pairs(active) do modalList[#modalList + 1] = flag end
  table.sort(modalList)
  out.modals = modalList

  return out
end

-- ─────────────────────────── public API ───────────────────────────

function UIState.json()
  return encode(UIState.describe())
end

-- Convenience predicates for `!assert` (each returns a plain value the harness
-- can compare). All read-only, all derived from describe().

-- className of the leaf control at slot "M1".."M6" (or index 1..6), or "".
function UIState.controlClassAt(slot)
  if type(slot) == "number" then slot = "M" .. slot end
  for _, c in ipairs(UIState.describe().controls) do
    if c.slot == slot then return c.class end
  end
  return ""
end

function UIState.controlNameAt(slot)
  if type(slot) == "number" then slot = "M" .. slot end
  for _, c in ipairs(UIState.describe().controls) do
    if c.slot == slot then return c.name end
  end
  return ""
end

-- primary handler className for a gesture token, or "".
function UIState.gestureBy(token)
  for _, g in ipairs(UIState.describe().gestures) do
    if g.token == token then return g.by end
  end
  return ""
end

-- true iff `token`'s primary handler className contains `substr`.
function UIState.gestureHandledBy(token, substr)
  local by = UIState.gestureBy(token)
  return by ~= "" and by:find(substr, 1, true) ~= nil
end

-- className of the currently-selected control (the SpottedStrip cursor), or "".
function UIState.selectionControlClass()
  local sel = UIState.describe().selection
  return (sel and sel.control) or ""
end

-- className of the currently-selected section (e.g. the focused unit), or "".
function UIState.selectionSectionClass()
  local sel = UIState.describe().selection
  return (sel and sel.section) or ""
end

function UIState.topClass()
  local s = UIState.describe().stack
  return s[1] or ""
end

function UIState.focusClass()
  return UIState.describe().focus.class or ""
end

function UIState.contextName()
  return UIState.describe().context.name or ""
end

return UIState

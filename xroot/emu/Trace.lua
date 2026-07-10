local app = app

-- [stol:emu-ui-trace-hooks]
-- EMULATION-only UI trace. When enabled, wraps the already-centralized UI seams
-- (Application.setVisibleContext for context switches, Context:add/remove for
-- window stack push/pop) and emits one line per transition on the control-reply
-- channel:
--
--   @trace <frame> <kind> <detail>
--
-- kinds: context (show/hide + context instance name), push/pop (window class),
--        mark (script-injected label). The '@' sigil is added C++-side by
--        ctlReply; here we push the payload only.
--
-- This module is required only under app.EMULATION (Application.lua guards the
-- tick + the `trace` control command routes here), so hardware builds never load
-- it. Wrappers are installed only while enabled and restored on off(), so there
-- is zero cost when tracing is not running.

local Trace = {}

local enabled = false
local frame = 0
-- Which event categories to emit. Default = context + stack (window push/pop).
local want = { context = true, stack = true }
-- Saved originals for idempotent restore.
local saved = {}

local function emit(category, kind, detail)
  if not (enabled and want[category]) then
    return
  end
  if detail and detail ~= "" then
    emu.pushControlReply(string.format("trace %d %s %s", frame, kind, detail))
  else
    emu.pushControlReply(string.format("trace %d %s", frame, kind))
  end
end

-- Called once per rendered frame from Application.onDisplayReady (under
-- app.EMULATION). Advances the frame stamp used to correlate trace regions with
-- the harness `frames` gate. Cheap enough to run unconditionally.
function Trace.tick()
  frame = frame + 1
end

function Trace.frame()
  return frame
end

-- Script-injected marker. Emitted regardless of the `want` filter (a mark is
-- always intentional) but only while tracing is enabled.
function Trace.mark(label)
  if not enabled then
    return
  end
  emu.pushControlReply(string.format("trace %d mark %s", frame, label or ""))
  return "mark " .. tostring(label)
end

local function install()
  local Application = require "Application"
  local Context = require "Base.Context"

  saved.setVisibleContext = Application.setVisibleContext
  Application.setVisibleContext = function(context)
    local prev = Application.getVisibleContext()
    saved.setVisibleContext(context)
    if context ~= prev then
      if prev then
        emit("context", "context", "hide " .. tostring(prev:getInstanceName()))
      end
      if context then
        emit("context", "context", "show " .. tostring(context:getInstanceName()))
      end
    end
  end

  saved.add = Context.add
  Context.add = function(self, window)
    saved.add(self, window)
    emit("stack", "push", window:getClassName())
  end

  saved.remove = Context.remove
  Context.remove = function(self, window)
    -- Context:remove refuses to pop the last window; mirror that so the trace
    -- reflects an actual stack change, not a rejected request.
    local popped = #self.stack >= 2 and self:getStackIndex(window) ~= nil
    saved.remove(self, window)
    if popped then
      emit("stack", "pop", window:getClassName())
    end
  end
end

local function restore()
  local Application = require "Application"
  local Context = require "Base.Context"
  if saved.setVisibleContext then
    Application.setVisibleContext = saved.setVisibleContext
  end
  if saved.add then
    Context.add = saved.add
  end
  if saved.remove then
    Context.remove = saved.remove
  end
  saved = {}
end

-- Enable tracing. `filter` is an optional comma-separated category list
-- ("context", "stack"); empty/nil means the default context+stack set.
-- Idempotent: re-enabling only updates the filter, never double-wraps.
function Trace.on(filter)
  if filter and filter ~= "" then
    want = {}
    for tok in string.gmatch(filter, "[^,]+") do
      want[tok] = true
    end
  else
    want = { context = true, stack = true }
  end
  if not enabled then
    install()
    enabled = true
  end
  return "trace on"
end

function Trace.off()
  if enabled then
    restore()
    enabled = false
  end
  return "trace off"
end

function Trace.isEnabled()
  return enabled
end

return Trace

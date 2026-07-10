local Card = require "Card"

-- Crash-report schema v2. This module owns the shared crash.log FORMAT (the
-- contract in docs/CRASH_REPORT_FORMAT.md that both the emu injector and, on
-- hardware, the sibling's ARM exception-hook flush honor), plus the emu-only
-- synthetic injector and the on-boot "a crash was captured" detection.
--
-- The block extends the pre-schema crash.log format written by xroot/Crash.lua:
-- the old "Firmware Version:", "Boot Count:", "Mount Count:", "Error Message:"
-- and "Recent Log Messages:" labels are preserved so existing readers still cope,
-- with the new Schema/Kind/Registers/Module Map/Fault Resolution/Flight Recorder
-- sections added around them.

local M = {}

local BEGIN = "---CRASH REPORT BEGIN"
local ENDER = "---CRASH REPORT END"

local function crashLogPath()
  return app.roots.front .. "/crash.log"
end

local function pendingPath()
  return app.roots.front .. "/crash.pending"
end

local function persistMeta()
  local ok, Persist = pcall(require, "Persist")
  if ok and Persist and Persist.meta then
    return Persist.meta
  end
  return nil
end

--------------------------------------------------------------------------------
-- Module-map parsing + on-device best-effort fault resolution.
--------------------------------------------------------------------------------

-- Parse the body produced by app.getModuleMap() into a list of relocatable
-- modules { path, lo, hi }. Entries with "text=0" (a non-relocated kernel) are
-- skipped: their PCs map directly onto the kernel .elf for addr2line.
function M.parseModuleMap(text)
  local mods = {}
  if not text then return mods end
  for line in text:gmatch("[^\n]+") do
    local path, lo, hi = line:match("^%s*(%S+)%s+text=(%x+)%.%.(%x+)")
    if path and lo and hi then
      mods[#mods + 1] = {
        path = path,
        lo = tonumber(lo, 16),
        hi = tonumber(hi, 16)
      }
    end
  end
  return mods
end

-- addr is a hex string ("0x40012abc" or "40012abc"). Returns "<pkg> + <off>" or
-- "?" if it lands in no relocated module.
function M.resolveAddress(addr, mods)
  if not addr then return "?" end
  local hex = addr:gsub("^0[xX]", "")
  local n = tonumber(hex, 16)
  if not n then return "?" end
  for _, m in ipairs(mods) do
    if n >= m.lo and n < m.hi then
      return string.format("%s + 0x%x", m.path, n - m.lo)
    end
  end
  return "?"
end

--------------------------------------------------------------------------------
-- The schema-v2 writer (shared contract).
--------------------------------------------------------------------------------

-- fields:
--   kind          data-abort | prefetch-abort | undef | lua | hang-watchdog
--   thread        "audio" | "ui" | <name>            (default "?")
--   registerLines array of preformatted register lines (C-side kinds), or nil
--   pc, lr        hex strings for Fault Resolution, or nil
--   luaMessage    Lua error message, or nil
--   luaTrace      Lua traceback, or nil
function M.write(fields)
  fields = fields or {}
  if not Card.mounted() then
    return false
  end
  local f = io.open(crashLogPath(), "a+")
  if not f then
    app.logError("CrashReport: failed to open crash.log for append.")
    return false
  end

  -- [stol:infra-crash-diag-format] schema-writer seam.
  f:write(BEGIN, "\n")
  f:write("Schema: 2\n")
  f:write(string.format("Kind: %s\n", fields.kind or "unknown"))
  f:write(string.format("Time Since Boot: %0.3fs\n", app.wallclock()))

  local meta = persistMeta()
  local boot = meta and meta.boot
  local mount = meta and meta.mount
  f:write(string.format("Firmware Version: %s\n",
                        (boot and boot.firmwareVersion) or app.FIRMWARE_VERSION))
  f:write(string.format("Boot Count: %d\n", (boot and boot.count) or 0))
  f:write(string.format("Mount Count: %d\n", (mount and mount.count) or 0))
  f:write(string.format("Thread: %s\n", fields.thread or "?"))

  -- Registers (C-side kinds only).
  if fields.registerLines and #fields.registerLines > 0 then
    f:write("--- Registers ---\n")
    for _, line in ipairs(fields.registerLines) do
      f:write(line, "\n")
    end
  end

  -- Module Map (kernel base + every loaded package).
  f:write("--- Module Map ---\n")
  local mapText = ""
  local ok, res = pcall(app.getModuleMap)
  if ok and res then
    mapText = res
    f:write(res)
  end

  -- Fault Resolution (best-effort on-device symbol-free lookup).
  if fields.pc or fields.lr then
    f:write("--- Fault Resolution ---\n")
    local mods = M.parseModuleMap(mapText)
    if fields.pc then
      f:write(string.format(" pc in %s\n", M.resolveAddress(fields.pc, mods)))
    end
    if fields.lr then
      f:write(string.format(" lr in %s\n", M.resolveAddress(fields.lr, mods)))
    end
  end

  -- Flight Recorder (ring of recent trigger events).
  f:write("--- Flight Recorder ---\n")
  local frOk, frText = pcall(app.flightRecorderText)
  if frOk and frText and frText ~= "" then
    f:write(frText)
  else
    f:write(" (empty)\n")
  end

  -- Lua (message + traceback if a Lua error). Old-reader-compatible labels.
  if fields.luaMessage then
    f:write("--- Lua ---\n")
    f:write("Error Message:\n")
    f:write(fields.luaMessage, "\n")
    if fields.luaTrace then
      f:write(fields.luaTrace, "\n")
    end
  end

  -- Recent Log (LogHistory ring, as today). Old-reader-compatible label.
  f:write("--- Recent Log ---\n")
  f:write("Recent Log Messages:\n")
  local lhOk, LogHistory = pcall(require, "LogHistory")
  if lhOk and LogHistory then
    local count = LogHistory:count()
    for i = 1, count do
      f:write(LogHistory:get(i), "\n")
    end
  end

  f:write(ENDER, "\n")
  f:close()
  app.logInfo("CrashReport: schema-v2 report appended to crash.log.")
  return true
end

--------------------------------------------------------------------------------
-- Pending-crash marker (drives the on-boot notice). The emu injector and the
-- hardware panic-buffer flush both drop this marker; the on-boot check consumes
-- it and the user dismisses it.
--------------------------------------------------------------------------------

function M.setPending(summary)
  local f = io.open(pendingPath(), "w")
  if f then
    f:write(summary or "A crash was captured.", "\n")
    f:close()
    return true
  end
  return false
end

function M.hasPending()
  return app.pathExists(pendingPath())
end

function M.readPending()
  local f = io.open(pendingPath(), "r")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  return line
end

function M.clearPending()
  if M.hasPending() then
    return app.deleteFile(pendingPath())
  end
  return true
end

--------------------------------------------------------------------------------
-- Report parsing (for the admin viewer).
--------------------------------------------------------------------------------

-- Returns an array of { summary=<string>, lines={...} }, oldest first. Handles
-- both schema-v2 blocks and pre-schema blocks (same BEGIN/END delimiters).
function M.parseReports()
  local reports = {}
  local f = io.open(crashLogPath(), "r")
  if not f then return reports end
  local cur = nil
  for line in f:lines() do
    if line == BEGIN then
      cur = { summary = nil, lines = {} }
    elseif line == ENDER then
      if cur then
        if not cur.summary then cur.summary = "crash report" end
        reports[#reports + 1] = cur
        cur = nil
      end
    elseif cur then
      cur.lines[#cur.lines + 1] = line
      -- Build a compact summary from the most informative fields.
      local kind = line:match("^Kind:%s*(.+)")
      if kind then
        cur.kind = kind
      end
      local t = line:match("^Time Since Boot:%s*(.+)")
      if t then
        cur.time = t
      end
      if cur.kind and cur.time then
        cur.summary = string.format("%s @ %s", cur.kind, cur.time)
      elseif cur.kind then
        cur.summary = cur.kind
      end
    end
  end
  f:close()
  return reports
end

-- Erase the whole crash.log (used by the viewer's Clear command).
function M.clearAll()
  if app.pathExists(crashLogPath()) then
    app.deleteFile(crashLogPath())
  end
  M.clearPending()
end

--------------------------------------------------------------------------------
-- Emu-only synthetic injector: drops a canned schema-v2 report + pending marker
-- so the presentation half is testable without a real hardware trap.
--------------------------------------------------------------------------------

-- [stol:infra-crash-diag-emu-inject]
function M.injectSynthetic(kind)
  if not app.EMULATION then
    app.logWarn("CrashReport.injectSynthetic ignored: not EMULATION.")
    return false
  end
  kind = kind or "data-abort"
  local registerLines = {
    " pc=40012abc lr=40012a00 sp=4fff0100 psr=60000013",
    " dfsr=00000805 ifsr=00000000 dfar=deadbeef ifar=00000000",
    " r0=00000001 r1=00000002 r2=00000003 r3=00000004",
    " r4=00000005 r5=00000006 r6=00000007 r7=00000008",
    " r8=00000009 r9=0000000a r10=0000000b r11=0000000c r12=0000000d"
  }
  local ok = M.write {
    kind = kind,
    thread = "audio",
    registerLines = registerLines,
    pc = "40012abc",
    lr = "40012a00"
  }
  M.setPending(string.format("%s in audio thread", kind))
  return ok
end

--------------------------------------------------------------------------------
-- On-boot notice + viewer entry points.
--------------------------------------------------------------------------------

function M.showBootNotice(summary)
  local Message = require "Message"
  local dlg = Message.Main("A crash was captured.", "See Admin > Crash Reports.")
  dlg:subscribe("done", function()
    M.clearPending()
  end)
  dlg:show()
  return dlg
end

-- Called from Application.init. Shows the notice iff a pending marker exists.
function M.checkPendingOnBoot()
  if not M.hasPending() then
    return false
  end
  local summary = M.readPending()
  app.logInfo("CrashReport: pending crash on boot (%s).", summary or "?")
  M.showBootNotice(summary)
  return true
end

function M.showViewer()
  local Viewer = require "CrashReportViewer"
  Viewer:show()
  return Viewer
end

return M

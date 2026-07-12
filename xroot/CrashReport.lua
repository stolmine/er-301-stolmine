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
--   stackWindowLines array of preformatted Stack Window lines (hang kind), or nil
--   stackBannerLines array of top-of-report banner lines (blown/near-full), or nil
--   stackLines    array of preformatted "--- Stacks ---" section lines, or nil
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
  -- [stol:crashdiag-stack-highwater] Prime-suspect banner near the TOP (right
  -- after Kind), matching the C flush, so a blown / near-full stack is unmissable.
  if fields.stackBannerLines and #fields.stackBannerLines > 0 then
    for _, line in ipairs(fields.stackBannerLines) do
      f:write(line, "\n")
    end
  end
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

  -- [stol:crashdiag-stack-highwater] Stacks section (per-task + ISR high-water /
  -- canary). Present for both trap and hang captures on hardware. The C flush
  -- emits this after Fault Resolution; mirror that order here.
  if fields.stackLines and #fields.stackLines > 0 then
    f:write("--- Stacks ---\n")
    for _, line in ipairs(fields.stackLines) do
      f:write(line, "\n")
    end
  end

  -- [stol:crashdiag-object-guard-event] Event Guard section (event-guard-breach
  -- kind only): the corrupted audio pendQ header + links + reason. The C flush
  -- emits this after the Stacks section; mirror that order here.
  if fields.eventGuardLines and #fields.eventGuardLines > 0 then
    f:write("--- Event Guard ---\n")
    for _, line in ipairs(fields.eventGuardLines) do
      f:write(line, "\n")
    end
  end

  -- [stol:crashdiag-hang-spin-pc] Hang State (hang kind only): running (spin) =>
  -- sp is the live interrupted SP; blocked => sp is the saved block site.
  if fields.hangState then
    f:write(string.format("Hang State: %s\n", fields.hangState))
  end

  -- Stack Window (hang-watchdog captures only; the C flush emits this from the
  -- hung task's raw stack. Address-prefixed hex, 4 words/line, innermost-first.
  -- See docs/CRASH_REPORT_FORMAT.md).
  if fields.stackWindowLines and #fields.stackWindowLines > 0 then
    f:write("--- Stack Window ---\n")
    for _, line in ipairs(fields.stackWindowLines) do
      f:write(line, "\n")
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

-- [stol:infra-crash-diag-hang-watchdog] Synthetic HANG record: no ExcContext, so
-- registers are best-effort (pc=0, a plausible sp) and the backtrace load is
-- carried by a canned Stack Window in the C flush's exact format. Exercises the
-- format + viewer + symbolizer stack-scan without a real hardware hang.
local function injectSyntheticHang()
  local registerLines = {
    " pc=00000000 lr=00000000 sp=9ffe0100 psr=00000000",
    " dfsr=00000000 ifsr=00000000 dfar=00000000 ifar=00000000",
    " r0=00000000 r1=00000000 r2=00000000 r3=00000000",
    " r4=00000000 r5=00000000 r6=00000000 r7=00000000",
    " r8=00000000 r9=00000000 r10=00000000 r11=00000000 r12=00000000"
  }
  -- Canned stack window (address-prefixed hex, 4 words/line). The synthetic
  -- addresses do not resolve against the emu module map, but they prove the
  -- section renders + parses; the symbolizer selftest uses its own in-range
  -- fixture to prove the .text scan.
  local stackWindowLines = {
    " sp=9ffe0100 bytes=64",
    " 9ffe0100: 80012abc 00000000 9ffe0140 80013344",
    " 9ffe0110: 00000000 40012a00 9ffe0180 80014400",
    " 9ffe0120: deadbeef 00000000 9ffe01c0 80010080",
    " 9ffe0130: 00000000 00000000 9ffe0200 8001aabb"
  }
  local ok = M.write {
    kind = "hang-watchdog",
    thread = "audio",
    registerLines = registerLines,
    pc = "00000000",
    lr = "00000000",
    hangState = "running (spin)",
    stackWindowLines = stackWindowLines
  }
  M.setPending("hang-watchdog in audio thread")
  return ok
end

-- [stol:crashdiag-stack-highwater] Synthetic report carrying a --- Stacks ---
-- section with one task (MAIN) overflowed (canary BLOWN, 100%) plus a near-full
-- DISPLAY task, a healthy audio task, and a healthy ISR stack. Exercises the
-- banner + Stacks format + viewer without hardware (the real per-task numbers
-- only exist on am335x). The Kind stays data-abort: on the frozen Anamnesis case
-- the stack blows and THEN traps, so a blown-stack report is a data-abort with a
-- Stacks section, which is exactly what this canned block models.
local function injectSyntheticStacks()
  local registerLines = {
    " pc=800014d0 lr=00001200 sp=4fff0100 psr=60000013",
    " dfsr=00000805 ifsr=00000000 dfar=4fff0000 ifar=00000000",
    " r0=00000001 r1=00000002 r2=00000003 r3=00000004",
    " r4=00000005 r5=00000006 r6=00000007 r7=00000008",
    " r8=00000009 r9=0000000a r10=0000000b r11=0000000c r12=0000000d"
  }
  local stackBannerLines = {
    " *** STACK MAIN BLOWN ***",
    " *** STACK DISPLAY NEAR-FULL (96%) ***"
  }
  local stackLines = {
    " MAIN            base=4fff0000 size=8192 used=8192 (100%) canary=BLOWN",
    " DISPLAY         base=4ffee000 size=8192 used=7900 (96%) canary=ok",
    " audio           base=4ffd0000 size=16384 used=6000 (36%) canary=ok",
    " isr             base=4001f000 size=4096 used=800 (19%) canary=ok"
  }
  local ok = M.write {
    kind = "data-abort",
    thread = "MAIN",
    registerLines = registerLines,
    pc = "800014d0",
    lr = "00001200",
    stackBannerLines = stackBannerLines,
    stackLines = stackLines
  }
  M.setPending("data-abort in MAIN (stack MAIN BLOWN)")
  return ok
end

-- [stol:crashdiag-object-guard-event] Synthetic audio-Event pend-queue guard
-- breach: the audio ISR caught the pendQ sentinel clobbered (next near-null)
-- BEFORE Event_post would trap, so this is a deferred-corruption capture. The
-- registers are best-effort (pc=0, lr=the ISR detection site); the load-bearing
-- signal is the --- Event Guard --- section (+ the top-of-report banner). The
-- per-breach CAPTURE only exists on am335x; this exercises the format + viewer +
-- symbolizer downstream of the panic buffer.
local function injectSyntheticGuard()
  local registerLines = {
    " pc=00000000 lr=803a1000 sp=00000000 psr=00000000",
    " dfsr=00000000 ifsr=00000000 dfar=00000000 ifar=00000000",
    " r0=00000000 r1=00000000 r2=00000000 r3=00000000",
    " r4=80538150 r5=80538154 r6=00000000 r7=00000000",
    " r8=49002070 r9=00000000 r10=00000000 r11=00000000 r12=00000000"
  }
  local stackBannerLines = {
    " *** EVENT GUARD BREACH (audio pendQ corrupted) ***"
  }
  -- next clobbered to a near-null value (the Anamnesis fingerprint); prev intact.
  local eventGuardLines = {
    " pendQ=80538380 next=00000062 prev=80538380 reason=05",
    " reason: next-badptr next-link"
  }
  local ok = M.write {
    kind = "event-guard-breach",
    thread = "audio",
    registerLines = registerLines,
    pc = "00000000",
    lr = "803a1000",
    stackBannerLines = stackBannerLines,
    eventGuardLines = eventGuardLines
  }
  M.setPending("event-guard-breach in audio (pendQ corrupted)")
  return ok
end

-- [stol:infra-crash-diag-emu-inject]
function M.injectSynthetic(kind)
  if not app.EMULATION then
    app.logWarn("CrashReport.injectSynthetic ignored: not EMULATION.")
    return false
  end
  kind = kind or "data-abort"
  if kind == "hang-watchdog" then
    return injectSyntheticHang()
  end
  if kind == "stacks" then
    return injectSyntheticStacks()
  end
  if kind == "event-guard-breach" then
    return injectSyntheticGuard()
  end
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

local Card = require "Card"

-- [stol:infra-crash-diag-format] The Lua error path now writes a schema-v2 crash
-- report via the shared CrashReport writer (kind = "lua"). The v2 block keeps the
-- old "Firmware Version:/Boot Count:/Mount Count:/Error Message:/Recent Log
-- Messages:" labels so pre-schema readers still cope, while gaining the shared
-- Module Map + Flight Recorder sections that the C-side hardware capture also
-- emits. See docs/CRASH_REPORT_FORMAT.md.
local function saveCrashReport(msg, trace)
  local CrashReport = require "CrashReport"
  local ok, reportSaved = pcall(CrashReport.write, {
    kind = "lua",
    thread = "ui",
    luaMessage = msg,
    luaTrace = trace
  })
  if ok and reportSaved then
    print("Crash report appended to 'crash.log'.")
    return true
  end
  print("Failed to write 'crash.log'.")
  return false
end

local function showDialog(reportSaved)
  local app = app
  local Message = require "Message"
  local Overlay = require "Overlay"
  local Busy = require "Busy"
  local dialog = Message.Sub("Reboot required.", "", true)

  if reportSaved then
    local label = app.Label("Oops! Something went wrong.", 12)
    label:setCenter(128, app.GRID4_LINE1)
    dialog:addMainGraphic(label)
    label = app.Label("Report saved to crash.log. Please send the report to:",
                      10)
    label:setCenter(128, app.GRID4_LINE2)
    dialog:addMainGraphic(label)
    label = app.Label("clarkson@orthogonaldevices.com", 10)
    label:setCenter(128, app.GRID4_LINE3)
    dialog:addMainGraphic(label)
  else
    local label = app.Label("Oops! Something went wrong.", 12)
    label:setCenter(128, app.GRID4_LINE1)
    dialog:addMainGraphic(label)
    label = app.Label("No card present to save the crash report.", 10)
    label:setCenter(128, app.GRID4_LINE2)
    dialog:addMainGraphic(label)
  end

  Busy.reset()
  Overlay.clearAll()
  local Context = require "Base.Context"
  local context = Context("Crash", dialog)
  context:show()

  app.logInfo("start: entering CRASH event loop.")
  Card.forceEject()
  while true do
    app.Events_wait()
    while true do
      local event = app.Events_pull()
      if event == app.EVENT_NONE then
        break
      elseif event == app.EVENT_DISPLAY_READY then
        app.UIThread.updateDisplay()
      elseif event == app.EVENT_RELEASE_SUB1 then
        app.reboot()
      elseif event == app.EVENT_RELEASE_SUB2 then
        app.reboot()
      elseif event == app.EVENT_RELEASE_SUB3 then
        app.reboot()
      elseif event == app.EVENT_RELEASE_ENTER then
        app.reboot()
      end
    end
  end
  return true
end

local function onError(msg, trace)
  local reportSaved = saveCrashReport(msg, trace)
  showDialog(reportSaved)
end

local function init()
  app.onErrorHook = onError
end

return {init = init}

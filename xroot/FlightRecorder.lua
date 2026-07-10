-- [stol:infra-crash-diag-flight-recorder]
-- Thin Lua wrapper over the C flight-recorder ring (od/extras/FlightRecorder,
-- exposed as app.flightRecord* by od/glue/CrashDiag.cpp). The ring lives in C so
-- the sibling's ARM exception hook can read it from an abort context. Recording
-- is gated in C by the armed flag (wired to the enableCrashDiagnostics setting),
-- so record() is a no-op branch when diagnostics are off -- zero cost when off.

local M = {}

function M.record(label)
  app.flightRecord(label or "")
end

function M.arm(on)
  app.flightRecorderArm(on and true or false)
end

function M.armed()
  return app.flightRecorderArmed()
end

function M.count()
  return app.flightRecorderCount()
end

function M.text()
  return app.flightRecorderText()
end

function M.clear()
  app.flightRecorderClear()
end

return M

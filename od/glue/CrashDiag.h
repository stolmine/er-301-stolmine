#pragma once

// [stol:infra-crash-diag-module-map][stol:infra-crash-diag-flight-recorder]
// Registers the crash-diagnostics accessors into the Lua `app` table:
//   app.getModuleMap()          -> formatted Module Map section body (string)
//   app.flightRecorderArm(on)   -> arm/disarm the flight recorder ring
//   app.flightRecorderArmed()   -> bool
//   app.flightRecord(label)     -> append an event (ignored when disarmed)
//   app.flightRecorderCount()   -> number of events held
//   app.flightRecorderText()    -> formatted Flight Recorder section body (string)
//   app.flightRecorderClear()   -> drop all events
//
// Registered from od::AppInterpreter::init after luaopen_app, so it is present in
// both the emu and am335x firmware builds without touching the SWIG surface.

struct lua_State;

namespace od
{
  void registerCrashDiag(lua_State *L);
}

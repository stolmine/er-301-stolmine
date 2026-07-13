// [stol:infra-crash-diag-module-map][stol:infra-crash-diag-flight-recorder]
#include <od/glue/CrashDiag.h>
#include <od/extras/FlightRecorder.h>
#include <hal/modulemap.h>
#include <hal/crash.h>

#include <string>
#include <vector>
#include <stdio.h>

extern "C"
{
#include "lua.h"
#include "lauxlib.h"
}

// [stol:infra-crash-diag-hang-watchdog] Weak no-op default for the hang-monitor
// arm hook. The am335x monitor (arch/am335x/hal/crash/HangWatchdog.cpp) provides
// the strong override; on builds without it (the emu, which has no hang capture)
// this no-op is linked so the shared arm choke point below always resolves.
extern "C" __attribute__((weak)) void Crash_hangArm(bool on)
{
  (void)on;
}

// [stol:crashdiag-ui-heartbeat] Weak no-op default for the UI heartbeat, mirroring
// the Crash_hangArm weak default above. The am335x HangWatchdog provides the strong
// override; the emu (no hang capture) links this no-op so app.uiHeartbeat is inert.
extern "C" __attribute__((weak)) void Crash_uiHeartbeat(bool busy)
{
  (void)busy;
}

// [stol:crashdiag-ui-heartbeat] Weak no-op default for the UI-hang opt-in (option
// c). The am335x HangWatchdog provides the strong override; the emu links this
// no-op so app.uiHangArm is inert.
extern "C" __attribute__((weak)) void Crash_uiHangArm(bool on)
{
  (void)on;
}

namespace
{
  // app.getModuleMap() -> one line per module:
  //   "<path>  text=<base>..<end>  data=<base>..<end>"
  // Bases are hex; a zero/unknown extent is rendered as "?".
  int l_getModuleMap(lua_State *L)
  {
    std::vector<od::ModuleInfo> mods;
    od::enumerateModules(mods);

    std::string out;
    char line[256];
    for (auto &m : mods)
    {
      char textPart[64];
      char dataPart[64];
      if (m.textSize > 0)
      {
        snprintf(textPart, sizeof(textPart), "text=%08llx..%08llx",
                 (unsigned long long)m.textBase,
                 (unsigned long long)(m.textBase + m.textSize));
      }
      else if (m.textBase != 0)
      {
        snprintf(textPart, sizeof(textPart), "text=%08llx..?",
                 (unsigned long long)m.textBase);
      }
      else
      {
        snprintf(textPart, sizeof(textPart), "text=0");
      }
      if (m.dataSize > 0)
      {
        snprintf(dataPart, sizeof(dataPart), "  data=%08llx..%08llx",
                 (unsigned long long)m.dataBase,
                 (unsigned long long)(m.dataBase + m.dataSize));
      }
      else
      {
        dataPart[0] = '\0';
      }
      snprintf(line, sizeof(line), " %-24s %s%s\n", m.path.c_str(), textPart,
               dataPart);
      out += line;
    }
    lua_pushstring(L, out.c_str());
    return 1;
  }

  int l_flightRecorderArm(lua_State *L)
  {
    bool on = lua_toboolean(L, 1) != 0;
    od::flightRecorder().arm(on);
    // [stol:infra-crash-diag-hang-watchdog] Same choke point arms the hang
    // monitor (real hardware arm path from the enableCrashDiagnostics setting),
    // so the Clock monitor exists exactly when diagnostics are armed. No-op on
    // the emu (weak default above).
    Crash_hangArm(on);
    return 0;
  }

  int l_flightRecorderArmed(lua_State *L)
  {
    lua_pushboolean(L, od::flightRecorder().armed() ? 1 : 0);
    return 1;
  }

  int l_flightRecord(lua_State *L)
  {
    const char *label = luaL_optstring(L, 1, "");
    od::flightRecorder().record(label);
    return 0;
  }

  // [stol:crashdiag-ui-heartbeat] app.uiHeartbeat(busy): the Lua main loop marks
  // itself busy (processing a handler/draw/trigger) or idle (about to block in
  // waitForEvent). Feeds the UI half of the am335x hang monitor; no-op on the emu.
  int l_uiHeartbeat(lua_State *L)
  {
    Crash_uiHeartbeat(lua_toboolean(L, 1) != 0);
    return 0;
  }

  // [stol:crashdiag-ui-heartbeat] app.uiHangArm(on): the separate UI-hang opt-in
  // (option c), driven by the enableUiHangDetection setting. Off by default; the
  // general "Enable crash diagnostics?" toggle does NOT set it.
  int l_uiHangArm(lua_State *L)
  {
    Crash_uiHangArm(lua_toboolean(L, 1) != 0);
    return 0;
  }

  int l_flightRecorderCount(lua_State *L)
  {
    lua_pushinteger(L, od::flightRecorder().count());
    return 1;
  }

  // app.flightRecorderText() -> one line per event:
  //   " <t>s  <label>"
  int l_flightRecorderText(lua_State *L)
  {
    od::FlightRecorder &fr = od::flightRecorder();
    std::string out;
    char line[128];
    int n = fr.count();
    for (int i = 0; i < n; i++)
    {
      const od::FlightRecorder::Event *e = fr.at(i);
      if (!e)
      {
        continue;
      }
      snprintf(line, sizeof(line), " %8.3fs  %s\n", (double)e->timestamp,
               e->label);
      out += line;
    }
    lua_pushstring(L, out.c_str());
    return 1;
  }

  int l_flightRecorderClear(lua_State *L)
  {
    (void)L;
    od::flightRecorder().clear();
    return 0;
  }

  const luaL_Reg kFuncs[] = {
      {"getModuleMap", l_getModuleMap},
      {"flightRecorderArm", l_flightRecorderArm},
      {"flightRecorderArmed", l_flightRecorderArmed},
      {"flightRecord", l_flightRecord},
      // [stol:crashdiag-ui-heartbeat] UI heartbeat producer for the hang monitor.
      {"uiHeartbeat", l_uiHeartbeat},
      {"uiHangArm", l_uiHangArm},
      {"flightRecorderCount", l_flightRecorderCount},
      {"flightRecorderText", l_flightRecorderText},
      {"flightRecorderClear", l_flightRecorderClear},
      {nullptr, nullptr}};
}

namespace od
{
  void registerCrashDiag(lua_State *L)
  {
    lua_getglobal(L, "app");
    if (!lua_istable(L, -1))
    {
      lua_pop(L, 1);
      return;
    }
    for (const luaL_Reg *f = kFuncs; f->name; f++)
    {
      lua_pushcfunction(L, f->func);
      lua_setfield(L, -2, f->name);
    }
    lua_pop(L, 1); // pop app table
  }
}

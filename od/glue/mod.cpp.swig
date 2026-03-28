// Import this at the beginning of mods.

%import <od/glue/prologue.cpp.swig>

%{
#pragma GCC diagnostic ignored "-Wmaybe-uninitialized"

#undef SWIGLUA


#include <od/extras/ReferenceCounted.h>
#include <od/extras/Lockable.h>

#include <od/audio/Sample.h> 
#include <od/audio/Slices.h> 

#include <od/objects/Object.h>  
#include <od/objects/heads/Head.h> 
#include <od/objects/heads/TapeHead.h>
#include <od/objects/heads/SliceHead.h> 

#include <od/tasks/Task.h> 

#include <od/graphics/Graphic.h> 
#include <od/graphics/sampling/HeadDisplay.h> 
#include <od/graphics/sampling/TapeHeadDisplay.h> 
#include <od/graphics/sampling/SliceHeadDisplay.h> 

#define SWIGLUA
%}

%import(module="app") <od/extras/ReferenceCounted.h>
%import(module="app") <od/extras/Lockable.h>

%import(module="app") <od/audio/Sample.h> 
%import(module="app") <od/audio/Slices.h> 

%import(module="app") <od/objects/Port.h>
%import(module="app") <od/objects/Inlet.h>
%import(module="app") <od/objects/Outlet.h>
%import(module="app") <od/objects/Followable.h>
%import(module="app") <od/objects/Parameter.h>
%import(module="app") <od/objects/Option.h>
%import(module="app") <od/objects/StateMachine.h>
%import(module="app") <od/objects/Object.h> 

%import(module="app") <od/objects/Object.h>  
%import(module="app") <od/objects/heads/Head.h> 
%import(module="app") <od/objects/heads/TapeHead.h>
%import(module="app") <od/objects/heads/SliceHead.h> 

%import(module="app") <od/units/Unit.h>

%import(module="app") <od/tasks/Task.h> 

%import(module="app") <od/graphics/Graphic.h> 
%import(module="app") <od/graphics/sampling/HeadDisplay.h> 
%import(module="app") <od/graphics/sampling/TapeHeadDisplay.h> 
%import(module="app") <od/graphics/sampling/SliceHeadDisplay.h>

%{
#include <string.h>
%}

%init %{
  /* SWIG Runtime Version Bridge (mod side)
   *
   * When this package loads on a firmware built with a different SWIG
   * version, the type tables use different Lua registry keys. This
   * bridge aliases the type table under all known runtime version keys
   * so that this package's types are visible to all other modules
   * regardless of their SWIG version.
   *
   * Combined with the same bridge in the kernel's app module, this
   * ensures bidirectional type compatibility: packages built with this
   * SDK work on vanilla firmware, and vanilla packages work on this
   * firmware.
   */
  {
    static const char *swig_runtime_keys[] = {
      "swig_runtime_data_type_pointer3",
      "swig_runtime_data_type_pointer4",
      "swig_runtime_data_type_pointer5",
      NULL
    };
    const char *current_key = "swig_runtime_data_type_pointer" SWIG_RUNTIME_VERSION;
    lua_pushstring(L, current_key);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (lua_islightuserdata(L, -1)) {
      for (const char **key = swig_runtime_keys; *key != NULL; key++) {
        if (strcmp(*key, current_key) != 0) {
          lua_pushstring(L, *key);
          lua_pushlightuserdata(L, lua_touserdata(L, -3));
          lua_rawset(L, LUA_REGISTRYINDEX);
        }
      }
    }
    lua_pop(L, 1);
  }
%}
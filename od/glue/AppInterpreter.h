#pragma once

#include <od/glue/Interpreter.h>
#include <vector>
#include <string>
#include "lua.h"

namespace od
{

  class AppInterpreter : public Interpreter
  {
  public:
    AppInterpreter();
    virtual ~AppInterpreter();

    void init();
  };

  // Declare the functions that are defined in AppInterpreter.cpp
  void stringVectorToLuaTable(lua_State* L, std::vector<std::string>& vec);
  void stringVectorToLuaTable(lua_State* L, const std::vector<std::string>& vec);

} /* namespace od */

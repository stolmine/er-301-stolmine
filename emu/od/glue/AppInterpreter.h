#pragma once
#include <vector>
#include <string>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

namespace od {

// Forward declare the class to avoid duplicate symbols
class AppInterpreter;

// Declare these as inline to avoid duplicate symbols
inline void stringVectorToLuaTable(lua_State* L, const std::vector<std::string>& vec) {
    lua_newtable(L);
    for (size_t i = 0; i < vec.size(); i++) {
        lua_pushstring(L, vec[i].c_str());
        lua_rawseti(L, -2, i + 1); // Lua tables are 1-based
    }
}

} // namespace od 
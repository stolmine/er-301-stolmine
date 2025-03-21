#pragma once
#include <vector>
#include <string>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

// Take the vector by const reference and create the table directly
inline int stringVectorToLuaTableWrapper(lua_State* L, const std::vector<std::string>& result) {
    lua_newtable(L);
    for (size_t i = 0; i < result.size(); i++) {
        lua_pushstring(L, result[i].c_str());
        lua_rawseti(L, -2, i + 1); // Lua tables are 1-based
    }
    return 1;
} 

%module app

%{
#include "string_vector_wrapper.h"
#include "od/glue/AppInterpreter.h"
%}

// Tell SWIG how to handle std::vector<std::string>
%include <std_vector.i>
%include <std_string.i>

// Handle vector<string> by value instead of reference
%apply std::vector<std::string> { std::vector<std::string>& }

%template(StringVector) std::vector<std::string>;

// Use the wrapper instead of the original function
%rename(stringVectorToLuaTable) stringVectorToLuaTableWrapper; 
%module multiout_libmultiout
%include <od/glue/mod.cpp.swig>

%{

#undef SWIGLUA

#include <multiout/QuadLFO.h>

#define SWIGLUA

%}

%include <multiout/QuadLFO.h>

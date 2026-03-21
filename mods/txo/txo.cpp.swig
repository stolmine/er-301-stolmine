%module txo_libtxo
%include <od/glue/mod.cpp.swig>

%{

#undef SWIGLUA

// tasks

#include <txo/TXoDispatcher.h>

// objects

#include <txo/TXoCV.h>
#include <txo/TXoTR.h>

#define SWIGLUA

%}

// tasks

%include <txo/TXoDispatcher.h>

// objects

%include <txo/TXoCV.h>
%include <txo/TXoTR.h>

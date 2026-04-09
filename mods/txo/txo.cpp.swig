%module txo_libtxo
%include <od/glue/mod.cpp.swig>

%{

#undef SWIGLUA

// tasks

#include <txo/TXoDispatcher.h>

// objects

#include <txo/TXoCV.h>
#include <txo/TXoTR.h>

// diagnostics

#include <txo/i2c_master_diag.h>

#define SWIGLUA

%}

// tasks

%include <txo/TXoDispatcher.h>

// objects

%include <txo/TXoCV.h>
%include <txo/TXoTR.h>

// diagnostics

%include <txo/i2c_master_diag.h>

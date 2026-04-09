#pragma once

// Standalone I2C slave diagnostic accessors for Lua/SWIG.
// These avoid modifying the Dispatcher class (which would change
// the .so binary layout and potentially break unit loading).

int I2cSlave_getDiagAAS();
int I2cSlave_getDiagRRDY();
int I2cSlave_getDiagARDY();
int I2cSlave_getDiagMsg();
int I2cSlave_getDiagOverrun();
int I2cSlave_getDiagDrop();

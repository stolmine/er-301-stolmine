#pragma once

// Standalone I2C master diagnostic accessors for Lua/SWIG.

int I2cMaster_getDiagSend();
int I2cMaster_getDiagNack();
int I2cMaster_getDiagArbLost();
int I2cMaster_getDiagBusy();

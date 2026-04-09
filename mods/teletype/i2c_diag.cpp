#include "i2c_diag.h"
#include <hal/i2c.h>

int I2cSlave_getDiagAAS()
{
  I2cSlaveDiag d;
  I2c_getSlaveDiag(&d);
  return d.aasCount;
}
int I2cSlave_getDiagRRDY()
{
  I2cSlaveDiag d;
  I2c_getSlaveDiag(&d);
  return d.rrdyCount;
}
int I2cSlave_getDiagARDY()
{
  I2cSlaveDiag d;
  I2c_getSlaveDiag(&d);
  return d.ardyCount;
}
int I2cSlave_getDiagMsg()
{
  I2cSlaveDiag d;
  I2c_getSlaveDiag(&d);
  return d.msgCount;
}
int I2cSlave_getDiagOverrun()
{
  I2cSlaveDiag d;
  I2c_getSlaveDiag(&d);
  return d.overrunCount;
}
int I2cSlave_getDiagDrop()
{
  I2cSlaveDiag d;
  I2c_getSlaveDiag(&d);
  return d.dropCount;
}

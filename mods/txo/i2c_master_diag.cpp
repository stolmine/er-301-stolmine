#include "i2c_master_diag.h"
#include <hal/i2c.h>

int I2cMaster_getDiagSend()
{
  I2cMasterDiag d;
  I2c_getMasterDiag(&d);
  return d.sendCount;
}
int I2cMaster_getDiagNack()
{
  I2cMasterDiag d;
  I2c_getMasterDiag(&d);
  return d.nackCount;
}
int I2cMaster_getDiagArbLost()
{
  I2cMasterDiag d;
  I2c_getMasterDiag(&d);
  return d.arbLostCount;
}
int I2cMaster_getDiagBusy()
{
  I2cMasterDiag d;
  I2c_getMasterDiag(&d);
  return d.busyCount;
}

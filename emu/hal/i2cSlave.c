#include <hal/i2c.h>
#include <hal/priorities.h>
#include <hal/log.h>
#include <stdio.h>
#include <string.h>

static bool initialized = false;
static bool masterOpen = false;
static FILE *txoMonitorFile = NULL;
static const char *txoMonitorPath = "/tmp/er301-txo-monitor";

bool I2c_popMessage(I2cMessage *msg)
{
  return false;
}

void I2c_init()
{
  initialized = true;
}

void I2c_deinit()
{
  initialized = false;
  masterOpen = false;
}

bool I2c_openSlave(uint32_t ownAddress)
{
  if (initialized)
  {
    logWarn("I2c_openSlave: not implemented.");
  }
  else
  {
    logError("I2c_openSlave: i2c not initialized.");
  }
  return false;
}

void I2c_closeSlave()
{
  if (initialized)
  {
    logWarn("I2c_closeSlave: not implemented.");
  }
  else
  {
    logError("I2c_closeSlave: i2c not initialized.");
  }
}

bool I2c_openMaster()
{
  if (initialized)
  {
    logInfo("I2c_openMaster: emulator stub (no real I2C).");
    txoMonitorFile = fopen(txoMonitorPath, "wb");
    if (txoMonitorFile)
    {
      logInfo("I2c_openMaster: monitor output -> %s", txoMonitorPath);
    }
    masterOpen = true;
    return true;
  }
  else
  {
    logError("I2c_openMaster: i2c not initialized.");
    return false;
  }
}

void I2c_closeMaster()
{
  if (initialized)
  {
    masterOpen = false;
    if (txoMonitorFile)
    {
      fclose(txoMonitorFile);
      txoMonitorFile = NULL;
    }
    logInfo("I2c_closeMaster: emulator stub.");
  }
  else
  {
    logError("I2c_closeMaster: i2c not initialized.");
  }
}

bool I2c_sendMessage(uint32_t slaveAddress, const uint8_t *data,
                     uint8_t length)
{
  if (!masterOpen)
  {
    return false;
  }

  // Write binary message to monitor file for the TUI viewer
  if (txoMonitorFile)
  {
    // Format: addr(1) len(1) data(len) — raw bytes
    uint8_t addr = (uint8_t)slaveAddress;
    fwrite(&addr, 1, 1, txoMonitorFile);
    fwrite(&length, 1, 1, txoMonitorFile);
    fwrite(data, 1, length, txoMonitorFile);
    fflush(txoMonitorFile);
  }

  return true;
}

bool I2c_isMasterOpen()
{
  return masterOpen;
}

void I2c_drainMasterQueue(int maxCount)
{
  // No-op in emulator — messages are logged in I2c_sendMessage
  (void)maxCount;
}

void I2c_masterISRHandler(uint32_t rawStatus)
{
  // No-op in emulator
  (void)rawStatus;
}

#include <hal/i2c.h>
#include <hal/priorities.h>
#include <hal/log.h>
#include <hal/timing.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>

static bool initialized = false;
static bool slaveOpen = false;
static bool masterOpen = false;
static FILE *txoMonitorFile = NULL;
static const char *txoMonitorPath = "/tmp/er301-txo-monitor";

// I2C slave input simulation: reads binary messages from a named pipe.
// External tool writes: [len(1)] [data(len)] to inject SC.CV/SC.TR commands.
static int slaveInputFd = -1;
static const char *slaveInputPath = "/tmp/er301-i2c-input";

bool I2c_popMessage(I2cMessage *msg)
{
  if (slaveInputFd < 0)
    return false;

  // Non-blocking read: [length(1)] [data(length)]
  uint8_t len = 0;
  ssize_t n = read(slaveInputFd, &len, 1);
  if (n != 1 || len == 0 || len > I2C_MAX_MSG_SIZE)
    return false;

  uint8_t buf[I2C_MAX_MSG_SIZE];
  ssize_t total = 0;
  while (total < len)
  {
    n = read(slaveInputFd, buf + total, len - total);
    if (n <= 0)
      return false;
    total += n;
  }

  msg->length = len;
  memcpy(msg->data, buf, len);
  msg->timestamp = ticks();
  return true;
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
  if (!initialized)
  {
    logError("I2c_openSlave: i2c not initialized.");
    return false;
  }

  // Create named pipe for I2C input simulation
  unlink(slaveInputPath);
  if (mkfifo(slaveInputPath, 0666) != 0 && errno != EEXIST)
  {
    logError("I2c_openSlave: failed to create FIFO %s", slaveInputPath);
    return false;
  }

  // Open non-blocking so we don't stall waiting for a writer
  slaveInputFd = open(slaveInputPath, O_RDONLY | O_NONBLOCK);
  if (slaveInputFd < 0)
  {
    logError("I2c_openSlave: failed to open FIFO %s", slaveInputPath);
    return false;
  }

  slaveOpen = true;
  logInfo("I2c_openSlave: listening on %s (address 0x%02x)", slaveInputPath, ownAddress);
  return true;
}

void I2c_closeSlave()
{
  if (slaveInputFd >= 0)
  {
    close(slaveInputFd);
    slaveInputFd = -1;
  }
  slaveOpen = false;
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

bool I2c_isMasterBusy(void)
{
  return false;
}

bool I2c_isSlaveOpen(void)
{
  return slaveOpen;
}

void I2c_getSlaveDiag(I2cSlaveDiag *diag)
{
  memset(diag, 0, sizeof(*diag));
}

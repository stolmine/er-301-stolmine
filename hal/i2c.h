#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <hal/timing.h>

#ifdef __cplusplus
extern "C"
{
#endif

#define I2C_MAX_MSG_SIZE (8)

  typedef struct
  {
    tick_t timestamp;
    uint8_t data[I2C_MAX_MSG_SIZE];
    uint8_t length;
  } I2cMessage;

  // Slave (follower) API
  void I2c_init();
  void I2c_deinit();
  bool I2c_openSlave(uint32_t ownAddress);
  void I2c_closeSlave();
  bool I2c_popMessage(I2cMessage *msg);

  // Master (leader) API
  bool I2c_openMaster();
  void I2c_closeMaster();
  bool I2c_sendMessage(uint32_t slaveAddress, const uint8_t *data,
                       uint8_t length);
  bool I2c_isMasterOpen();
  void I2c_drainMasterQueue(int maxCount);

  // Cross-module queries for simultaneous master/slave
  bool I2c_isMasterBusy(void);
  bool I2c_isSlaveOpen(void);

  // Internal: called from I2C2 ISR to handle master TX interrupts
  void I2c_masterISRHandler(uint32_t rawStatus);

  // Slave diagnostic counters
  typedef struct
  {
    uint32_t aasCount;     // address-as-slave matched
    uint32_t rrdyCount;    // bytes received
    uint32_t ardyCount;    // access ready (message boundary)
    uint32_t msgCount;     // complete messages enqueued
    uint32_t overrunCount; // receive overruns
    uint32_t dropCount;    // messages dropped (queue full or ARDY gated)
  } I2cSlaveDiag;

  void I2c_getSlaveDiag(I2cSlaveDiag *diag);

  // Master diagnostic counters
  typedef struct
  {
    uint32_t sendCount;      // messages sent successfully (ARDY)
    uint32_t nackCount;      // NACKs received
    uint32_t arbLostCount;   // arbitration lost events
    uint32_t busyCount;      // transfers skipped (bus busy)
  } I2cMasterDiag;

  void I2c_getMasterDiag(I2cMasterDiag *diag);

#ifdef __cplusplus
}
#endif

#include <hal/i2c.h>
#include <hal/board.h>
#include <hal/log.h>
#include <hal/uart.h>
#include <hal/priorities.h>
#include <ti/am335x/csl_i2c.h>
#include <ti/am335x/soc.h>
#include <ti/sysbios/family/arm/a8/intcps/Hwi.h>
#include <string.h>

#define I2C_BASE_ADDRESS (SOC_I2C_2_REGS)
#define I2C_INPUT_FUNCTIONAL_CLK (48000000U)
#define I2C_MODULE_INTERNAL_CLK_12MHZ (12000000U)

#define MASTER_TX_INTFLAGS (I2C_INT_TRANSMIT_READY | \
                            I2C_INT_ADRR_READY_ACESS | \
                            I2C_INT_NO_ACK | \
                            I2C_INT_ARBITRATION_LOST)

// TX queue (lock-free SPSC FIFO, same pattern as slave RX queue)
#define TX_QUEUE_SIZE (64)

typedef struct
{
  uint32_t slaveAddress;
  uint8_t data[I2C_MAX_MSG_SIZE];
  uint8_t length;
} TxEntry;

typedef enum
{
  MASTER_IDLE,
  MASTER_SENDING,
  MASTER_WAIT_ARDY
} MasterState;

typedef struct
{
  bool isOpen;

  // SPSC queue: producer = audio thread, consumer = ISR
  TxEntry queue[TX_QUEUE_SIZE];
  size_t front, pfront;
  size_t back, cback;

  // ISR working state
  volatile MasterState state;
  TxEntry current;
  uint8_t byteIndex;
} MasterLocal;

static MasterLocal master;
static I2cMasterDiag masterDiag;

//// WeakRB bounded FIFO queue
// Ref: Correct and Efficient Bounded FIFO Queues
// https://www.irif.fr/~guatto/papers/sbac13.pdf

static void initTxQ()
{
  master.front = master.pfront = 0;
  master.back = master.cback = 0;
}

static bool pushTxQ(TxEntry *entry)
{
  size_t b;
  b = __atomic_load_n(&master.back, __ATOMIC_RELAXED);
  if (master.pfront + TX_QUEUE_SIZE - b < 1)
  {
    master.pfront = __atomic_load_n(&master.front, __ATOMIC_ACQUIRE);
    if (master.pfront + TX_QUEUE_SIZE - b < 1)
    {
      return false;
    }
  }
  master.queue[b % TX_QUEUE_SIZE] = *entry;
  __atomic_store_n(&master.back, b + 1, __ATOMIC_RELEASE);
  return true;
}

static bool popTxQ(TxEntry *entry)
{
  size_t f;
  f = __atomic_load_n(&master.front, __ATOMIC_RELAXED);
  if (master.cback - f < 1)
  {
    master.cback = __atomic_load_n(&master.back, __ATOMIC_ACQUIRE);
    if (master.cback - f < 1)
    {
      return false;
    }
  }
  *entry = master.queue[f % TX_QUEUE_SIZE];
  __atomic_store_n(&master.front, f + 1, __ATOMIC_RELEASE);
  return true;
}

// Restore slave-mode CON register if slave is open.
// Called whenever master goes idle after a transfer.
static void restoreSlaveMode(void)
{
  if (I2c_isSlaveOpen())
  {
    I2CMasterControl(I2C_BASE_ADDRESS,
                     I2C_CFG_MST_ENABLE | I2C_CFG_7BIT_OWN_ADDR_0);
  }
}

// Pop one message from queue and initiate I2C transfer.
// Called from audio thread only (with HWI disabled).
// Only one transfer per call — after completion the ISR restores slave
// mode, leaving a full audio frame of slave listening before the next
// drainMasterQueue call. This mirrors Crow's one-transfer-per-poll
// pattern and prevents master TX from starving slave address matching.
static void startNextTransfer(void)
{
  // Don't start a master transfer while bus is busy (e.g., slave receiving)
  if (I2CMasterBusBusy(I2C_BASE_ADDRESS))
  {
    masterDiag.busyCount++;
    master.state = MASTER_IDLE;
    restoreSlaveMode();
    return;
  }

  TxEntry entry;
  if (!popTxQ(&entry))
  {
    master.state = MASTER_IDLE;
    restoreSlaveMode();
    return;
  }

  master.current = entry;
  master.byteIndex = 0;
  master.state = MASTER_SENDING;

  I2CMasterSlaveAddrSet(I2C_BASE_ADDRESS, entry.slaveAddress);
  I2CSetDataCount(I2C_BASE_ADDRESS, entry.length);
  I2CFIFOClear(I2C_BASE_ADDRESS, I2C_TX_MODE);
  I2CMasterIntClearEx(I2C_BASE_ADDRESS, MASTER_TX_INTFLAGS);
  I2CMasterIntEnableEx(I2C_BASE_ADDRESS, MASTER_TX_INTFLAGS);

  // MST_TX takes over the CON register. When master goes idle,
  // restoreSlaveMode() re-enables slave addressing.
  I2CMasterControl(I2C_BASE_ADDRESS,
                   I2C_CFG_MST_TX | I2C_CFG_MST_ENABLE |
                       I2C_CFG_START | I2C_CFG_STOP |
                       I2C_CFG_7BIT_SLAVE_ADDR);
}

// Called from the unified I2C2 ISR in i2cSlave.c.
// Handles master TX interrupt status bits.
void I2c_masterISRHandler(uint32_t stat)
{
  if (!master.isOpen || master.state == MASTER_IDLE)
  {
    return;
  }

  // NACK: slave didn't acknowledge — go idle, restore slave mode
  if (stat & I2C_INT_NO_ACK)
  {
    masterDiag.nackCount++;
    I2CMasterIntDisableEx(I2C_BASE_ADDRESS, MASTER_TX_INTFLAGS);
    I2CMasterStop(I2C_BASE_ADDRESS);
    I2CMasterIntClearEx(I2C_BASE_ADDRESS,
                        I2C_INT_NO_ACK | I2C_INT_ADRR_READY_ACESS);
    master.state = MASTER_IDLE;
    restoreSlaveMode();
    return;
  }

  // Arbitration lost
  if (stat & I2C_INT_ARBITRATION_LOST)
  {
    masterDiag.arbLostCount++;
    I2CMasterIntDisableEx(I2C_BASE_ADDRESS, MASTER_TX_INTFLAGS);
    I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_ARBITRATION_LOST);
    master.state = MASTER_IDLE;
    restoreSlaveMode();
    return;
  }

  // XRDY: transmit data register ready for next byte
  if (stat & I2C_INT_TRANSMIT_READY)
  {
    if (master.byteIndex < master.current.length)
    {
      I2CMasterDataPut(I2C_BASE_ADDRESS,
                       master.current.data[master.byteIndex]);
      master.byteIndex++;

      if (master.byteIndex >= master.current.length)
      {
        I2CMasterIntDisableEx(I2C_BASE_ADDRESS, I2C_INT_TRANSMIT_READY);
        master.state = MASTER_WAIT_ARDY;
      }
    }
    I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_TRANSMIT_READY);
  }

  // ARDY: transfer complete — go idle, restore slave mode.
  // Next transfer will be kicked by drainMasterQueue on the next audio frame.
  if (stat & I2C_INT_ADRR_READY_ACESS)
  {
    masterDiag.sendCount++;
    I2CMasterIntDisableEx(I2C_BASE_ADDRESS, MASTER_TX_INTFLAGS);
    I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_ADRR_READY_ACESS);
    master.state = MASTER_IDLE;
    restoreSlaveMode();
  }
}

bool I2c_openMaster()
{
  if (master.isOpen)
  {
    return true;
  }

  memset(&master, 0, sizeof(master));
  memset(&masterDiag, 0, sizeof(masterDiag));
  initTxQ();
  master.state = MASTER_IDLE;

  // I2C2 shares pins with UART0
  Uart_disable();

  // I2c_init() creates the shared HWI and enables pinmux/clock.
  // Safe to call multiple times (idempotent).
  I2c_init();

  // Only do full peripheral config if slave hasn't already set it up.
  // Slave's I2c_openSlave() configures clock, enables peripheral, etc.
  // Reconfiguring would destroy the slave's own-address and interrupt setup.
  if (!I2c_isSlaveOpen())
  {
    I2CMasterDisable(I2C_BASE_ADDRESS);
    I2CAutoIdleDisable(I2C_BASE_ADDRESS);

    I2CMasterInitExpClk(I2C_BASE_ADDRESS, I2C_INPUT_FUNCTIONAL_CLK,
                        I2C_MODULE_INTERNAL_CLK_12MHZ,
                        100000);

    I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_ALL);
    I2CMasterIntDisableEx(I2C_BASE_ADDRESS, I2C_INT_ALL);

    I2CMasterEnable(I2C_BASE_ADDRESS);
    I2CMasterEnableFreeRun(I2C_BASE_ADDRESS);
  }
  I2CFIFOClear(I2C_BASE_ADDRESS, I2C_TX_MODE);

  master.isOpen = true;
  logInfo("I2c_openMaster: interrupt-driven master TX enabled on I2C2.");
  return true;
}

void I2c_closeMaster()
{
  if (master.isOpen)
  {
    master.isOpen = false;

    I2CMasterIntDisableEx(I2C_BASE_ADDRESS, MASTER_TX_INTFLAGS);
    I2CMasterIntClearEx(I2C_BASE_ADDRESS, MASTER_TX_INTFLAGS);

    master.state = MASTER_IDLE;
    restoreSlaveMode();
    logInfo("I2c_closeMaster: master TX disabled.");
  }
}

bool I2c_isMasterOpen()
{
  return master.isOpen;
}

bool I2c_isMasterBusy(void)
{
  return master.isOpen && master.state != MASTER_IDLE;
}

bool I2c_sendMessage(uint32_t slaveAddress, const uint8_t *data,
                     uint8_t length)
{
  if (!master.isOpen || length == 0 || length > I2C_MAX_MSG_SIZE)
  {
    return false;
  }

  TxEntry entry;
  entry.slaveAddress = slaveAddress;
  entry.length = length;
  memcpy(entry.data, data, length);
  return pushTxQ(&entry);
}

// Called from the audio thread to send one queued message.
// Sends at most one message per call, then returns to slave mode.
// The next call happens on the next audio frame (~2.67ms later),
// guaranteeing a slave listening window between transfers.
void I2c_drainMasterQueue(int maxCount)
{
  (void)maxCount;
  if (!master.isOpen)
  {
    return;
  }

  uint32_t key = Hwi_disable();
  if (master.state == MASTER_IDLE)
  {
    startNextTransfer();
  }
  Hwi_restore(key);
}

void I2c_getMasterDiag(I2cMasterDiag *diag)
{
  *diag = masterDiag;
}

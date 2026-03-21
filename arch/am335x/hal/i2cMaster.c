#include <hal/i2c.h>
#include <hal/board.h>
#include <hal/log.h>
#include <hal/uart.h>
#include <ti/am335x/csl_i2c.h>
#include <ti/am335x/soc.h>
#include <string.h>

#define I2C_BASE_ADDRESS (SOC_I2C_2_REGS)
#define I2C_INPUT_FUNCTIONAL_CLK (48000000U)
#define I2C_MODULE_INTERNAL_CLK_12MHZ (12000000U)

// TX queue (lock-free SPSC FIFO, same pattern as slave RX queue)
#define TX_QUEUE_SIZE (64)

typedef struct
{
  uint32_t slaveAddress;
  uint8_t data[I2C_MAX_MSG_SIZE];
  uint8_t length;
} TxEntry;

typedef struct
{
  bool isOpen;
  TxEntry queue[TX_QUEUE_SIZE];
  size_t front, pfront;
  size_t back, cback;
} MasterLocal;

static MasterLocal master;

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

bool I2c_openMaster()
{
  if (master.isOpen)
  {
    return true;
  }
  initTxQ();

  // I2C2 shares pins with UART0 — disable UART first
  Uart_disable();

  // Enable I2C2 pinmux and module clock
  Board_pinmuxI2C2();
  Board_enableI2C2();

  // Disable the peripheral so we can reconfigure
  I2CMasterDisable(I2C_BASE_ADDRESS);

  // Disable Auto Idle
  I2CAutoIdleDisable(I2C_BASE_ADDRESS);

  // Configure clock for 100kHz
  I2CMasterInitExpClk(I2C_BASE_ADDRESS, I2C_INPUT_FUNCTIONAL_CLK,
                      I2C_MODULE_INTERNAL_CLK_12MHZ,
                      100000);

  // Clear any pending interrupts
  I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_ALL);

  // Disable all interrupts — master TX uses polled mode
  I2CMasterIntDisableEx(I2C_BASE_ADDRESS, I2C_INT_ALL);

  // Enable the I2C module
  I2CMasterEnable(I2C_BASE_ADDRESS);

  // Enable free run mode (don't freeze on debug halt)
  I2CMasterEnableFreeRun(I2C_BASE_ADDRESS);

  // Clear TX FIFO
  I2CFIFOClear(I2C_BASE_ADDRESS, I2C_TX_MODE);

  master.isOpen = true;
  logInfo("I2c_openMaster: master TX enabled, I2C2 configured for polled master.");
  return true;
}

void I2c_closeMaster()
{
  if (master.isOpen)
  {
    master.isOpen = false;
    logInfo("I2c_closeMaster: master TX disabled.");
  }
}

bool I2c_isMasterOpen()
{
  return master.isOpen;
}

// Blocking polled master transmit.
// Called from the audio thread's task processing, NOT from ISR.
// The I2C peripheral is shared with slave mode — we temporarily
// reconfigure for master TX, send the message, then restore slave.
static bool masterTransmitPolled(uint32_t slaveAddress,
                                 const uint8_t *data, uint8_t length)
{
  uint32_t timeout = 50000;

  // Wait for bus to be free
  while (I2CMasterBusBusy(I2C_BASE_ADDRESS) && --timeout)
    ;
  if (timeout == 0)
  {
    logWarn("I2c master: bus busy timeout");
    return false;
  }

  // Set slave address
  I2CMasterSlaveAddrSet(I2C_BASE_ADDRESS, slaveAddress);

  // Set data count
  I2CSetDataCount(I2C_BASE_ADDRESS, length);

  // Configure as master-transmitter and generate START + STOP
  I2CMasterControl(I2C_BASE_ADDRESS,
                   I2C_CFG_MST_TX | I2C_CFG_MST_ENABLE |
                       I2C_CFG_START | I2C_CFG_STOP |
                       I2C_CFG_7BIT_SLAVE_ADDR);

  for (uint8_t i = 0; i < length; i++)
  {
    timeout = 50000;
    // Wait for transmit ready
    while (!(I2CMasterIntRawStatus(I2C_BASE_ADDRESS) &
             I2C_INT_TRANSMIT_READY) &&
           --timeout)
      ;
    if (timeout == 0)
    {
      logWarn("I2c master: TX ready timeout at byte %d", i);
      return false;
    }

    I2CMasterDataPut(I2C_BASE_ADDRESS, data[i]);
    I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_TRANSMIT_READY);
  }

  // Wait for ARDY (access ready = transfer complete)
  timeout = 50000;
  while (!(I2CMasterIntRawStatus(I2C_BASE_ADDRESS) &
           I2C_INT_ADRR_READY_ACESS) &&
         --timeout)
    ;

  // Check for NACK
  if (I2CMasterIntRawStatus(I2C_BASE_ADDRESS) & I2C_INT_NO_ACK)
  {
    logWarn("I2c master: NACK from 0x%02x", slaveAddress);
    I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_NO_ACK);
  }

  I2CMasterIntClearEx(I2C_BASE_ADDRESS,
                      I2C_INT_ADRR_READY_ACESS | I2C_INT_BUS_FREE);

  return true;
}

bool I2c_sendMessage(uint32_t slaveAddress, const uint8_t *data,
                     uint8_t length)
{
  if (!master.isOpen || length == 0 || length > I2C_MAX_MSG_SIZE)
  {
    return false;
  }

  // For now: queue the message. The TXo dispatcher task will call
  // I2c_drainMasterQueue() from the audio thread context.
  TxEntry entry;
  entry.slaveAddress = slaveAddress;
  entry.length = length;
  memcpy(entry.data, data, length);
  return pushTxQ(&entry);
}

// Called from the TXo dispatcher task on the audio thread.
// Drains queued TX messages using polled master transmit.
// Processes up to maxCount messages per call to avoid hogging the bus.
void I2c_drainMasterQueue(int maxCount)
{
  if (!master.isOpen)
  {
    return;
  }

  TxEntry entry;
  int count = 0;
  while (count < maxCount && popTxQ(&entry))
  {
    masterTransmitPolled(entry.slaveAddress, entry.data, entry.length);
    count++;
  }
}

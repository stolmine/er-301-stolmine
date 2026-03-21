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
#define I2C_INTERRUPT (I2C2_INT)

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

// Max messages the ISR will chain before going idle.
// Prevents the ISR from monopolizing the interrupt context
// when the queue is continuously fed (e.g., feedback loops).
#define MAX_ISR_CHAIN (4)

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
  uint8_t chainCount; // messages sent in current chain

  Hwi_Handle hwiHandle;
} MasterLocal;

static MasterLocal master;

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

// Pop next message from queue and initiate I2C transfer.
// Called from audio thread (with HWI disabled) and from ISR (on ARDY).
static void startNextTransfer(bool fromISR)
{
  // Limit chaining from ISR to avoid starving other interrupts
  if (fromISR && master.chainCount >= MAX_ISR_CHAIN)
  {
    master.state = MASTER_IDLE;
    master.chainCount = 0;
    return;
  }

  TxEntry entry;
  if (!popTxQ(&entry))
  {
    master.state = MASTER_IDLE;
    master.chainCount = 0;
    return;
  }

  master.current = entry;
  master.byteIndex = 0;
  master.state = MASTER_SENDING;
  if (fromISR)
  {
    master.chainCount++;
  }
  else
  {
    master.chainCount = 0;
  }

  I2CMasterSlaveAddrSet(I2C_BASE_ADDRESS, entry.slaveAddress);
  I2CSetDataCount(I2C_BASE_ADDRESS, entry.length);
  I2CFIFOClear(I2C_BASE_ADDRESS, I2C_TX_MODE);
  I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_ALL);
  I2CMasterIntEnableEx(I2C_BASE_ADDRESS, MASTER_TX_INTFLAGS);

  I2CMasterControl(I2C_BASE_ADDRESS,
                   I2C_CFG_MST_TX | I2C_CFG_MST_ENABLE |
                       I2C_CFG_START | I2C_CFG_STOP |
                       I2C_CFG_7BIT_SLAVE_ADDR);
}

static void masterTxISR(UArg arg)
{
  uint32_t stat = I2CMasterIntRawStatus(I2C_BASE_ADDRESS);

  // NACK: slave didn't acknowledge
  if (stat & I2C_INT_NO_ACK)
  {
    I2CMasterIntDisableEx(I2C_BASE_ADDRESS, MASTER_TX_INTFLAGS);
    I2CMasterStop(I2C_BASE_ADDRESS);
    I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_ALL);
    // Discard this message, try next
    startNextTransfer(true);
    return;
  }

  // Arbitration lost
  if (stat & I2C_INT_ARBITRATION_LOST)
  {
    I2CMasterIntDisableEx(I2C_BASE_ADDRESS, MASTER_TX_INTFLAGS);
    I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_ALL);
    master.state = MASTER_IDLE;
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
        // Last byte written — only need ARDY now
        I2CMasterIntDisableEx(I2C_BASE_ADDRESS, I2C_INT_TRANSMIT_READY);
        master.state = MASTER_WAIT_ARDY;
      }
    }
    I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_TRANSMIT_READY);
  }

  // ARDY: transfer complete
  if (stat & I2C_INT_ADRR_READY_ACESS)
  {
    I2CMasterIntDisableEx(I2C_BASE_ADDRESS, MASTER_TX_INTFLAGS);
    I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_ALL);
    // Chain to next queued message (or go IDLE)
    startNextTransfer(true);
  }
}

bool I2c_openMaster()
{
  if (master.isOpen)
  {
    return true;
  }

  memset(&master, 0, sizeof(master));
  initTxQ();
  master.state = MASTER_IDLE;

  // I2C2 shares pins with UART0
  Uart_disable();

  Board_pinmuxI2C2();
  Board_enableI2C2();

  I2CMasterDisable(I2C_BASE_ADDRESS);
  I2CAutoIdleDisable(I2C_BASE_ADDRESS);

  I2CMasterInitExpClk(I2C_BASE_ADDRESS, I2C_INPUT_FUNCTIONAL_CLK,
                      I2C_MODULE_INTERNAL_CLK_12MHZ,
                      100000);

  I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_ALL);
  I2CMasterIntDisableEx(I2C_BASE_ADDRESS, I2C_INT_ALL);

  I2CMasterEnable(I2C_BASE_ADDRESS);
  I2CMasterEnableFreeRun(I2C_BASE_ADDRESS);
  I2CFIFOClear(I2C_BASE_ADDRESS, I2C_TX_MODE);

  // Register ISR for I2C2 interrupt
  Hwi_Params params;
  Hwi_Params_init(&params);
  params.priority = HWI_PRIORITY_I2C;
  master.hwiHandle = Hwi_create(I2C_INTERRUPT, masterTxISR, &params, NULL);

  master.isOpen = true;
  logInfo("I2c_openMaster: interrupt-driven master TX enabled on I2C2.");
  return true;
}

void I2c_closeMaster()
{
  if (master.isOpen)
  {
    master.isOpen = false;

    I2CMasterIntDisableEx(I2C_BASE_ADDRESS, I2C_INT_ALL);
    I2CMasterIntClearEx(I2C_BASE_ADDRESS, I2C_INT_ALL);

    if (master.hwiHandle)
    {
      Hwi_delete(&master.hwiHandle);
      master.hwiHandle = NULL;
    }

    I2CMasterDisable(I2C_BASE_ADDRESS);
    master.state = MASTER_IDLE;
    logInfo("I2c_closeMaster: master TX disabled.");
  }
}

bool I2c_isMasterOpen()
{
  return master.isOpen;
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

// Called from the audio thread to kick the ISR if idle.
// The ISR self-chains through queued messages on ARDY.
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
    startNextTransfer(false);
  }
  Hwi_restore(key);
}

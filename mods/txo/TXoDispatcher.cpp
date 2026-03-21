#include <txo/TXoDispatcher.h>
#include <od/AudioThread.h>
#include <hal/i2c.h>
#include <hal/log.h>
#include <od/config.h>
#include <hal/ops.h>
#include <string.h>
#include <limits.h>

// TXo I2C opcodes (from telex.h)
#define TO_TR 0x00
#define TO_TR_TOG 0x01
#define TO_CV 0x10
#define TO_CV_SET 0x11

namespace txo
{

  TXoDispatcher::TXoDispatcher() : Task("TXo Dispatcher")
  {
    memset(mCVValue, 0, sizeof(mCVValue));
    memset(mCVDirty, 0, sizeof(mCVDirty));
    memset(mTRValue, 0, sizeof(mTRValue));
    memset(mTRDirty, 0, sizeof(mTRDirty));
    memset(mCVWriteFrame, 0, sizeof(mCVWriteFrame));
    memset(mTRWriteFrame, 0, sizeof(mTRWriteFrame));
    mFrameCount = 0;
    mSamplesPerUpdate = globalConfig.sampleRate / mUpdateRate;
    mSampleCounter = 0;
  }

  TXoDispatcher::~TXoDispatcher()
  {
    disable();
  }

  void TXoDispatcher::setUpdateRate(int hz)
  {
    mUpdateRate = CLAMP(10, 4000, hz);
    mSamplesPerUpdate = globalConfig.sampleRate / mUpdateRate;
  }

  void TXoDispatcher::sendCV(int output, float value)
  {
    // Convert float voltage to 16-bit signed integer
    // TXo protocol: 16384 per volt (same as Teletype SC.CV)
    // int16 range ±32767 gives ~±2V at this scale
    // Values beyond ±2V will clip at the protocol level
    int intRaw = (int)(value * 16384.0f);
    int16_t intValue = (int16_t)CLAMP(-32768, 32767, intRaw);
    uint8_t data[4];
    data[0] = TO_CV_SET;
    data[1] = (uint8_t)output;
    data[2] = (uint8_t)((intValue >> 8) & 0xFF);
    data[3] = (uint8_t)(intValue & 0xFF);
    I2c_sendMessage(mTXoAddress, data, 4);
  }

  void TXoDispatcher::sendTR(int output, bool state)
  {
    uint8_t data[4];
    data[0] = TO_TR;
    data[1] = (uint8_t)output;
    data[2] = 0;
    data[3] = state ? 1 : 0;
    I2c_sendMessage(mTXoAddress, data, 4);
  }

  void TXoDispatcher::process(float *inputs, float *outputs)
  {
    mFrameCount++;
    mSampleCounter += globalConfig.frameLength;

    if (mSampleCounter < mSamplesPerUpdate)
    {
      return;
    }
    mSampleCounter -= mSamplesPerUpdate;

    // Send any dirty CV values
    for (int i = 0; i < MaxOutputs; i++)
    {
      if (mCVDirty[i])
      {
        sendCV(i, mCVValue[i]);
        mCVDirty[i] = false;
      }
    }

    // Send any dirty TR values
    for (int i = 0; i < MaxOutputs; i++)
    {
      if (mTRDirty[i])
      {
        sendTR(i, mTRValue[i] > 0.5f);
        mTRDirty[i] = false;
      }
    }

    // Drain the TX queue (max 8 messages per update to avoid hogging)
    I2c_drainMasterQueue(8);
  }

  void TXoDispatcher::enable(uint32_t txoAddress)
  {
    if (!mEnabled)
    {
      mTXoAddress = txoAddress;
      logInfo("Enabling TXo I2C master to 0x%x.", txoAddress);
      I2c_openMaster();
      od::AudioThread::addTask(this, INT_MAX - 2);
      mEnabled = true;
    }
  }

  void TXoDispatcher::disable()
  {
    if (mEnabled)
    {
      od::AudioThread::removeTask(this);
      mEnabled = false;
      I2c_closeMaster();
    }
  }

} // namespace txo

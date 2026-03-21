#include <txo/TXoCV.h>
#include <od/config.h>
#include <hal/ops.h>

namespace txo
{

  TXoCV::TXoCV(TXoDispatcher *pDispatcher) : mpDispatcher(pDispatcher)
  {
    addInput(mInput);
    addOutput(mOutput);
    addParameter(mPort);
    addParameter(mGain);
    addOption(mMode);
  }

  TXoCV::~TXoCV()
  {
  }

  void TXoCV::process()
  {
    int port = CLAMP(0, TXoDispatcher::MaxOutputs - 1,
                     (int)mPort.roundValue());

    float *in = mInput.buffer();
    float *out = mOutput.buffer();

    // Pass through input to output
    for (int i = 0; i < FRAMELENGTH; i++)
    {
      out[i] = in[i];
    }

    // Sample the last value in the frame for I2C
    float value = in[FRAMELENGTH - 1];

    // Apply gain in Normal mode; 1:1 in V/Oct mode
    if (mMode.value() == 0)
    {
      value *= mGain.value();
    }

    // Write to dispatcher (last-write-wins for v1)
    mpDispatcher->mCVValue[port] = value;
    mpDispatcher->mCVDirty[port] = true;
    mpDispatcher->mCVWriteFrame[port] = mpDispatcher->mFrameCount;
  }

} // namespace txo

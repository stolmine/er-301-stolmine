#include <txo/TXoTR.h>
#include <od/config.h>
#include <hal/ops.h>

namespace txo
{

  TXoTR::TXoTR(TXoDispatcher *pDispatcher) : mpDispatcher(pDispatcher)
  {
    addInput(mInput);
    addOutput(mOutput);
    addParameter(mPort);
    addParameter(mThreshold);
  }

  TXoTR::~TXoTR()
  {
  }

  void TXoTR::process()
  {
    int port = CLAMP(0, TXoDispatcher::MaxOutputs - 1,
                     (int)mPort.roundValue());
    float threshold = mThreshold.value();

    float *in = mInput.buffer();
    float *out = mOutput.buffer();

    // Pass through input to output
    for (int i = 0; i < FRAMELENGTH; i++)
    {
      out[i] = in[i];
    }

    // Detect gate state from last sample in frame
    bool state = in[FRAMELENGTH - 1] > threshold;

    // Only send when state changes
    if (state != mLastState)
    {
      mpDispatcher->mTRValue[port] = state ? 1.0f : 0.0f;
      mpDispatcher->mTRDirty[port] = true;
      mpDispatcher->mTRWriteFrame[port] = mpDispatcher->mFrameCount;
      mLastState = state;
    }
  }

} // namespace txo

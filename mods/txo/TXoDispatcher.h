#pragma once

#include <od/tasks/Task.h>

namespace txo
{

  class TXoDispatcher : public od::Task
  {
  public:
    TXoDispatcher();
    virtual ~TXoDispatcher();

    void enable(uint32_t txoAddress);
    void disable();
    void setUpdateRate(int hz);

#ifndef SWIGLUA
    void process(float *inputs, float *outputs);

    static const int MaxOutputs = 4;

    // CV state: written by TXoCV objects, read by dispatcher
    float mCVValue[MaxOutputs];
    bool mCVDirty[MaxOutputs];

    // TR state: written by TXoTR objects, read by dispatcher
    float mTRValue[MaxOutputs];
    bool mTRDirty[MaxOutputs];

    // Collision tracking: last-write-wins with frame counter
    uint32_t mCVWriteFrame[MaxOutputs];
    uint32_t mTRWriteFrame[MaxOutputs];
    uint32_t mFrameCount;
#endif

  protected:
    uint32_t mTXoAddress = 0x60;
    bool mEnabled = false;
    int mUpdateRate = 1000;
    int mSamplesPerUpdate = 0;
    int mSampleCounter = 0;

    void sendCV(int output, float value);
    void sendTR(int output, bool state);
  };

} // namespace txo

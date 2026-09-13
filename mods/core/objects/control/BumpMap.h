#pragma once

#include <od/objects/heads/Head.h>
#include <od/audio/Sample.h>

namespace od
{

  class BumpMap : public Head
  {
  public:
    BumpMap();
    virtual ~BumpMap();

    void setSample(Sample *sample) override
    {
      Head::setSample(sample);
      if (sample)
      {
        mChannelIndex = 0;
      }
    }
    void setSample(Sample *sample, int channel);

#ifndef SWIGLUA
    void process() override;
    Inlet mInput{"In"};
    Outlet mOutput{"Out"};
    Inlet mPhase{"Phase"};
    Parameter mCenter{"Center", 0.0f};
    Parameter mWidth{"Width", 0.1f};
    Parameter mHeight{"Height", 0.5f};
    Parameter mFade{"Fade", 0.25f};
    Option mInterpolation{"Interpolation", INTERPOLATION_LINEAR};
#endif

  private:
    int mChannelIndex = 0;
    float mPreviousCenter = 0.0f;
    float mPreviousScale = 1.0f;
    float mPreviousHeight = 0.5f;
    float mPreviousEdge = 0.5f;

    void processWithSample();
    void processWithNoSample();
  };

} /* namespace od */

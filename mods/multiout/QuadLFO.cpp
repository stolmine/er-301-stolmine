#include <multiout/QuadLFO.h>
#include <math.h>
#include <od/config.h>

namespace multiout
{

  QuadLFO::QuadLFO()
  {
    addInput(mFrequency);
    addInput(mSync);
    addOutput(mOut1);
    addOutput(mOut2);
    addOutput(mOut3);
    addOutput(mOut4);
    addParameter(mInternalPhase);
    mInternalPhase.enableSerialization();
  }

  QuadLFO::~QuadLFO()
  {
  }

  // NOTE: scalar sinf is fine on Linux emu (x86_64, aarch64). On am335x
  // hardware, runtime sinf called from a package .so miscomputes — see
  // memory_project_package_trig_bug. If shipping QuadLFO to am335x, replace
  // with a precomputed LUT (pattern in habitat's FilterResponseGraphic.h).
  void QuadLFO::process()
  {
    float *freq = mFrequency.buffer();
    float *sync = mSync.buffer();
    float *out1 = mOut1.buffer();
    float *out2 = mOut2.buffer();
    float *out3 = mOut3.buffer();
    float *out4 = mOut4.buffer();
    const float sr = globalConfig.samplePeriod;
    const float twoPi = 2.0f * M_PI;
    const float halfPi = 0.5f * M_PI;
    float internalPhase = mInternalPhase.value();

    for (int i = 0; i < FRAMELENGTH; i++)
    {
      if (sync[i] > 0.0f)
      {
        internalPhase = 0.0f;
      }
      else
      {
        internalPhase += sr * freq[i];
        if (internalPhase >= 1.0f)
        {
          internalPhase -= (int)internalPhase;
        }
        else if (internalPhase < 0.0f)
        {
          internalPhase -= (int)internalPhase - 1.0f;
        }
      }
      const float p = internalPhase * twoPi;
      out1[i] = sinf(p);
      out2[i] = sinf(p + halfPi);
      out3[i] = sinf(p + 2.0f * halfPi);
      out4[i] = sinf(p + 3.0f * halfPi);
    }

    mInternalPhase.hardSet(internalPhase);
  }

} // namespace multiout

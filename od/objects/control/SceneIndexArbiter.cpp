#include <od/objects/control/SceneIndexArbiter.h>
#include <od/config.h>
#include <hal/simd.h>
#include <math.h>

namespace od
{

  // kIndex semantics: Bias and CV are normalized [0, 1] (a
  // fraction-of-bank position). Output is round(value * N),
  // clipped to [0, N], so input semantics are bank-independent.
  // Add or remove scenes and the fader / CV mapping doesn't
  // change -- only the audible output range shifts.

  SceneIndexArbiter::SceneIndexArbiter()
  {
    addInput(mInput);
    addOutput(mOutput);
    addParameter(mGain);
    addParameter(mBias);
  }

  SceneIndexArbiter::~SceneIndexArbiter()
  {
  }

  int SceneIndexArbiter::clipIndex(int v) const
  {
    if (v < 0) return 0;
    if (v > mSceneCount) return mSceneCount;
    return v;
  }

  int SceneIndexArbiter::computeEffectiveIndex(float cvIn, float gain, float bias) const
  {
    // Both Bias and CV scaled by mSceneCount to land in [0, N]
    // output space. Bias is the user's normalized manual position;
    // gain * cvIn is the normalized CV-driven offset (Gain stays
    // a unitless input scaler so default 0 leaves CV inert).
    float normalized;
    if (mState == kTrackingCV)
    {
      normalized = gain * cvIn;
    }
    else
    {
      normalized = bias;
    }
    int idx = (int)floorf(normalized * (float)mSceneCount + 0.5f);
    return clipIndex(idx);
  }

  bool SceneIndexArbiter::shouldYieldToCV(float cvIn) const
  {
    // Schmitt threshold in scene-index space. 0.5 means "half a
    // scene step at the entry Gain and bank size." With Gain=0
    // the delta is 0 -> never trips -> CV stays inert. With a
    // small bank N the threshold in input-fraction space is wider
    // (0.5/N), so a sparse bank tolerates more CV drift before
    // releasing manual; a dense bank is more responsive.
    float delta_out_space =
      mGainAtEntry * (cvIn - mCVInputAtEntry) * (float)mSceneCount;
    return fabsf(delta_out_space) > 0.5f;
  }

  void SceneIndexArbiter::process()
  {
    float *buf = mInput.buffer();
    float cvIn = buf[FRAMELENGTH - 1];
    mLastCVSample = cvIn;

    float gain = mGain.target();
    float bias = mBias.target();

    if (mState == kTrackingManual && shouldYieldToCV(cvIn))
    {
      mState = kTrackingCV;
    }

    int idx = computeEffectiveIndex(cvIn, gain, bias);
    if (idx != mLastFiredIndex)
    {
      mLastFiredIndex = idx;
      mTransitionPending = true;
    }

    // Fill output buffer with float index for downstream Inlets
    // (morpher IndexA/IndexB) and for fader animation. Constant
    // across the frame: scene transitions are step changes, not
    // per-sample modulation.
    simd_set(mOutput.buffer(), FRAMELENGTH, (float)idx);
    mOutput.mIsConstant = true;
  }

  void SceneIndexArbiter::hardSetBias(float value)
  {
    // Normalized clip: Bias is a [0, 1] fraction-of-bank.
    if (value < 0.0f) value = 0.0f;
    else if (value > 1.0f) value = 1.0f;

    mBias.hardSet(value);
    mCVInputAtEntry = mLastCVSample;
    mGainAtEntry = mGain.target();
    mState = kTrackingManual;

    int idx = computeEffectiveIndex(mLastCVSample, mGainAtEntry, value);
    if (idx != mLastFiredIndex)
    {
      mLastFiredIndex = idx;
      mTransitionPending = true;
    }
  }

  void SceneIndexArbiter::setSceneCount(int n)
  {
    if (n < 0) n = 0;
    if (n == mSceneCount) return;
    mSceneCount = n;
    // Bias is normalized; doesn't shrink with N. But the effective
    // output index DOES change when N changes (round(Bias * N) is
    // a different integer for a different N), so re-evaluate and
    // fire a transition if needed so the morpher rebuild (Lua
    // side, triggered separately) and the UI redraw stay in sync.
    int idx = computeEffectiveIndex(mLastCVSample, mGain.target(),
                                     mBias.target());
    if (idx != mLastFiredIndex)
    {
      mLastFiredIndex = idx;
      mTransitionPending = true;
    }
  }

  bool SceneIndexArbiter::consumeTransitionFlag()
  {
    if (mTransitionPending)
    {
      mTransitionPending = false;
      return true;
    }
    return false;
  }

} /* namespace od */

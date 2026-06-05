#include <od/objects/control/SceneIndexArbiter.h>
#include <od/config.h>
#include <hal/constants.h>
#include <hal/simd.h>
#include <math.h>

namespace od
{

  // CV input is in 301 internal units where 1.0 == FULLSCALE_IN_VOLTS
  // (= 10V hardware). To make Gain feel like "scenes per volt" --
  // the v/oct-adjacent convention users expect from modular CV
  // sources -- we multiply cvIn by FULLSCALE_IN_VOLTS before
  // scaling by Gain. With this:
  //   Gain = 1   -> 1 scene per volt
  //   Gain = 12  -> 12 scenes per volt (one scene per semitone in
  //                 v/oct land; 1V = full octave traversal)
  //   Gain = 16  -> 16 scenes per volt (full bank from a 1V swing)
  // The Schmitt threshold (0.5 in scene-index space) uses the same
  // multiplier so its trip point is consistent.
  static constexpr float kVoltsScale = FULLSCALE_IN_VOLTS;

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
    float candidate;
    if (mState == kTrackingCV)
    {
      // Gain is in scenes-per-volt; kVoltsScale converts the
      // internal CV value (1.0 = 10V) into volts.
      candidate = gain * cvIn * kVoltsScale;
    }
    else
    {
      candidate = bias;
    }
    int idx = (int)floorf(candidate + 0.5f);  // round-half-up
    return clipIndex(idx);
  }

  bool SceneIndexArbiter::shouldYieldToCV(float cvIn) const
  {
    // Schmitt threshold in scene-index space using volts-scaled
    // delta so 0.5 means "half a scene step at the entry Gain."
    float delta_out_space =
      mGainAtEntry * (cvIn - mCVInputAtEntry) * kVoltsScale;
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
    if (value < 0.0f) value = 0.0f;
    else if (value > (float)mSceneCount) value = (float)mSceneCount;

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
    mSceneCount = n;
    float bias = mBias.target();
    if (bias > (float)n)
    {
      mBias.hardSet((float)n);
      mTransitionPending = true;
    }
    if (mLastFiredIndex > n)
    {
      mLastFiredIndex = n;
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

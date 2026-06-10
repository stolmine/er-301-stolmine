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
    addOutput(mOutputNorm);
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
    //
    // Null-vs-first-scene boundary falls out of the round() math:
    // idx == 0 (null) for normalized * N < 0.5, idx == 1 for
    // normalized * N >= 0.5. So the null region's fader width is
    // 0.5 / N -- proportional to bank size, no hardcoded cutoff.
    // N=8: null occupies [0, 0.0625) of the fader; N=16: [0,
    // 0.03125). Lua-side label check tests idx < 1 against this
    // same integer, so the visual fallback ("show role label not
    // scene 1") tracks the same boundary.
    // GainBias semantics in both states: out = bias + gain * cvIn,
    // matching Offset / Adder / GainBias-driven builtin units. Bias
    // is the user's manual home, CV adds on top. With a unipolar
    // positive CV source the output always rides at or above bias;
    // with a bipolar CV source it swings symmetrically around bias.
    // State machine is now introspection-only (consumeTransitionFlag
    // + getState); it does not affect output. The rounding alone
    // provides the deadband against CV noise (sub-scene jitter
    // doesn't change round(normalized * N)).
    float normalized = bias + gain * cvIn;
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

    // Integer-index output for the morpher.
    simd_set(mOutput.buffer(), FRAMELENGTH, (float)idx);
    mOutput.mIsConstant = true;

    // Normalized effective position [0, 1] for the M2/M3 fader's
    // range-bar visualization (MinMax reads this instead of the
    // integer Out so the swing renders in the fader's coord system).
    // Same GainBias formula as the integer-index computation, just
    // pre-rounded so the indicator can dwell between scene steps.
    float effectiveNorm = bias + gain * cvIn;
    if (effectiveNorm < 0.0f) effectiveNorm = 0.0f;
    else if (effectiveNorm > 1.0f) effectiveNorm = 1.0f;
    simd_set(mOutputNorm.buffer(), FRAMELENGTH, effectiveNorm);
    mOutputNorm.mIsConstant = true;
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

    // Re-anchor Bias so the currently-selected scene stays selected
    // through the bank-size change. Without this, Bias at e.g. 0.7
    // with N=3 (output = round(2.1) = 2) drifts to scene 3 when N
    // grows to 4 (output = round(2.8) = 3), so adding a new scene
    // looked like it auto-selected the new one. Normalize the old
    // integer output to the new bank scale: newBias = oldIdx / N'.
    // Affects only Manual-state output audibly; in Tracking-CV the
    // gain*cvIn product still rescales naturally, but Bias preserves
    // the user's manual home position for when they yield back.
    int oldIdx = mLastFiredIndex;
    mSceneCount = n;
    if (n > 0 && oldIdx > 0)
    {
      int preservedIdx = (oldIdx > n) ? n : oldIdx;
      mBias.hardSet((float)preservedIdx / (float)n);
    }
    else if (n == 0)
    {
      mBias.hardSet(0.0f);
    }

    // Re-evaluate effective output. With Bias re-anchored, idx
    // should usually equal oldIdx (or n if oldIdx was clipped down
    // on bank shrink). CV-state output may still shift since
    // gain*cvIn*N rescales naturally; that's expected.
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

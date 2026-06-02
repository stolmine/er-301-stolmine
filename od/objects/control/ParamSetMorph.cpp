#include <od/objects/control/ParamSetMorph.h>
#include <od/config.h>
#include <od/extras/Conversions.h>
#include <algorithm>

namespace od
{

    ParamSetMorph::ParamSetMorph()
    {
        addParameter(mWeight);
        addInput(mCV);
    }

    ParamSetMorph::~ParamSetMorph()
    {
    }

    void ParamSetMorph::process()
    {
        // Audio-rate weight drive. Two CV->weight mappings:
        //
        //   Vee mode (scene crossfader): CV is interpreted as a
        //   bipolar bias in [-1, +1] and stored verbatim into
        //   mWeight. VEE items read it as bias directly:
        //     bias=+1 -> full sceneA, bias=-1 -> full sceneB,
        //     bias= 0 -> audio at base (no scene contribution).
        //
        //   Linear mode (the legacy PinView path): CV in [-1, +1]
        //   maps to mWeight in [0, 1] via (1 - cv) * 0.5 so the
        //   morpher's apply does the standard linear blend
        //     (1-w)*start + w*end
        //   between cached / live endpoints. Unchanged from before
        //   the VEE work landed.
        //
        // Unconnected mCV -> Inlet::buffer() returns ZeroOutput
        // (sample=0). Vee: bias=0 -> audio at base. Linear:
        // weight=0.5 -> midpoint. Guard with isConnected so
        // PinView's encoder-driven mWeight isn't overwritten on
        // its own morpher (which doesn't connect this inlet).
        if (mCV.isConnected())
        {
            float *buf = mCV.buffer();
            float sample = buf[FRAMELENGTH - 1];
            float weight;
            if (mVeeMode)
            {
                weight = sample;
                if (weight < -1.0f) weight = -1.0f;
                else if (weight > 1.0f) weight = 1.0f;
            }
            else
            {
                weight = (1.0f - sample) * 0.5f;
                if (weight < 0.0f) weight = 0.0f;
                else if (weight > 1.0f) weight = 1.0f;
            }
            mWeight.hardSet(weight);
        }
        apply();
    }

    void ParamSetMorph::apply()
    {
        float w2 = mWeight.target();
        // Live-Parameter items may move their endpoints every frame
        // (the scene crossfader's source-of-truth is the scene's
        // stored Parameter which the user is encoder-editing in
        // authoring). Disable the weight-unchanged short-circuit
        // when any such item is present.
        bool needApply = mHasLiveItems || mUpdateNeeded ||
                         fabs(w2 - mPreviousWeight) > 1e-8f;
        if (needApply)
        {
            float w1 = 1.0f - w2;

            for (Item &item : mItems)
            {
                bool isDB = item.param->mEnableDecibelMorph;

                if (item.kind == Item::kVee4)
                {
                    // VEE blend. w2 is the bipolar bias in [-1, +1].
                    // sceneA stored in startParam, sceneB in endParam,
                    // base in baseParam.
                    float bias = w2;
                    float base = isDB ? toDecibels(item.baseParam->target())
                                      : item.baseParam->target();
                    float x;
                    if (bias > 0.0f && item.startParam != nullptr)
                    {
                        float sceneA = isDB
                            ? toDecibels(item.startParam->target())
                            : item.startParam->target();
                        x = (1.0f - bias) * base + bias * sceneA;
                    }
                    else if (bias < 0.0f && item.endParam != nullptr)
                    {
                        float sceneB = isDB
                            ? toDecibels(item.endParam->target())
                            : item.endParam->target();
                        float absB = -bias;
                        x = (1.0f - absB) * base + absB * sceneB;
                    }
                    else
                    {
                        x = base;
                    }
                    // hardSet instead of softSet: the morpher's
                    // output should track bias one-to-one so the
                    // user can crossfade as fast as they can turn
                    // the encoder. Click-protection on abrupt
                    // assignment changes is the user's
                    // responsibility -- if they want a ramp,
                    // they drop a slew unit into the CV input
                    // subchain. See TODO.md "Eliminate or make-
                    // optional morph slew".
                    item.param->hardSet(isDB ? fromDecibels(x) : x);
                    continue;
                }

                // 2-arg / 3-arg linear blend path. Same reasoning
                // as the VEE branch above: hardSet so the morph
                // output tracks bias without an internal ramp.
                float startVal, endVal;
                if (item.startParam != nullptr)
                {
                    startVal = isDB ? toDecibels(item.startParam->target())
                                    : item.startParam->target();
                }
                else
                {
                    startVal = item.startValue;
                }

                if (item.endParam != nullptr)
                {
                    endVal = isDB ? toDecibels(item.endParam->target())
                                  : item.endParam->target();
                }
                else
                {
                    endVal = item.endValue;
                }

                float x = w1 * startVal + w2 * endVal;
                if (isDB)
                {
                    item.param->hardSet(fromDecibels(x));
                }
                else
                {
                    item.param->hardSet(x);
                }
            }

            mUpdateNeeded = false;
            mPreviousWeight = w2;
        }
    }

    void ParamSetMorph::reset()
    {
        mWeight.hardSet(0);
        for (Item &item : mItems)
        {
            // Only the 2-arg cached variant has anything to
            // snapshot. Live (3-arg) + VEE (4-arg) read their
            // endpoints from Parameters every apply.
            if (item.kind != Item::kCached2) continue;

            if (item.param->mEnableDecibelMorph)
            {
                item.startValue = toDecibels(item.param->target());
            }
            else
            {
                item.startValue = item.param->target();
            }
        }
        mUpdateNeeded = true;
    }

    ParamSetMorph::Item::Item(Parameter *p, float _endValue) : param(p)
    {
        kind = kCached2;
        if (param != nullptr)
        {
            param->attach();
            if (param->mEnableDecibelMorph)
            {
                startValue = toDecibels(param->target());
                endValue = toDecibels(_endValue);
            }
            else
            {
                startValue = param->target();
                endValue = _endValue;
            }
        }
    }

    // 3-arg ctor: store live Parameter pointers for both endpoints.
    // apply() reads target() on each every frame so the scene
    // crossfader picks up encoder edits in real time without a
    // rebuild. Attaches all three (target + start + end) and
    // releases in ~Item.
    ParamSetMorph::Item::Item(Parameter *_target, Parameter *_startParam, Parameter *_endParam)
        : param(_target), startParam(_startParam), endParam(_endParam)
    {
        kind = kLive3;
        if (param != nullptr) param->attach();
        if (startParam != nullptr) startParam->attach();
        if (endParam != nullptr) endParam->attach();
    }

    // 4-arg VEE ctor: base + scene A + scene B, all live. apply
    // picks active scene per-frame from the sign of mWeight (the
    // bipolar bias). scenes stored in startParam (=A) and
    // endParam (=B) to reuse the existing fields.
    ParamSetMorph::Item::Item(Parameter *_target, Parameter *_baseParam,
                              Parameter *_sceneA, Parameter *_sceneB)
        : param(_target), startParam(_sceneA), endParam(_sceneB), baseParam(_baseParam)
    {
        kind = kVee4;
        if (param != nullptr) param->attach();
        if (baseParam != nullptr) baseParam->attach();
        if (startParam != nullptr) startParam->attach();
        if (endParam != nullptr) endParam->attach();
    }

    ParamSetMorph::Item::Item(ParamSetMorph::Item &&other)
        : kind(other.kind),
          param(other.param),
          startParam(other.startParam),
          endParam(other.endParam),
          baseParam(other.baseParam),
          startValue(other.startValue),
          endValue(other.endValue)
    {
        other.param = nullptr;
        other.startParam = nullptr;
        other.endParam = nullptr;
        other.baseParam = nullptr;
    }

    ParamSetMorph::Item::~Item()
    {
        if (param != nullptr) param->release();
        if (startParam != nullptr) startParam->release();
        if (endParam != nullptr) endParam->release();
        if (baseParam != nullptr) baseParam->release();
    }

    bool ParamSetMorph::Item::operator==(const Parameter *x)
    {
        return param == x;
    }

    ParamSetMorph::Item &ParamSetMorph::Item::operator=(
        ParamSetMorph::Item &&other)
    {
        if (this != &other)
        {
            if (param != nullptr) param->release();
            if (startParam != nullptr) startParam->release();
            if (endParam != nullptr) endParam->release();
            if (baseParam != nullptr) baseParam->release();

            kind = other.kind;
            param = other.param;
            startParam = other.startParam;
            endParam = other.endParam;
            baseParam = other.baseParam;
            startValue = other.startValue;
            endValue = other.endValue;

            other.param = nullptr;
            other.startParam = nullptr;
            other.endParam = nullptr;
            other.baseParam = nullptr;
        }

        return *this;
    }

    void ParamSetMorph::add(Parameter *param, float endValue)
    {
        auto i = std::find(mItems.begin(), mItems.end(), param);
        if (i == mItems.end())
        {
            mItems.emplace_back(param, endValue);
            mUpdateNeeded = true;
        }
    }

    void ParamSetMorph::add(Parameter *target, Parameter *startParam, Parameter *endParam)
    {
        auto i = std::find(mItems.begin(), mItems.end(), target);
        if (i == mItems.end())
        {
            mItems.emplace_back(target, startParam, endParam);
            mUpdateNeeded = true;
            mHasLiveItems = true;
        }
    }

    void ParamSetMorph::addVee(Parameter *target, Parameter *baseParam,
                                Parameter *sceneA, Parameter *sceneB)
    {
        auto i = std::find(mItems.begin(), mItems.end(), target);
        if (i == mItems.end())
        {
            mItems.emplace_back(target, baseParam, sceneA, sceneB);
            mUpdateNeeded = true;
            mHasLiveItems = true;
            mVeeMode = true;
        }
    }

    void ParamSetMorph::remove(Parameter *param)
    {
        auto i = std::find(mItems.begin(), mItems.end(), param);
        if (i != mItems.end())
        {
            mItems.erase(i);
            mUpdateNeeded = true;
            // Recompute flags in case the removed item was the
            // only one of its kind.
            mHasLiveItems = false;
            mVeeMode = false;
            for (Item &item : mItems)
            {
                if (item.kind == Item::kLive3 || item.kind == Item::kVee4)
                {
                    mHasLiveItems = true;
                }
                if (item.kind == Item::kVee4)
                {
                    mVeeMode = true;
                }
            }
        }
    }

    void ParamSetMorph::clear()
    {
        mItems.clear();
        mHasLiveItems = false;
        mVeeMode = false;
        hardSet(0.0f);
    }

    int ParamSetMorph::size()
    {
        return mItems.size();
    }

    void ParamSetMorph::softSet(float x)
    {
        mWeight.softSet(x);
        mUpdateNeeded = true;
    }

    void ParamSetMorph::hardSet(float x)
    {
        mWeight.hardSet(x);
        mUpdateNeeded = true;
    }

} /* namespace od */

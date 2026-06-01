#include <od/objects/control/ParamSetMorph.h>
#include <od/extras/Conversions.h>
#include <algorithm>

namespace od
{

    ParamSetMorph::ParamSetMorph()
    {
        addParameter(mWeight);
    }

    ParamSetMorph::~ParamSetMorph()
    {
    }

    void ParamSetMorph::process()
    {
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
                float startVal, endVal;
                bool isDB = item.param->mEnableDecibelMorph;

                if (item.startParam != nullptr)
                {
                    // 3-arg variant: read live from start Parameter
                    startVal = isDB ? toDecibels(item.startParam->target())
                                    : item.startParam->target();
                }
                else
                {
                    // 2-arg variant: use cached start value (already
                    // in dB-space if isDB; see Item ctor)
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
                    item.param->softSet(fromDecibels(x));
                }
                else
                {
                    item.param->softSet(x);
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
            // 3-arg variant reads startParam->target() live in
            // apply(); nothing to snapshot.
            if (item.startParam != nullptr) continue;

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
        if (param != nullptr)
        {
            param->attach();
        }
        if (startParam != nullptr)
        {
            startParam->attach();
        }
        if (endParam != nullptr)
        {
            endParam->attach();
        }
    }

    ParamSetMorph::Item::Item(ParamSetMorph::Item &&other)
        : param(other.param),
          startParam(other.startParam),
          endParam(other.endParam),
          startValue(other.startValue),
          endValue(other.endValue)
    {
        other.param = nullptr;
        other.startParam = nullptr;
        other.endParam = nullptr;
    }

    ParamSetMorph::Item::~Item()
    {
        if (param != nullptr)
        {
            param->release();
        }
        if (startParam != nullptr)
        {
            startParam->release();
        }
        if (endParam != nullptr)
        {
            endParam->release();
        }
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
            if (param != nullptr)
            {
                param->release();
            }
            if (startParam != nullptr)
            {
                startParam->release();
            }
            if (endParam != nullptr)
            {
                endParam->release();
            }

            param = other.param;
            startParam = other.startParam;
            endParam = other.endParam;
            startValue = other.startValue;
            endValue = other.endValue;

            other.param = nullptr;
            other.startParam = nullptr;
            other.endParam = nullptr;
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

    void ParamSetMorph::remove(Parameter *param)
    {
        auto i = std::find(mItems.begin(), mItems.end(), param);
        if (i != mItems.end())
        {
            mItems.erase(i);
            mUpdateNeeded = true;
            // Recompute the live-items flag in case the removed
            // item was the only 3-arg variant.
            mHasLiveItems = false;
            for (Item &item : mItems)
            {
                if (item.startParam != nullptr || item.endParam != nullptr)
                {
                    mHasLiveItems = true;
                    break;
                }
            }
        }
    }

    void ParamSetMorph::clear()
    {
        mItems.clear();
        mHasLiveItems = false;
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

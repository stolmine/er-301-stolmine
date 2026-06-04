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
        addInput(mIndexA);
        addInput(mIndexB);
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
                    // Linear bipolar A<->B crossfade.
                    //   wA = (1 + bias) / 2     -- bias = +1 -> A only
                    //   wB = 1 - wA             -- bias = -1 -> B only
                    //   x  = wA * sceneA + wB * sceneB
                    //
                    // Unassigned endpoints are filled with baseParam
                    // by Chain.Root._buildSceneMorphItems, so a
                    // sweep "into" an unassigned (or blank-delta)
                    // slot reveals base. Same affordance the
                    // Elektron lineage uses: the escape from scene
                    // contribution is a slot you can stage instead
                    // of a magic midpoint.
                    //
                    // baseParam stays in the Item for ABI stability
                    // (addVee is the public ctor); apply doesn't
                    // need it -- the caller already routed base
                    // through start/end when it wanted base on
                    // that side.
                    //
                    // hardSet (no morpher-internal ramp): see
                    // commit `de66fcd` reasoning -- the user adds
                    // slew in the CV input subchain if they want
                    // click protection on abrupt assignment
                    // changes.
                    float sceneA = isDB
                        ? toDecibels(item.startParam->target())
                        : item.startParam->target();
                    float sceneB = isDB
                        ? toDecibels(item.endParam->target())
                        : item.endParam->target();
                    float wA = (w2 + 1.0f) * 0.5f;
                    float wB = 1.0f - wA;
                    float x = wA * sceneA + wB * sceneB;
                    item.param->hardSet(isDB ? fromDecibels(x) : x);
                    continue;
                }

                if (item.kind == Item::kVeeIndexed)
                {
                    // v1.1 live A/B selection. Same wA/wB blend as
                    // kVee4 but A and B endpoints are resolved per
                    // frame from the IndexA/IndexB Inlets.
                    //
                    // Index 0 = unassigned (baseParam). Indices
                    // 1..N pick scenes[idx-1] which was wired by
                    // Chain.Root._buildSceneMorphItems to the
                    // scene's stored Parameter (or to baseParam if
                    // that scene has no delta on this control).
                    //
                    // Unconnected IndexA / IndexB Inlets return
                    // ZeroOutput -> sample 0 -> baseParam, matching
                    // the v1.0 "unassigned A or B leaves audio at
                    // base on that side" semantic.
                    int N = (int)item.scenes.size();
                    float aSample = mIndexA.buffer()[FRAMELENGTH - 1];
                    float bSample = mIndexB.buffer()[FRAMELENGTH - 1];
                    int idxA = (int)floorf(aSample + 0.5f);
                    int idxB = (int)floorf(bSample + 0.5f);
                    if (idxA < 0) idxA = 0;
                    else if (idxA > N) idxA = N;
                    if (idxB < 0) idxB = 0;
                    else if (idxB > N) idxB = N;

                    Parameter *paramA = (idxA == 0)
                        ? item.baseParam
                        : item.scenes[idxA - 1];
                    Parameter *paramB = (idxB == 0)
                        ? item.baseParam
                        : item.scenes[idxB - 1];

                    float sceneA = isDB
                        ? toDecibels(paramA->target())
                        : paramA->target();
                    float sceneB = isDB
                        ? toDecibels(paramB->target())
                        : paramB->target();
                    float wA = (w2 + 1.0f) * 0.5f;
                    float wB = 1.0f - wA;
                    float x = wA * sceneA + wB * sceneB;
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

    // v1.1 indexed-VEE ctor: per-scene Parameter vector + base.
    // apply picks scene endpoints per-frame from IndexA/IndexB
    // Inlets. attach()/release() lifecycle on every stored
    // Parameter pointer matches the other kinds.
    ParamSetMorph::Item::Item(Parameter *_target, Parameter *_baseParam,
                              std::vector<Parameter *> _scenes)
        : param(_target), baseParam(_baseParam), scenes(std::move(_scenes))
    {
        kind = kVeeIndexed;
        if (param != nullptr) param->attach();
        if (baseParam != nullptr) baseParam->attach();
        for (Parameter *p : scenes)
        {
            if (p != nullptr) p->attach();
        }
    }

    ParamSetMorph::Item::Item(ParamSetMorph::Item &&other)
        : kind(other.kind),
          param(other.param),
          startParam(other.startParam),
          endParam(other.endParam),
          baseParam(other.baseParam),
          startValue(other.startValue),
          endValue(other.endValue),
          scenes(std::move(other.scenes))
    {
        other.param = nullptr;
        other.startParam = nullptr;
        other.endParam = nullptr;
        other.baseParam = nullptr;
        // moved-from vector is empty; no double-release in ~other
    }

    ParamSetMorph::Item::~Item()
    {
        if (param != nullptr) param->release();
        if (startParam != nullptr) startParam->release();
        if (endParam != nullptr) endParam->release();
        if (baseParam != nullptr) baseParam->release();
        for (Parameter *p : scenes)
        {
            if (p != nullptr) p->release();
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
            if (param != nullptr) param->release();
            if (startParam != nullptr) startParam->release();
            if (endParam != nullptr) endParam->release();
            if (baseParam != nullptr) baseParam->release();
            for (Parameter *p : scenes)
            {
                if (p != nullptr) p->release();
            }

            kind = other.kind;
            param = other.param;
            startParam = other.startParam;
            endParam = other.endParam;
            baseParam = other.baseParam;
            startValue = other.startValue;
            endValue = other.endValue;
            scenes = std::move(other.scenes);

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

    void ParamSetMorph::addVeeIndexed(Parameter *target, Parameter *baseParam,
                                       std::vector<Parameter *> scenes)
    {
        auto i = std::find(mItems.begin(), mItems.end(), target);
        if (i == mItems.end())
        {
            mItems.emplace_back(target, baseParam, std::move(scenes));
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
            // Recompute mHasLiveItems in case the removed item was
            // the only Live/Vee item.
            //
            // mVeeMode is intentionally NOT recomputed here. Owners
            // can pin it via setVeeMode -- once a morpher is wired
            // into a scene-cv pipeline that expects bipolar
            // semantics, removing all Items shouldn't silently
            // collapse the live "Weight" Parameter back to legacy
            // linear [0,1] mapping. addVee still flips it on as
            // before for the auto-detection case.
            mHasLiveItems = false;
            for (Item &item : mItems)
            {
                if (item.kind == Item::kLive3 ||
                    item.kind == Item::kVee4 ||
                    item.kind == Item::kVeeIndexed)
                {
                    mHasLiveItems = true;
                }
            }
        }
    }

    void ParamSetMorph::clear()
    {
        mItems.clear();
        mHasLiveItems = false;
        // mVeeMode intentionally NOT reset here. See setVeeMode
        // and remove() for the same reasoning: once an owner has
        // pinned the morpher into Vee semantics, a transient clear
        // (rebuild between scene assignments) shouldn't drop the
        // mode and silently re-remap the live "Weight" Parameter.
        hardSet(0.0f);
    }

    void ParamSetMorph::setVeeMode(bool on)
    {
        mVeeMode = on;
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

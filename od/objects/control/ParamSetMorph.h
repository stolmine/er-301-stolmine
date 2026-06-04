#pragma once

#include <od/objects/Object.h>
#include <od/objects/Inlet.h>
#include <vector>

namespace od
{

    class ParamSetMorph : public Object
    {
    public:
        ParamSetMorph();
        virtual ~ParamSetMorph();

#ifndef SWIGLUA
        virtual void process();
        void apply();
        Parameter mWeight{"Weight", 0.0f};
        // CV input for audio-rate weight drive (scene crossfader).
        // process() reads the last sample, clamps [0,1], hardSets
        // mWeight, calls apply(). Unconnected -> Inlet::buffer()
        // returns ZeroOutput so weight stays at 0 = full A endpoint;
        // PinView's morpher (also reaches process via its task but
        // historically didn't need it) gets a no-op since it never
        // connects this inlet.
        Inlet mCV{"CV"};
        // v1.1 live A/B scene-index inputs for kVeeIndexed items.
        // Each connects to a SceneIndexArbiter's mOutput; apply()
        // reads buffer[FRAMELENGTH-1], rounds, and clips to the
        // item's scenes vector size. Unconnected -> ZeroOutput ->
        // index 0 -> baseParam (= "unassigned" semantic, matching
        // v1.0's behavior for an unassigned crossfader endpoint).
        // Non-kVeeIndexed items ignore these inlets entirely.
        Inlet mIndexA{"IndexA"};
        Inlet mIndexB{"IndexB"};
#endif

        void add(Parameter *param, float endValue);
        // Live-Parameter variant: both endpoints read target() each
        // frame instead of being cached at add-time. Used by the
        // scene crossfader so a scene's stored value (also a
        // Parameter) tracks live during scene authoring. PinView
        // keeps the cached-float 2-arg path above.
        void add(Parameter *target, Parameter *startParam, Parameter *endParam);
        // Bipolar linear crossfade variant for the scene system.
        // mWeight is the M1 bias in [-1, +1].
        //   wA = (1 + bias) / 2,   wB = 1 - wA
        //   audio = wA * sceneA + wB * sceneB
        // bias = +1 -> all A, -1 -> all B, 0 -> 50/50 mix. Direct
        // A<->B path (no through-zero detour through base) --
        // matches the Elektron-lineage crossfader convention.
        // Escape from scene contribution is via an unassigned
        // (or empty-delta) endpoint: Chain.Root collapses those
        // to baseParam before calling, so a sweep into an
        // unassigned slot reveals the user's pre-scene base.
        // baseParam is retained in the signature for ABI
        // stability but no longer consulted in apply().
        void addVee(Parameter *target, Parameter *baseParam,
                    Parameter *sceneA, Parameter *sceneB);
        // v1.1 live-indexed VEE: scenes vector holds N Parameters
        // (one per scene in the bank, in index order 1..N). apply()
        // reads mIndexA / mIndexB Inlets each frame, rounds, clips
        // to [0, N], selects baseParam for idx==0 (unassigned) or
        // scenes[idx-1] otherwise, and runs the same wA/wB blend
        // as addVee. Lets A/B scene assignment be driven live by
        // CV through SceneIndexArbiter without per-transition
        // morpher rebuilds.
        //
        // _scenes is moved-from (cheap pointer-vector move). Each
        // scene Parameter is attach()'d in the Item ctor and
        // released in ~Item, same lifecycle as the other endpoint
        // fields.
        void addVeeIndexed(Parameter *target, Parameter *baseParam,
                            std::vector<Parameter *> scenes);
        void remove(Parameter *param);
        void clear();
        int size();

        void softSet(float x);
        void hardSet(float x);
        void reset();

        // Force the CV -> mWeight mapping mode. Normally toggled by
        // add/addVee/clear/remove based on Item kinds. Scene-cv
        // callers wire the morpher's CV inlet before any Items have
        // been built (Performance view comes up with zero deltas);
        // calling setVeeMode(true) keeps process() in bipolar
        // pass-through so the live "Weight" Parameter that views
        // read for indicators is always in [-1, +1] semantics,
        // never the legacy linear [0, 1] remap.
        void setVeeMode(bool on);

    protected:
        struct Item
        {
            // 2-arg ctor: cache startValue from param->target() at
            // add-time. PinView path.
            Item(Parameter *param, float endValue);
            // 3-arg ctor: store start + end Parameter pointers,
            // read live each frame. Scene crossfader path.
            Item(Parameter *target, Parameter *startParam, Parameter *endParam);
            // 4-arg VEE ctor: base + two scene endpoints, all live.
            // Active scene picked per-frame from weight sign.
            Item(Parameter *target, Parameter *baseParam,
                 Parameter *sceneA, Parameter *sceneB);
            // v1.1 indexed-VEE ctor: base + per-scene Parameter
            // vector. Active scene pair picked per-frame from
            // IndexA/IndexB Inlets in apply().
            Item(Parameter *target, Parameter *baseParam,
                 std::vector<Parameter *> _scenes);
            Item(Item &&other); // move ctor
            virtual ~Item();
            bool operator==(const Parameter *param);
            Item &operator=(Item &&other); // move assignment

            // Kind tag for the apply() branch. Cheap enum so we
            // don't have to keep null-checking three pointer
            // combinations.
            enum Kind { kCached2, kLive3, kVee4, kVeeIndexed };
            Kind kind = kCached2;

            Parameter *param;        // target -- the param softSet by apply
            Parameter *startParam = 0; // live-start (3-arg) or nullptr (2-arg)
            Parameter *endParam = 0;   // live-end (3-arg) or nullptr (2-arg)
            Parameter *baseParam = 0;  // base (4-arg VEE / indexed) or nullptr
            float startValue;          // used when startParam == 0
            float endValue;            // used when endParam == 0
            // kVeeIndexed only: per-scene Parameters in index
            // order. Length = current bank size N; index 0 in the
            // Inlet value maps to baseParam (unassigned), indices
            // 1..N map to scenes[idx-1]. Empty for other kinds.
            std::vector<Parameter *> scenes;
        };
        std::vector<Item> mItems;
        float mPreviousWeight = 0.0f;
        bool mUpdateNeeded = false;
        // True when at least one Item uses live-Parameter endpoints.
        // apply() can't short-circuit on (weight unchanged) when this
        // is set because the endpoint values may move every frame.
        bool mHasLiveItems = false;
        // True once at least one VEE item has been added (set by
        // addVee, cleared on clear). Drives the CV -> mWeight
        // remap in process(): Vee mode passes CV through as
        // bipolar bias [-1, +1]; linear mode remaps to [0, 1].
        bool mVeeMode = false;
    };

} /* namespace od */

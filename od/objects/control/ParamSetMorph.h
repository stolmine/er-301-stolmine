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
#endif

        void add(Parameter *param, float endValue);
        // Live-Parameter variant: both endpoints read target() each
        // frame instead of being cached at add-time. Used by the
        // scene crossfader so a scene's stored value (also a
        // Parameter) tracks live during scene authoring. PinView
        // keeps the cached-float 2-arg path above.
        void add(Parameter *target, Parameter *startParam, Parameter *endParam);
        // VEE-blend variant for the scene crossfader. mWeight is
        // bipolar in [-1, +1] (the M1 bias).
        //   weight > 0  audio = (1 - w) * base + w * sceneA
        //   weight < 0  audio = (1 + w) * base + |w| * sceneB
        //   weight == 0 audio = base
        // Differs from the linear (2-arg / 3-arg) variants: bias at
        // center leaves audio sitting on the user's pre-scene value,
        // and scene contribution ramps in as the user pulls bias
        // toward an endpoint. Scenes never mix unless the user
        // actively crosses the midpoint.
        void addVee(Parameter *target, Parameter *baseParam,
                    Parameter *sceneA, Parameter *sceneB);
        void remove(Parameter *param);
        void clear();
        int size();

        void softSet(float x);
        void hardSet(float x);
        void reset();

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
            Item(Item &&other); // move ctor
            virtual ~Item();
            bool operator==(const Parameter *param);
            Item &operator=(Item &&other); // move assignment

            // Kind tag for the apply() branch. Cheap enum so we
            // don't have to keep null-checking three pointer
            // combinations.
            enum Kind { kCached2, kLive3, kVee4 };
            Kind kind = kCached2;

            Parameter *param;        // target -- the param softSet by apply
            Parameter *startParam = 0; // live-start (3-arg) or nullptr (2-arg)
            Parameter *endParam = 0;   // live-end (3-arg) or nullptr (2-arg)
            Parameter *baseParam = 0;  // base (4-arg VEE) or nullptr
            float startValue;          // used when startParam == 0
            float endValue;            // used when endParam == 0
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

#pragma once

#include <od/objects/Object.h>
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
#endif

        void add(Parameter *param, float endValue);
        // Live-Parameter variant: both endpoints read target() each
        // frame instead of being cached at add-time. Used by the
        // scene crossfader so a scene's stored value (also a
        // Parameter) tracks live during scene authoring. PinView
        // keeps the cached-float 2-arg path above.
        void add(Parameter *target, Parameter *startParam, Parameter *endParam);
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
            Item(Item &&other); // move ctor
            virtual ~Item();
            bool operator==(const Parameter *param);
            Item &operator=(Item &&other); // move assignment

            Parameter *param;        // target -- the param softSet by apply
            Parameter *startParam = 0; // live-start (3-arg) or nullptr (2-arg)
            Parameter *endParam = 0;   // live-end (3-arg) or nullptr (2-arg)
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
    };

} /* namespace od */

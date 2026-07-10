#pragma once

// [stol:infra-crash-diag-flight-recorder]
// A small fixed-size ring of recent crash-trigger events (unit insert, preset /
// quicksave load, engine/mode switch). Every historical hardware crash in the
// habitat lore was user-action-triggered, so the last few actions before a trap
// are the highest-value context a report can carry.
//
// The ring is a plain C++ struct with no heap and no locks, so the sibling's ARM
// exception hook can read it from an abort context (read-only). Recording is
// gated by an "armed" flag wired to the enableCrashDiagnostics setting: when
// disarmed, record() is a single branch and touches nothing (zero cost when off).

#include <stdint.h>
#include <stddef.h>

namespace od
{
  class FlightRecorder
  {
  public:
    static const int kCapacity = 32;
    static const int kLabelLen = 48; // includes NUL

    struct Event
    {
      float timestamp;            // seconds since boot (wallclock)
      char label[kLabelLen];      // short human label, NUL-terminated
    };

    FlightRecorder();

    // Arm/disarm recording. When disarmed, record() is a no-op.
    void arm(bool on) { mArmed = on; }
    bool armed() const { return mArmed; }

    // Append an event. Ignored when disarmed. Safe to call from Lua seams.
    void record(const char *label);

    // Drop all events (keeps the armed state).
    void clear();

    // Number of events currently held (<= kCapacity).
    int count() const;

    // Fetch the i-th event in chronological order (0 == oldest). Returns nullptr
    // if out of range.
    const Event *at(int i) const;

  private:
    Event mRing[kCapacity];
    int mHead = 0;   // next write slot
    int mCount = 0;  // number of valid entries
    bool mArmed = false;
  };

  // Process-wide singleton (both the Lua seams and the abort hook use this one).
  FlightRecorder &flightRecorder();
}

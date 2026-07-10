// [stol:infra-crash-diag-flight-recorder]
#include <od/extras/FlightRecorder.h>
#include <hal/timing.h>
#include <string.h>

namespace od
{
  FlightRecorder::FlightRecorder()
  {
    clear();
  }

  void FlightRecorder::record(const char *label)
  {
    if (!mArmed)
    {
      return;
    }
    Event &e = mRing[mHead];
    e.timestamp = wallclock();
    if (label)
    {
      strncpy(e.label, label, kLabelLen - 1);
      e.label[kLabelLen - 1] = '\0';
    }
    else
    {
      e.label[0] = '\0';
    }
    mHead = (mHead + 1) % kCapacity;
    if (mCount < kCapacity)
    {
      mCount++;
    }
  }

  void FlightRecorder::clear()
  {
    mHead = 0;
    mCount = 0;
    for (int i = 0; i < kCapacity; i++)
    {
      mRing[i].timestamp = 0.0f;
      mRing[i].label[0] = '\0';
    }
  }

  int FlightRecorder::count() const
  {
    return mCount;
  }

  const FlightRecorder::Event *FlightRecorder::at(int i) const
  {
    if (i < 0 || i >= mCount)
    {
      return nullptr;
    }
    // Oldest entry is at (mHead - mCount) mod kCapacity.
    int start = (mHead - mCount + kCapacity) % kCapacity;
    int idx = (start + i) % kCapacity;
    return &mRing[idx];
  }

  // [stol:infra-crash-diag-flight-recorder] File-scope global, NOT a Meyers
  // function-local static. A function-local static would run __cxa_guard_acquire
  // + a lazy ctor on first touch -- and the sibling ARM abort hook may be the
  // first thing to touch it, creating a hidden abort-context dependency. As a
  // file-scope global it is constructed during static initialization (no guard
  // variable). Its ctor only memsets the ring and depends on no other global, so
  // static-init order is safe; the object also lives in zero-initialized storage.
  FlightRecorder g_flightRecorder;

  FlightRecorder &flightRecorder()
  {
    return g_flightRecorder;
  }
}

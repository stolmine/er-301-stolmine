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

  FlightRecorder &flightRecorder()
  {
    static FlightRecorder instance;
    return instance;
  }
}

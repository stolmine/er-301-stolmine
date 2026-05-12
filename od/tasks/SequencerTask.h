#pragma once

#include <od/tasks/Task.h>
#include <od/objects/Outlet.h>
#include <od/sequencer/Sequencer.h>

namespace od {

  // SequencerTask runs once per audio frame, dispatched by TaskScheduler
  // at priority INT_MAX-2 (after InputTask INT_MAX-1, before any channel
  // chains). It owns 4 Slot instances and 24 Outlets (4 slots * 6 outputs).
  //
  // Slot output mapping (named to match `seqN.colname` picker entries):
  //   slot N -> { cv1, cv2, cv3, gate_len, gate_amp, step_len }
  //
  // ABI: subclasses od::Task and overrides ONLY existing virtuals (process).
  // Do NOT add new virtuals; teletype/Dispatcher + txo/TXoDispatcher inherit
  // Task with pre-compiled vtables.

  class SequencerTask : public Task {
  public:
    SequencerTask();
    virtual ~SequencerTask();

    virtual void process(float *inputs, float *outputs);

    // 24 outlets — verbose, but matches InputTask's named-member pattern
    // (each is reachable from Lua as `seqTask.mSeq1Cv1` etc., wrapped in
    // Source.External by app-setup.lua).
    Outlet mSeq1Cv1{"seq1.cv1"};
    Outlet mSeq1Cv2{"seq1.cv2"};
    Outlet mSeq1Cv3{"seq1.cv3"};
    Outlet mSeq1GateLen{"seq1.gate_len"};
    Outlet mSeq1GateAmp{"seq1.gate_amp"};
    Outlet mSeq1StepLen{"seq1.step_len"};

    Outlet mSeq2Cv1{"seq2.cv1"};
    Outlet mSeq2Cv2{"seq2.cv2"};
    Outlet mSeq2Cv3{"seq2.cv3"};
    Outlet mSeq2GateLen{"seq2.gate_len"};
    Outlet mSeq2GateAmp{"seq2.gate_amp"};
    Outlet mSeq2StepLen{"seq2.step_len"};

    Outlet mSeq3Cv1{"seq3.cv1"};
    Outlet mSeq3Cv2{"seq3.cv2"};
    Outlet mSeq3Cv3{"seq3.cv3"};
    Outlet mSeq3GateLen{"seq3.gate_len"};
    Outlet mSeq3GateAmp{"seq3.gate_amp"};
    Outlet mSeq3StepLen{"seq3.step_len"};

    Outlet mSeq4Cv1{"seq4.cv1"};
    Outlet mSeq4Cv2{"seq4.cv2"};
    Outlet mSeq4Cv3{"seq4.cv3"};
    Outlet mSeq4GateLen{"seq4.gate_len"};
    Outlet mSeq4GateAmp{"seq4.gate_amp"};
    Outlet mSeq4StepLen{"seq4.step_len"};

    // Slot accessors for bench harness / future UI
    sequencer::Slot &getSlot(int idx);

    // Global BPM (single value shared across all 4 slots per locked
    // decision #4). Set from Lua admin onSet callback; read on audio
    // thread in process(). Worst case is a brief stale read which is
    // musically harmless.
    //
    // Implemented as instance methods (not static) so SWIG exposes them
    // on the Lua-side wrapper directly via `seqTask:setBpm(n)` syntax.
    // Backed by a static field since there's exactly one SequencerTask
    // anyway.
    void  setBpm(float bpm);
    float getBpm() const;

    // Bench-harness proxy API. Lua passes integers and floats only;
    // Predicate / Action structs are not SWIG-exposed for v0.1.
    // `slot` is the slot index 0..3.
    void setL1(int slot, int col, int row, float value);
    void setColumnLength(int slot, int col, int length);
    void setMarkers(int slot, int col, int m1, int m2);
    // predOp / actionOp values correspond to the integer values of the
    // sequencer::PredicateOp / sequencer::ActionOp enums in Sequencer.h.
    // predColA / actionTargetCol: -1 means "host column" / "self".
    void setL2(int slot, int col, int row,
               int predOp, int predColA, float predOperand,
               int actionOp, int actionTargetCol, float actionOperand);
    void clearL2(int slot, int col, int row);
    void startSlot(int slot);
    void stopSlot(int slot);
    void resetSlot(int slot);
    void seedRng(int slot, unsigned int seed);
    int  playhead(int slot, int col) const;
    float l1Value(int slot, int col, int row) const;

    // Bench-only synchronous tick (do not call on running slots).
    void tickOnce(int slot);

    // Held-output value accessors (current sample-and-hold state).
    float heldCV1(int slot) const;
    float heldCV2(int slot) const;
    float heldCV3(int slot) const;
    float heldGateLen(int slot) const;
    float heldGateAmp(int slot) const;
    float heldStepLen(int slot) const;

  private:
    sequencer::Slot mSlots[sequencer::kNumSlots];
    static float    sBpm;
  };

} // namespace od

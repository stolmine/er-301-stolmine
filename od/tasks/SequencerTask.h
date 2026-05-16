#pragma once

#include <od/tasks/Task.h>
#include <od/objects/Outlet.h>
#include <od/sequencer/Sequencer.h>

namespace od {

  // SequencerTask runs once per audio frame, dispatched by TaskScheduler
  // at priority INT_MAX-2 (after InputTask INT_MAX-1, before any channel
  // chains). It owns 4 Slot instances and 24 Outlets (4 slots * 6
  // columns) -- 16 of those are picker-exposed (cv1/cv2/gate1/gate2 per
  // slot) and 8 are internal-only (stepLen, transpose; written each
  // frame for debug / future tooling but not registered as picker
  // sources in app-setup.lua).
  //
  // Slot output mapping (v2 layout, matches `seqN.colname` picker entries):
  //   slot N -> { cv1, cv2, gate1_amp, gate2_amp, step_len, transpose }
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
    // Source.External by app-setup.lua for the picker-exposed four).
    Outlet mSeq1Cv1{"seq1.cv1"};
    Outlet mSeq1Cv2{"seq1.cv2"};
    Outlet mSeq1Gate1Amp{"seq1.gate1"};
    Outlet mSeq1Gate2Amp{"seq1.gate2"};
    Outlet mSeq1StepLen{"seq1.step_len"};
    Outlet mSeq1Transpose{"seq1.transpose"};

    Outlet mSeq2Cv1{"seq2.cv1"};
    Outlet mSeq2Cv2{"seq2.cv2"};
    Outlet mSeq2Gate1Amp{"seq2.gate1"};
    Outlet mSeq2Gate2Amp{"seq2.gate2"};
    Outlet mSeq2StepLen{"seq2.step_len"};
    Outlet mSeq2Transpose{"seq2.transpose"};

    Outlet mSeq3Cv1{"seq3.cv1"};
    Outlet mSeq3Cv2{"seq3.cv2"};
    Outlet mSeq3Gate1Amp{"seq3.gate1"};
    Outlet mSeq3Gate2Amp{"seq3.gate2"};
    Outlet mSeq3StepLen{"seq3.step_len"};
    Outlet mSeq3Transpose{"seq3.transpose"};

    Outlet mSeq4Cv1{"seq4.cv1"};
    Outlet mSeq4Cv2{"seq4.cv2"};
    Outlet mSeq4Gate1Amp{"seq4.gate1"};
    Outlet mSeq4Gate2Amp{"seq4.gate2"};
    Outlet mSeq4StepLen{"seq4.step_len"};
    Outlet mSeq4Transpose{"seq4.transpose"};

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
    // predColARow / actionTargetRow: -1 means "use that column's
    // playhead row" (original behaviour); >=0 pins the rule to that
    // specific cell of the column.
    void setL2(int slot, int col, int row,
               int predOp, int predColA, int predColARow, float predOperand,
               int actionOp, int actionTargetCol, int actionTargetRow,
               float actionOperand);
    void clearL2(int slot, int col, int row);
    void startSlot(int slot);
    void stopSlot(int slot);
    void resetSlot(int slot);
    // Read-side companion to startSlot/stopSlot. Used by quicksave
    // (Persist.lua) to capture which slots were running so the load
    // path can optionally restore that transport state.
    bool isSlotRunning(int slot) const;

    // Whether the most recent fireTick produced a gate edge on this
    // slot. Mirrors Slot::firedThisTick. Used by the bench harness to
    // distinguish "extend held gate" (TIE re-energizing an in-flight
    // gate) from "edge / new gate event" (TIE starting fresh, or a
    // normal retrigger). firedThisTick is the slot-level OR of the
    // per-gate flags below; PRED_FIRE1 / PRED_FIRE2 in the L2 grammar
    // read the per-gate state directly.
    bool firedThisTick(int slot) const;
    bool firedGate1ThisTick(int slot) const;
    bool firedGate2ThisTick(int slot) const;
    void seedRng(int slot, unsigned int seed);
    int  playhead(int slot, int col) const;
    float l1Value(int slot, int col, int row) const;

    // Marker / length introspection for UI rendering (loop-region dim, etc.).
    int marker1(int slot, int col) const;
    int marker2(int slot, int col) const;
    int columnLength(int slot, int col) const;

    // L2 cell introspection for the L2 grid view. Returned ints map back
    // to the PredicateOp / ActionOp enums in Sequencer.h. predColA and
    // actionTargetCol return -1 to mean "host column" / "self" (the
    // same convention used by setL2). For an absent cell, l2Present
    // returns false and the other getters all return 0 / -1.
    bool  l2Present(int slot, int col, int row) const;
    int   l2PredOp(int slot, int col, int row) const;
    int   l2PredColA(int slot, int col, int row) const;
    int   l2PredColARow(int slot, int col, int row) const;
    float l2PredVal(int slot, int col, int row) const;
    int   l2ActOp(int slot, int col, int row) const;
    int   l2ActTgt(int slot, int col, int row) const;
    int   l2ActTgtRow(int slot, int col, int row) const;
    float l2ActVal(int slot, int col, int row) const;

    // Most recent row on which this column's L2 cell fired (predicate
    // evaluated true and action ran). -1 = no L2 cell has fired on
    // this column since init / reset. UI side reads this each refresh
    // and decays its own indicator timestamp Lua-side.
    int   l2LastFiredRow(int slot, int col) const;
    // Monotonic fire counter (uint32_t cast to int for SWIG). UI
    // tracks last-seen value per column; a different value means a
    // new fire happened since the last poll, even when the row is
    // the same as before (e.g. a %N rule on a single cell).
    int   l2FireSerial(int slot, int col) const;

    // Bench-only synchronous tick (do not call on running slots).
    void tickOnce(int slot);

    // Held-output value accessors (current sample-and-hold state).
    // heldCV1 includes the transpose pre-application -- it returns
    // cv1Raw + heldTranspose / 12. The raw cv1 cell value is reachable
    // via l1Value(slot, kColCV1, row) if needed.
    float heldCV1(int slot) const;
    float heldCV2(int slot) const;
    float heldGate1Len(int slot) const;
    float heldGate2Len(int slot) const;
    float heldGate1Amp(int slot) const;
    float heldGate2Amp(int slot) const;
    float heldStepLen(int slot) const;
    float heldTranspose(int slot) const;

  private:
    sequencer::Slot mSlots[sequencer::kNumSlots];
    static float    sBpm;
  };

} // namespace od

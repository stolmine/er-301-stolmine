#include <od/tasks/SequencerTask.h>
#include <od/config.h>

namespace od {

  float SequencerTask::sBpm = 120.0f;

  SequencerTask::SequencerTask() : Task("SequencerTask")
  {
    own(mSeq1Cv1); own(mSeq1Cv2);
    own(mSeq1Gate1Amp); own(mSeq1Gate2Amp);
    own(mSeq1StepLen); own(mSeq1Transpose);
    own(mSeq2Cv1); own(mSeq2Cv2);
    own(mSeq2Gate1Amp); own(mSeq2Gate2Amp);
    own(mSeq2StepLen); own(mSeq2Transpose);
    own(mSeq3Cv1); own(mSeq3Cv2);
    own(mSeq3Gate1Amp); own(mSeq3Gate2Amp);
    own(mSeq3StepLen); own(mSeq3Transpose);
    own(mSeq4Cv1); own(mSeq4Cv2);
    own(mSeq4Gate1Amp); own(mSeq4Gate2Amp);
    own(mSeq4StepLen); own(mSeq4Transpose);

    for (int i = 0; i < sequencer::kNumSlots; ++i) {
      mSlots[i].init(i);
    }
  }

  SequencerTask::~SequencerTask()
  {
  }

  void SequencerTask::process(float * /*inputs*/, float * /*outputs*/)
  {
    const int frameLen = FRAMELENGTH;
    const float sampleRate = static_cast<float>(globalConfig.sampleRate);
    const float bpm = sBpm;

    // v2 outlet plumbing. Index order matches the v2 column layout:
    //   [0] cv1, [1] cv2, [2] gate1Amp, [3] gate2Amp,
    //   [4] stepLen, [5] transpose.
    Outlet *outs[sequencer::kNumSlots][sequencer::kNumColumns] = {
      {&mSeq1Cv1, &mSeq1Cv2, &mSeq1Gate1Amp, &mSeq1Gate2Amp, &mSeq1StepLen, &mSeq1Transpose},
      {&mSeq2Cv1, &mSeq2Cv2, &mSeq2Gate1Amp, &mSeq2Gate2Amp, &mSeq2StepLen, &mSeq2Transpose},
      {&mSeq3Cv1, &mSeq3Cv2, &mSeq3Gate1Amp, &mSeq3Gate2Amp, &mSeq3StepLen, &mSeq3Transpose},
      {&mSeq4Cv1, &mSeq4Cv2, &mSeq4Gate1Amp, &mSeq4Gate2Amp, &mSeq4StepLen, &mSeq4Transpose}
    };

    for (int s = 0; s < sequencer::kNumSlots; ++s) {
      mSlots[s].processFrame(
        frameLen,
        outs[s][sequencer::kColCV1]->buffer(),
        outs[s][sequencer::kColCV2]->buffer(),
        outs[s][sequencer::kColGate1Len]->buffer(),
        outs[s][sequencer::kColGate2Len]->buffer(),
        outs[s][sequencer::kColStepLen]->buffer(),
        outs[s][sequencer::kColTranspose]->buffer(),
        bpm, sampleRate);
    }
  }

  sequencer::Slot &SequencerTask::getSlot(int idx)
  {
    if (idx < 0) idx = 0;
    if (idx >= sequencer::kNumSlots) idx = sequencer::kNumSlots - 1;
    return mSlots[idx];
  }

  void SequencerTask::setBpm(float bpm)
  {
    if (bpm < 20.0f) bpm = 20.0f;
    if (bpm > 400.0f) bpm = 400.0f;
    sBpm = bpm;
  }

  float SequencerTask::getBpm() const
  {
    return sBpm;
  }

  // -------------------------------------------------------------------------
  // Bench-harness proxies. Each guards the slot index then forwards to
  // mSlots[slot]'s public API.
  // -------------------------------------------------------------------------

  static inline int clampSlot(int s)
  {
    if (s < 0) return 0;
    if (s >= sequencer::kNumSlots) return sequencer::kNumSlots - 1;
    return s;
  }

  void SequencerTask::setL1(int slot, int col, int row, float value)
  {
    mSlots[clampSlot(slot)].setL1(col, row, value);
  }

  void SequencerTask::setColumnLength(int slot, int col, int length)
  {
    mSlots[clampSlot(slot)].setColumnLength(col, length);
  }

  void SequencerTask::setMarkers(int slot, int col, int m1, int m2)
  {
    mSlots[clampSlot(slot)].setMarkers(col, m1, m2);
  }

  void SequencerTask::setL2(int slot, int col, int row,
                            int predOp, int predColA, int predColARow,
                            float predOperand,
                            int actionOp, int actionTargetCol,
                            int actionTargetRow,
                            float actionOperand)
  {
    sequencer::Predicate p;
    p.op      = static_cast<sequencer::PredicateOp>(predOp);
    p.colA    = static_cast<int8_t>(predColA);
    p.colARow = static_cast<int8_t>(predColARow);
    p.operand = predOperand;

    sequencer::Action a;
    a.op        = static_cast<sequencer::ActionOp>(actionOp);
    a.targetCol = static_cast<int8_t>(actionTargetCol);
    a.targetRow = static_cast<int8_t>(actionTargetRow);
    a.operand   = actionOperand;

    mSlots[clampSlot(slot)].setL2(col, row, p, a);
  }

  void SequencerTask::clearL2(int slot, int col, int row)
  {
    mSlots[clampSlot(slot)].clearL2(col, row);
  }

  void SequencerTask::startSlot(int slot)
  {
    mSlots[clampSlot(slot)].start();
  }

  void SequencerTask::stopSlot(int slot)
  {
    mSlots[clampSlot(slot)].stop();
  }

  void SequencerTask::resetSlot(int slot)
  {
    mSlots[clampSlot(slot)].reset();
  }

  bool SequencerTask::isSlotRunning(int slot) const
  {
    return mSlots[clampSlot(slot)].running;
  }

  bool SequencerTask::firedThisTick(int slot) const
  {
    return mSlots[clampSlot(slot)].firedThisTick;
  }

  bool SequencerTask::firedGate1ThisTick(int slot) const
  {
    return mSlots[clampSlot(slot)].firedGate1ThisTick;
  }

  bool SequencerTask::firedGate2ThisTick(int slot) const
  {
    return mSlots[clampSlot(slot)].firedGate2ThisTick;
  }

  void SequencerTask::seedRng(int slot, unsigned int seed)
  {
    mSlots[clampSlot(slot)].seedRng(static_cast<uint32_t>(seed));
  }

  int SequencerTask::playhead(int slot, int col) const
  {
    if (col < 0 || col >= sequencer::kNumColumns) return 0;
    // Return currentRow (= the row being emitted right now) rather
    // than playhead (= the row scheduled for the next tick). UI
    // wants the audibly-current row so the highlight doesn't lead
    // the audio by one step. Internal C++ paths still use
    // col.playhead directly via Slot::playhead().
    return mSlots[clampSlot(slot)].columns[col].currentRow;
  }

  float SequencerTask::l1Value(int slot, int col, int row) const
  {
    return mSlots[clampSlot(slot)].l1Value(col, row);
  }

  int SequencerTask::marker1(int slot, int col) const
  {
    if (col < 0 || col >= sequencer::kNumColumns) return 0;
    return mSlots[clampSlot(slot)].columns[col].marker1;
  }

  int SequencerTask::marker2(int slot, int col) const
  {
    if (col < 0 || col >= sequencer::kNumColumns) return 0;
    return mSlots[clampSlot(slot)].columns[col].marker2;
  }

  int SequencerTask::columnLength(int slot, int col) const
  {
    if (col < 0 || col >= sequencer::kNumColumns) return 0;
    return mSlots[clampSlot(slot)].columns[col].length;
  }

  // L2 cell introspection. All seven getters share the same out-of-bounds
  // policy: invalid (slot, col, row) -> the absent-cell defaults. Callers
  // should gate further reads on l2Present() returning true.
  static inline bool inL2Range(int col, int row)
  {
    return col >= 0 && col < sequencer::kNumColumns
        && row >= 0 && row < sequencer::kMaxStepsPerColumn;
  }

  bool SequencerTask::l2Present(int slot, int col, int row) const
  {
    if (!inL2Range(col, row)) return false;
    return mSlots[clampSlot(slot)].columns[col].l2[row].present;
  }

  int SequencerTask::l2PredOp(int slot, int col, int row) const
  {
    if (!inL2Range(col, row)) return 0;
    const auto& cell = mSlots[clampSlot(slot)].columns[col].l2[row];
    return cell.present ? static_cast<int>(cell.pred.op) : 0;
  }

  int SequencerTask::l2PredColA(int slot, int col, int row) const
  {
    if (!inL2Range(col, row)) return -1;
    const auto& cell = mSlots[clampSlot(slot)].columns[col].l2[row];
    return cell.present ? static_cast<int>(cell.pred.colA) : -1;
  }

  int SequencerTask::l2PredColARow(int slot, int col, int row) const
  {
    if (!inL2Range(col, row)) return -1;
    const auto& cell = mSlots[clampSlot(slot)].columns[col].l2[row];
    return cell.present ? static_cast<int>(cell.pred.colARow) : -1;
  }

  float SequencerTask::l2PredVal(int slot, int col, int row) const
  {
    if (!inL2Range(col, row)) return 0.0f;
    const auto& cell = mSlots[clampSlot(slot)].columns[col].l2[row];
    return cell.present ? cell.pred.operand : 0.0f;
  }

  int SequencerTask::l2ActOp(int slot, int col, int row) const
  {
    if (!inL2Range(col, row)) return 0;
    const auto& cell = mSlots[clampSlot(slot)].columns[col].l2[row];
    return cell.present ? static_cast<int>(cell.action.op) : 0;
  }

  int SequencerTask::l2ActTgt(int slot, int col, int row) const
  {
    if (!inL2Range(col, row)) return -1;
    const auto& cell = mSlots[clampSlot(slot)].columns[col].l2[row];
    return cell.present ? static_cast<int>(cell.action.targetCol) : -1;
  }

  int SequencerTask::l2ActTgtRow(int slot, int col, int row) const
  {
    if (!inL2Range(col, row)) return -1;
    const auto& cell = mSlots[clampSlot(slot)].columns[col].l2[row];
    return cell.present ? static_cast<int>(cell.action.targetRow) : -1;
  }

  float SequencerTask::l2ActVal(int slot, int col, int row) const
  {
    if (!inL2Range(col, row)) return 0.0f;
    const auto& cell = mSlots[clampSlot(slot)].columns[col].l2[row];
    return cell.present ? cell.action.operand : 0.0f;
  }

  int SequencerTask::l2LastFiredRow(int slot, int col) const
  {
    if (col < 0 || col >= sequencer::kNumColumns) return -1;
    return mSlots[clampSlot(slot)].columns[col].lastL2FiredRow;
  }

  int SequencerTask::l2FireSerial(int slot, int col) const
  {
    if (col < 0 || col >= sequencer::kNumColumns) return 0;
    return static_cast<int>(mSlots[clampSlot(slot)].columns[col].l2FireSerial);
  }

  void SequencerTask::tickOnce(int slot)
  {
    mSlots[clampSlot(slot)].tickOnce();
  }

  float SequencerTask::heldCV1(int slot) const
  {
    return mSlots[clampSlot(slot)].heldCV1;
  }

  float SequencerTask::heldCV2(int slot) const
  {
    return mSlots[clampSlot(slot)].heldCV2;
  }

  float SequencerTask::heldGate1Len(int slot) const
  {
    return mSlots[clampSlot(slot)].heldGate1Len;
  }

  float SequencerTask::heldGate2Len(int slot) const
  {
    return mSlots[clampSlot(slot)].heldGate2Len;
  }

  float SequencerTask::heldGate1Amp(int slot) const
  {
    return mSlots[clampSlot(slot)].heldGate1Amp;
  }

  float SequencerTask::heldGate2Amp(int slot) const
  {
    return mSlots[clampSlot(slot)].heldGate2Amp;
  }

  float SequencerTask::heldStepLen(int slot) const
  {
    return mSlots[clampSlot(slot)].heldStepLen;
  }

  float SequencerTask::heldTranspose(int slot) const
  {
    return mSlots[clampSlot(slot)].heldTranspose;
  }

} // namespace od

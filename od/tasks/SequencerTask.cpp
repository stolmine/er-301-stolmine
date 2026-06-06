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

    // Ext-clock + reset comparators (phase 6). Set up names and default
    // to trigger-on-rise mode (the natural fit for a gate clock). The
    // Comparator ctor adds the In Inlet + Out Outlet to its internal
    // mInputs/mOutputs vectors; we own() them via Object ownership.
    mExtClockComp.setName("ExtClock");
    mExtResetComp.setName("ExtReset");
    mExtClockComp.setTriggerOnRiseMode();
    mExtResetComp.setTriggerOnRiseMode();

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
    const float internalBpm = sBpm;

    // Drive the comparators first. They read from their In Inlets
    // (connected to picker-bound source Outlets by ClockBinding) and
    // write their gate states to their Out Outlet buffers. Out is what
    // we edge-scan below for the divider / reset logic.
    mExtClockComp.process();
    mExtResetComp.process();

    // Refresh the windowed ext BPM cache. Same convention as
    // ComparatorView::draw (lines 140-158): once we have >2 edges
    // AND >0.25s elapsed since the last counter reset, take a
    // rate sample and reset the counter so the next window starts
    // fresh. Driving this from the audio thread (rather than from
    // the view) means the value stays current whether or not the
    // ClockView is on screen.
    //
    // PPQN interpretation: ext clock pulses are assumed to be
    // 1/16-note ticks (4 pulses per beat) -- the analog-modular
    // default and what matches Slot::stepLen=0.25's "tick = 1/16"
    // convention. So musical BPM = comparator_rate_in_bpm / 4
    // (which is comparator_rate_in_hz * 60 / 4 = hz * 15).
    if (mExtClockComp.getRisingEdgeCount() > 2
        && mExtClockComp.getElapsed() > 0.25f) {
      mCachedExtBpm = mExtClockComp.getRateInBPM() / 4.0f;
      mExtClockComp.resetCounter();
    }

    // v2 outlet plumbing. Index order matches the v2 column layout:
    //   [0] cv1, [1] cv2, [2] gate1Amp, [3] gate2Amp,
    //   [4] stepLen, [5] transpose.
    Outlet *outs[sequencer::kNumSlots][sequencer::kNumColumns] = {
      {&mSeq1Cv1, &mSeq1Cv2, &mSeq1Gate1Amp, &mSeq1Gate2Amp, &mSeq1StepLen, &mSeq1Transpose},
      {&mSeq2Cv1, &mSeq2Cv2, &mSeq2Gate1Amp, &mSeq2Gate2Amp, &mSeq2StepLen, &mSeq2Transpose},
      {&mSeq3Cv1, &mSeq3Cv2, &mSeq3Gate1Amp, &mSeq3Gate2Amp, &mSeq3StepLen, &mSeq3Transpose},
      {&mSeq4Cv1, &mSeq4Cv2, &mSeq4Gate1Amp, &mSeq4Gate2Amp, &mSeq4StepLen, &mSeq4Transpose}
    };

    // Reset edge detection on comparator.Out — runs in BOTH modes. A
    // modular reset jack is still useful when the sequencer is
    // internally clocked but synced to an external transport. v1
    // quantizes resets to the start of the frame.
    {
      const float *rstBuf = mExtResetComp.getOutput("Out")->buffer();
      bool resetEdge = false;
      float prev = mExtResetOutPrev;
      for (int i = 0; i < frameLen; ++i) {
        const float cur = rstBuf[i];
        if (prev < 0.5f && cur >= 0.5f) resetEdge = true;
        prev = cur;
      }
      mExtResetOutPrev = prev;
      if (resetEdge) {
        for (int s = 0; s < sequencer::kNumSlots; ++s) {
          mSlots[s].reset();
        }
      }
    }

    if (mClockSource == CLOCK_EXTERNAL) {
      // Per-sample edge detection on the ext clock comparator's Out.
      // Each edge feeds the global divider; surviving ticks feed
      // per-slot dividers; surviving per-slot ticks call externalTick().
      // Gate-length BPM uses the comparator's built-in rate measurement
      // when available; falls back to internal BPM otherwise.
      const float *clkBuf = mExtClockComp.getOutput("Out")->buffer();
      const float compBpm = mExtClockComp.getRateInBPM();
      const float gateBpm = (compBpm > 0.0f) ? compBpm : internalBpm;
      float prev = mExtClockOutPrev;

      for (int i = 0; i < frameLen; ++i) {
        const float cur = clkBuf[i];
        if (prev < 0.5f && cur >= 0.5f) {
          // Ext clock rising edge. Advance global divider.
          ++mGlobalDivCount;
          if (mGlobalDivCount >= mGlobalDiv) {
            mGlobalDivCount = 0;
            for (int s = 0; s < sequencer::kNumSlots; ++s) {
              ++mSlotDivCount[s];
              if (mSlotDivCount[s] >= mSlotDiv[s]) {
                mSlotDivCount[s] = 0;
                mSlots[s].externalTick(gateBpm, sampleRate);
              }
            }
          }
        }
        prev = cur;
      }
      mExtClockOutPrev = prev;

      // Emission pass — slots emit S&H + gate envelopes without
      // advancing their internal samplesUntilTick.
      for (int s = 0; s < sequencer::kNumSlots; ++s) {
        mSlots[s].processFrameExternal(
          frameLen,
          outs[s][sequencer::kColCV1]->buffer(),
          outs[s][sequencer::kColCV2]->buffer(),
          outs[s][sequencer::kColGate1Len]->buffer(),
          outs[s][sequencer::kColGate2Len]->buffer(),
          outs[s][sequencer::kColStepLen]->buffer(),
          outs[s][sequencer::kColTranspose]->buffer());
      }
    } else {
      // CLOCK_INTERNAL — existing behaviour. Per-slot polymetric
      // stepLen-driven scheduling, unchanged from pre-phase-6.
      for (int s = 0; s < sequencer::kNumSlots; ++s) {
        mSlots[s].processFrame(
          frameLen,
          outs[s][sequencer::kColCV1]->buffer(),
          outs[s][sequencer::kColCV2]->buffer(),
          outs[s][sequencer::kColGate1Len]->buffer(),
          outs[s][sequencer::kColGate2Len]->buffer(),
          outs[s][sequencer::kColStepLen]->buffer(),
          outs[s][sequencer::kColTranspose]->buffer(),
          internalBpm, sampleRate);
      }
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

  // -------------------------------------------------------------------------
  // External clock + reset (phase 6) — setters / getters / inlet accessors.
  // -------------------------------------------------------------------------

  void SequencerTask::setClockSource(int source)
  {
    // Switching modes resets the divider counters and the comparator
    // rate counter so the new mode starts cleanly. The next ext-clock
    // edge (in external mode) or the next frame (in internal mode)
    // fires a tick as expected.
    if (source != CLOCK_INTERNAL && source != CLOCK_EXTERNAL) return;
    if (mClockSource != source) {
      mClockSource = source;
      mGlobalDivCount = 0;
      for (int i = 0; i < sequencer::kNumSlots; ++i) mSlotDivCount[i] = 0;
      // Drop BPM estimate + comparator window so the next pulse starts
      // fresh measurement rather than carrying over stale state.
      mCachedExtBpm = 0.0f;
      mExtClockComp.resetCounter();
    }
  }

  int SequencerTask::getClockSource() const
  {
    return mClockSource;
  }

  void SequencerTask::setGlobalDiv(int div)
  {
    if (div < 1) div = 1;
    if (div > 16) div = 16;
    mGlobalDiv = div;
  }

  int SequencerTask::getGlobalDiv() const
  {
    return mGlobalDiv;
  }

  void SequencerTask::setSlotDiv(int slot, int div)
  {
    if (div < 1) div = 1;
    if (div > 16) div = 16;
    mSlotDiv[clampSlot(slot)] = div;
  }

  int SequencerTask::getSlotDiv(int slot) const
  {
    return mSlotDiv[clampSlot(slot)];
  }

  float SequencerTask::getExtBpm() const
  {
    return mCachedExtBpm;
  }

  void SequencerTask::resetDividers()
  {
    mGlobalDivCount = 0;
    for (int i = 0; i < sequencer::kNumSlots; ++i) mSlotDivCount[i] = 0;
    mExtClockComp.resetCounter();
    mExtResetComp.resetCounter();
  }

  void SequencerTask::triggerClockRise()
  {
    mExtClockComp.simulateRisingEdge();
  }

  void SequencerTask::triggerClockFall()
  {
    mExtClockComp.simulateFallingEdge();
  }

  void SequencerTask::triggerResetRise()
  {
    mExtResetComp.simulateRisingEdge();
  }

  void SequencerTask::triggerResetFall()
  {
    mExtResetComp.simulateFallingEdge();
  }

} // namespace od

#include <od/sequencer/Sequencer.h>
#include <od/sequencer/PredicateEval.h>
#include <od/sequencer/ActionApply.h>

#include <algorithm>

namespace od { namespace sequencer {

// ---------------------------------------------------------------------------
// Column
// ---------------------------------------------------------------------------

Column::Column()
{
  l1.resize(kMaxStepsPerColumn);
  l2.resize(kMaxStepsPerColumn);
}

int Column::loopMin() const
{
  return marker1 < marker2 ? marker1 : marker2;
}

int Column::loopMax() const
{
  return marker1 > marker2 ? marker1 : marker2;
}

// ---------------------------------------------------------------------------
// Gate retrigger helper (file-local). Applies one gate's TIE / retrigger /
// skip logic in place. v2 layout: gate amplitude is constant 1.0 -- a
// gate-len value of 0 means "skip row", any value > 0 (up to but below
// kTieThreshold) means "fire a gate of that length", and >= kTieThreshold
// means "TIE": extend an in-flight gate by one step (no edge), or start
// fresh full-step if no gate is in flight.
// ---------------------------------------------------------------------------

static constexpr float kTieThreshold = 3.999f;

static void fireGate(float heldGateLen, float heldStepLen,
                     float samplesPerBeat,
                     float& heldGateAmp, int& gateRemainingSamples,
                     bool& firedThisGate)
{
  firedThisGate = false;
  if (heldGateLen <= 0.0f) {
    // Skip row -- existing envelope continues counting down in processFrame.
    return;
  }
  if (heldGateLen >= kTieThreshold) {
    // TIE: extend-or-start. Refresh remaining to one step's worth.
    float stepBeats = (heldStepLen > 0.0f) ? heldStepLen : 0.25f;
    int spt = static_cast<int>(stepBeats * samplesPerBeat);
    if (spt < 1) spt = 1;
    if (gateRemainingSamples > 0) {
      // Extend; no edge, heldGateAmp untouched.
      gateRemainingSamples = spt;
    } else {
      // Fresh start; edge.
      firedThisGate = true;
      heldGateAmp = 1.0f;
      gateRemainingSamples = spt;
    }
    return;
  }
  // Normal retrigger.
  firedThisGate = true;
  heldGateAmp = 1.0f;
  int n = static_cast<int>(heldGateLen * samplesPerBeat);
  if (n < 1) n = 1;
  gateRemainingSamples = n;
}

// ---------------------------------------------------------------------------
// Slot
// ---------------------------------------------------------------------------

Slot::Slot()
{
}

void Slot::init(int slotIdx)
{
  rng.seed(0xC0FFEE + static_cast<uint32_t>(slotIdx));

  for (int c = 0; c < kNumColumns; ++c) {
    Column& col = columns[c];
    for (int r = 0; r < kMaxStepsPerColumn; ++r) {
      col.l1[r].value = 0.0f;
      col.l2[r].present = false;
    }
    col.length      = 16;
    col.marker1     = 0;
    col.marker2     = 15;
    col.playhead    = 0;
    col.currentRow  = 0;
    col.passCount   = 0;
    col.pendingJump = -1;
    col.lastTickValue  = std::numeric_limits<float>::quiet_NaN();
    col.lastL2FiredRow = -1;
    col.l2FireSerial   = 0;
  }

  // Seed step-len column with a sane default so a fresh slot's first tick
  // doesn't divide by zero in fireTick (which falls back to 0.25 anyway).
  for (int r = 0; r < kMaxStepsPerColumn; ++r) {
    columns[kColStepLen].l1[r].value = 0.25f;  // 1/16 note
  }

  samplesUntilTick = 0;
  externalTickCount = 0;
  running          = false;
  heldCV1 = heldCV2 = 0.0f;
  heldGate1Len = heldGate2Len = 0.0f;
  heldStepLen      = 0.25f;
  heldTranspose    = 0.0f;
  heldGate1Amp = heldGate2Amp = 0.0f;
  gate1RemainingSamples = gate2RemainingSamples = 0;
  cachedBpm        = 120.0f;
  cachedSampleRate = 48000.0f;
  firedThisTick = firedGate1ThisTick = firedGate2ThisTick = false;
}

int Slot::fireTick()
{
  // Reset per-tick edge flags. Set below by fireGate() helpers if step 2
  // produces an edge. PRED_FIRE reads firedThisTick (slot-level OR);
  // PRED_FIRE1 / PRED_FIRE2 read the per-gate flags.
  firedThisTick = firedGate1ThisTick = firedGate2ThisTick = false;

  // Capture currentRow per column before any L1/L2 processing or
  // playhead advance. UI getters read currentRow so the displayed
  // highlight matches the row being emitted THIS tick.
  for (int c = 0; c < kNumColumns; ++c) {
    columns[c].currentRow = columns[c].playhead;
  }

  Column& cv1c       = columns[kColCV1];
  Column& cv2c       = columns[kColCV2];
  Column& gate1LenC  = columns[kColGate1Len];
  Column& gate2LenC  = columns[kColGate2Len];
  Column& stepLenC   = columns[kColStepLen];
  Column& transposeC = columns[kColTranspose];

  // 1. Sample-and-hold from current playhead positions. Every column
  //    reads from its OWN playhead -- cv1, cv2, g1L, g2L, stL, tr all
  //    polymetric. Transpose is pre-applied to cv1's S&H so the cv1
  //    audio buffer carries the transposed value. The grid view still
  //    displays the raw cv1 cell so authoring stays clear (transpose
  //    is its own column to edit).
  heldTranspose = transposeC.l1[transposeC.playhead].value;
  heldCV1       = cv1c.l1[cv1c.playhead].value + heldTranspose / 12.0f;
  heldCV2       = cv2c.l1[cv2c.playhead].value;
  heldGate1Len  = gate1LenC.l1[gate1LenC.playhead].value;
  heldGate2Len  = gate2LenC.l1[gate2LenC.playhead].value;
  heldStepLen   = stepLenC.l1[stepLenC.playhead].value;

  // 2. Gate envelope retrigger -- each gate independently.
  //    gate-len > 0 fires (amp constant 1.0); >= kTieThreshold is TIE
  //    (extend-or-start). See fireGate() comment for the full table.
  const float samplesPerBeat = 60.0f * cachedSampleRate / cachedBpm;
  fireGate(heldGate1Len, heldStepLen, samplesPerBeat,
           heldGate1Amp, gate1RemainingSamples, firedGate1ThisTick);
  fireGate(heldGate2Len, heldStepLen, samplesPerBeat,
           heldGate2Amp, gate2RemainingSamples, firedGate2ThisTick);
  firedThisTick = firedGate1ThisTick || firedGate2ThisTick;

  // 3. L2 evaluation. For each column whose current playhead row has an
  //    L2 cell with .present=true, evaluate the predicate; if true, apply
  //    the action. Actions may mutate other columns' L1 values (affects
  //    FUTURE emissions, not the current one — held values were already
  //    captured above) and may queue deferred jumps applied during the
  //    advance step below.
  //
  //    Evaluation order: column index ascending.
  for (int c = 0; c < kNumColumns; ++c) {
    Column& col = columns[c];
    const int row = col.playhead;
    if (col.l2[row].present) {
      if (od::sequencer::evaluate(*this, col.l2[row].pred, c)) {
        col.lastL2FiredRow = row;
        ++col.l2FireSerial;
        od::sequencer::apply(*this, col.l2[row].action, c);
      }
    }
  }

  // 3.5. Capture each column's current playhead-row L1 value into
  //      Column::lastTickValue so the NEXT tick's PRED_CHANGED can
  //      compare against it. Runs AFTER L2 actions (step 3) so that
  //      same-tick L2 mutations register as a "change" on the next tick.
  for (int c = 0; c < kNumColumns; ++c) {
    Column& col = columns[c];
    col.lastTickValue = col.l1[col.playhead].value;
  }

  // 4. Compute samples until NEXT tick from the step-len value we just
  //    emitted. (Default to 1/16 if 0 to avoid hangs from empty cells.)
  float stepLenBeats = heldStepLen;
  if (stepLenBeats <= 0.0f) stepLenBeats = 0.25f;
  int spt = static_cast<int>(stepLenBeats * samplesPerBeat);
  if (spt < 1) spt = 1;

  // 5. Advance every column's playhead, applying any pendingJump set by
  //    L2 actions this tick (or carried over from a previous tick).
  for (int c = 0; c < kNumColumns; ++c) {
    Column& col = columns[c];
    if (col.pendingJump >= 0) {
      const int target = col.pendingJump;
      col.pendingJump = -1;
      col.playhead = (target < 0) ? 0
                  : (target >= col.length) ? (col.length - 1)
                  : target;
    } else {
      const int lo = col.loopMin();
      const int hi = col.loopMax();
      if (col.playhead < lo || col.playhead > hi) {
        col.playhead = lo;
      } else if (col.playhead == hi) {
        col.playhead = lo;
        ++col.passCount;
      } else {
        ++col.playhead;
      }
    }
  }

  return spt;
}

void Slot::processFrame(int frameLen,
                        float* cv1, float* cv2,
                        float* gate1Amp, float* gate2Amp,
                        float* stepLen, float* transpose,
                        float bpm, float sampleRate)
{
  cachedBpm = bpm;
  cachedSampleRate = sampleRate;

  // CV cell values are stored in VOLTS. ER-301 audio buffers are
  // normalized so 1.0 maps to +10V at the output jack, hence we emit
  // cell_volts * 0.1 to the buffer. CV1 typically uses V/oct (1V per
  // octave). Gate amps are constant 1.0 when armed; step-len /
  // transpose buffers are internal-only (not picker-exposed in v2)
  // but emitted for debug / future tooling.
  static constexpr float kCvOutScale = 0.1f;

  if (!running) {
    // Hold last values; both gate envelopes drop to silent.
    for (int i = 0; i < frameLen; ++i) {
      cv1[i]       = heldCV1 * kCvOutScale;
      cv2[i]       = heldCV2 * kCvOutScale;
      gate1Amp[i]  = 0.0f;
      gate2Amp[i]  = 0.0f;
      stepLen[i]   = heldStepLen;
      transpose[i] = heldTranspose;
    }
    return;
  }

  // Sample-accurate tick scheduling: split the frame at tick boundaries.
  // See the v0.1 comment retained for context -- behaviour unchanged.
  int filled = 0;
  while (filled < frameLen) {
    while (samplesUntilTick <= 0) {
      const int spt = fireTick();
      samplesUntilTick += spt;
    }
    const int remaining = frameLen - filled;
    const int n = (samplesUntilTick < remaining) ? samplesUntilTick : remaining;
    for (int j = 0; j < n; ++j) {
      const int i = filled + j;
      cv1[i]       = heldCV1 * kCvOutScale;
      cv2[i]       = heldCV2 * kCvOutScale;
      stepLen[i]   = heldStepLen;
      transpose[i] = heldTranspose;
      if (gate1RemainingSamples > 0) {
        gate1Amp[i] = heldGate1Amp;
        --gate1RemainingSamples;
      } else {
        gate1Amp[i] = 0.0f;
      }
      if (gate2RemainingSamples > 0) {
        gate2Amp[i] = heldGate2Amp;
        --gate2RemainingSamples;
      } else {
        gate2Amp[i] = 0.0f;
      }
    }
    filled += n;
    samplesUntilTick -= n;
  }
}

void Slot::processFrameExternal(int frameLen,
                                float* cv1, float* cv2,
                                float* gate1Amp, float* gate2Amp,
                                float* stepLen, float* transpose)
{
  // CV output scaling -- same convention as processFrame. 1.0 unit
  // == 10V at the output jack, so cell volts emit at * 0.1.
  static constexpr float kCvOutScale = 0.1f;

  if (!running) {
    // Hold last values; both gate envelopes drop to silent. Matches
    // processFrame's stopped behaviour.
    for (int i = 0; i < frameLen; ++i) {
      cv1[i]       = heldCV1 * kCvOutScale;
      cv2[i]       = heldCV2 * kCvOutScale;
      gate1Amp[i]  = 0.0f;
      gate2Amp[i]  = 0.0f;
      stepLen[i]   = heldStepLen;
      transpose[i] = heldTranspose;
    }
    return;
  }

  // No internal tick scheduling here. externalTick() is invoked from
  // SequencerTask on master-tick boundaries (typically before this
  // method runs for the frame), which has already updated S&H +
  // gate envelopes. We just emit + count down gate envelopes per
  // sample.
  for (int i = 0; i < frameLen; ++i) {
    cv1[i]       = heldCV1 * kCvOutScale;
    cv2[i]       = heldCV2 * kCvOutScale;
    stepLen[i]   = heldStepLen;
    transpose[i] = heldTranspose;
    if (gate1RemainingSamples > 0) {
      gate1Amp[i] = heldGate1Amp;
      --gate1RemainingSamples;
    } else {
      gate1Amp[i] = 0.0f;
    }
    if (gate2RemainingSamples > 0) {
      gate2Amp[i] = heldGate2Amp;
      --gate2RemainingSamples;
    } else {
      gate2Amp[i] = 0.0f;
    }
  }
}

void Slot::externalTick(float bpm, float sampleRate)
{
  if (!running) return;
  cachedBpm        = bpm;
  cachedSampleRate = sampleRate;

  // Atomic-tick semantics. Each surviving external pulse increments
  // the counter; the slot only advances its playhead when the current
  // row's stL is satisfied. PPQN=4 base: 1 tick = 0.25 beats = 1/16
  // note. stL is stored as 0.25 * integer_ticks (user can only author
  // integer-tick values via the UI; clamp floors at one tick).
  //
  // Without this gating, every surviving pulse fires fireTick() and
  // every row advances on every pulse regardless of stL -- the bug
  // reported on 9.5.0 bench.
  ++externalTickCount;

  Column& stC      = columns[kColStepLen];
  float   stLBeats = stC.l1[stC.playhead].value;
  if (stLBeats <= 0.0f) stLBeats = 0.25f;  // safety: avoid deadlock
  int     stLTicks = static_cast<int>(stLBeats * 4.0f + 0.5f);  // round
  if (stLTicks < 1) stLTicks = 1;

  if (externalTickCount >= stLTicks) {
    externalTickCount = 0;
    // Discard returned samples-per-tick: external clock owns spacing.
    (void)fireTick();
  }
}

void Slot::setL1(int col, int row, float value)
{
  if (col < 0 || col >= kNumColumns) return;
  if (row < 0 || row >= kMaxStepsPerColumn) return;
  columns[col].l1[row].value = normalizeL1Value(col, value);
}

void Slot::setColumnLength(int col, int length)
{
  if (col < 0 || col >= kNumColumns) return;
  if (length < 1) length = 1;
  if (length > kMaxStepsPerColumn) length = kMaxStepsPerColumn;
  columns[col].length = length;
  if (columns[col].marker2 >= length) columns[col].marker2 = length - 1;
  if (columns[col].marker1 >= length) columns[col].marker1 = length - 1;
  if (columns[col].playhead >= length) columns[col].playhead = 0;
}

void Slot::setMarkers(int col, int m1, int m2)
{
  if (col < 0 || col >= kNumColumns) return;
  Column& c = columns[col];
  m1 = std::max(0, std::min(m1, kMaxStepsPerColumn - 1));
  m2 = std::max(0, std::min(m2, kMaxStepsPerColumn - 1));
  const int needed = std::max(m1, m2) + 1;
  if (c.length < needed) c.length = needed;
  c.marker1 = m1;
  c.marker2 = m2;
}

void Slot::setL2(int col, int row, const Predicate& p, const Action& a)
{
  if (col < 0 || col >= kNumColumns) return;
  if (row < 0 || row >= kMaxStepsPerColumn) return;
  L2Cell& cell = columns[col].l2[row];
  cell.present = true;
  cell.pred = p;
  cell.action = a;
}

void Slot::clearL2(int col, int row)
{
  if (col < 0 || col >= kNumColumns) return;
  if (row < 0 || row >= kMaxStepsPerColumn) return;
  columns[col].l2[row].present = false;
}

void Slot::start()
{
  running = true;
  samplesUntilTick = 0;  // fire on next frame
}

void Slot::stop()
{
  running = false;
}

void Slot::reset()
{
  for (int c = 0; c < kNumColumns; ++c) {
    columns[c].playhead   = columns[c].loopMin();
    columns[c].currentRow = columns[c].loopMin();
    columns[c].passCount = 0;
    columns[c].pendingJump = -1;
    // Clear PRED_CHANGED's tick-over-tick comparator so the first
    // tick after reset can never "change" against a stale value.
    columns[c].lastTickValue  = std::numeric_limits<float>::quiet_NaN();
    columns[c].lastL2FiredRow = -1;
  }
  samplesUntilTick = 0;
  externalTickCount = 0;
  heldCV1 = heldCV2 = 0.0f;
  heldTranspose = 0.0f;
  heldGate1Amp = heldGate2Amp = 0.0f;
  gate1RemainingSamples = gate2RemainingSamples = 0;
  firedThisTick = firedGate1ThisTick = firedGate2ThisTick = false;
}

void Slot::seedRng(uint32_t seed)
{
  rng.seed(seed);
}

int Slot::playhead(int col) const
{
  if (col < 0 || col >= kNumColumns) return 0;
  return columns[col].playhead;
}

float Slot::l1Value(int col, int row) const
{
  if (col < 0 || col >= kNumColumns) return 0.0f;
  if (row < 0 || row >= kMaxStepsPerColumn) return 0.0f;
  return columns[col].l1[row].value;
}

void Slot::tickOnce()
{
  fireTick();  // ignore returned samplesPerTick (bench doesn't need it)
}

}}  // namespace od::sequencer

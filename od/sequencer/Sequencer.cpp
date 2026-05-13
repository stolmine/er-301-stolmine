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
// Slot — stubs for sub-task A. Real bodies land in sub-task B.
// ---------------------------------------------------------------------------

Slot::Slot()
{
}

void Slot::init(int slotIdx)
{
  rng.seed(0xC0FFEE + static_cast<uint32_t>(slotIdx));

  // Column vectors are pre-sized to kMaxStepsPerColumn by Column ctor;
  // this just resets values in place (no realloc).
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
  }

  // Seed step-len column with a sane default so a fresh slot's first tick
  // doesn't divide by zero in fireTick (which falls back to 0.25 anyway).
  for (int r = 0; r < kMaxStepsPerColumn; ++r) {
    columns[kColStepLen].l1[r].value = 0.25f;  // 1/16 note
  }

  samplesUntilTick = 0;
  running          = false;
  heldCV1 = heldCV2 = heldCV3 = 0.0f;
  heldGateLen      = 0.0f;
  heldStepLen      = 0.25f;
  heldGateAmp      = 0.0f;
  gateRemainingSamples = 0;
  cachedBpm        = 120.0f;
  cachedSampleRate = 48000.0f;
  firedThisTick    = false;
}

int Slot::fireTick()
{
  // Reset per-tick edge flag. PRED_FIRE reads this during step 3
  // (L2 eval); it'll be set true below if step 2 retriggers the gate.
  firedThisTick = false;

  // Capture currentRow per column before any L1/L2 processing or
  // playhead advance. UI getters read currentRow so the displayed
  // highlight matches the row being emitted THIS tick (= playhead
  // at the start of fireTick), not the row scheduled for the next
  // tick (= playhead after advance at the end).
  for (int c = 0; c < kNumColumns; ++c) {
    columns[c].currentRow = columns[c].playhead;
  }

  Column& cv1c     = columns[kColCV1];
  Column& cv2c     = columns[kColCV2];
  Column& cv3c     = columns[kColCV3];
  Column& gateLenC = columns[kColGateLen];
  Column& gateAmpC = columns[kColGateAmp];
  Column& stepLenC = columns[kColStepLen];

  // 1. Sample-and-hold from current playhead positions.
  //    Per the v0.1 working assumption (TODO(gate-row) in Sequencer.h),
  //    gate-len and gate-amp values are read from CV1's playhead row, NOT
  //    each column's own row. CV outputs and step-len read each column's
  //    own playhead.
  heldCV1     = cv1c.l1[cv1c.playhead].value;
  heldCV2     = cv2c.l1[cv2c.playhead].value;
  heldCV3     = cv3c.l1[cv3c.playhead].value;
  heldGateLen = gateLenC.l1[cv1c.playhead].value;
  heldStepLen = stepLenC.l1[stepLenC.playhead].value;

  // 2. Gate envelope retrigger.
  //    If gate-amp at this row is 0, the row "skips" -- existing envelope
  //    continues counting down. Otherwise we retrigger: amp = new value,
  //    duration = gateLenBeats * samplesPerBeat.
  const float rowGateAmp = gateAmpC.l1[cv1c.playhead].value;
  firedThisTick = (rowGateAmp > 0.0f);
  if (firedThisTick) {
    heldGateAmp = rowGateAmp;
    const float samplesPerBeat = 60.0f * cachedSampleRate / cachedBpm;
    int n = static_cast<int>(heldGateLen * samplesPerBeat);
    if (n < 1) n = 1;
    gateRemainingSamples = n;
  }

  // 3. L2 evaluation. For each column whose current playhead row has an
  //    L2 cell with .present=true, evaluate the predicate; if true, apply
  //    the action. Actions may mutate other columns' L1 values (affects
  //    FUTURE emissions, not the current one — held values were already
  //    captured above) and may queue deferred jumps applied during the
  //    advance step below.
  //
  //    Evaluation order: column index ascending. Documented as the v0.1
  //    ordering; revisit if jump actions interact poorly.
  for (int c = 0; c < kNumColumns; ++c) {
    Column& col = columns[c];
    const int row = col.playhead;
    if (col.l2[row].present) {
      if (od::sequencer::evaluate(*this, col.l2[row].pred, c)) {
        col.lastL2FiredRow = row;
        od::sequencer::apply(*this, col.l2[row].action, c);
      }
    }
  }

  // 3.5. Capture each column's current playhead-row L1 value into
  //      Column::lastTickValue so the NEXT tick's PRED_CHANGED can
  //      compare against it. Runs AFTER L2 actions (step 3) so that
  //      same-tick L2 mutations register as a "change" on the next
  //      tick.
  for (int c = 0; c < kNumColumns; ++c) {
    Column& col = columns[c];
    col.lastTickValue = col.l1[col.playhead].value;
  }

  // 4. Compute samples until NEXT tick from the step-len value we just
  //    emitted. (Default to 1/16 if 0 to avoid hangs from empty cells.)
  float stepLenBeats = heldStepLen;
  if (stepLenBeats <= 0.0f) stepLenBeats = 0.25f;
  const float samplesPerBeat = 60.0f * cachedSampleRate / cachedBpm;
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
                        float* cv1, float* cv2, float* cv3,
                        float* gateLen, float* gateAmp, float* stepLen,
                        float bpm, float sampleRate)
{
  cachedBpm = bpm;
  cachedSampleRate = sampleRate;

  // Convention: CV cell values are stored in VOLTS. ER-301 audio buffers
  // are normalized so 1.0 maps to +10V at the output jack, hence we
  // emit cell_volts * 0.1 to the buffer. CV1 typically uses V/oct (1V
  // per octave), but the engine stays unit-agnostic; the UI does the
  // note-name conversion. Gate-len / step-len stay in beats (unit-
  // agnostic float emitted directly). Gate-amp stays in 0..1.
  static constexpr float kCvOutScale = 0.1f;

  if (!running) {
    // Hold last values; gate envelope drops to silent.
    for (int i = 0; i < frameLen; ++i) {
      cv1[i]     = heldCV1 * kCvOutScale;
      cv2[i]     = heldCV2 * kCvOutScale;
      cv3[i]     = heldCV3 * kCvOutScale;
      gateLen[i] = heldGateLen;
      gateAmp[i] = 0.0f;
      stepLen[i] = heldStepLen;
    }
    return;
  }

  // Fire 0 or more ticks at the start of the frame. The while-loop
  // handles the case where samplesPerTick < frameLen (very fast tempos
  // or short step-lengths).
  while (samplesUntilTick <= 0) {
    const int spt = fireTick();
    samplesUntilTick += spt;
  }

  // Fill the frame with current held values. Gate output is the envelope
  // (heldGateAmp while remaining > 0, else 0).
  for (int i = 0; i < frameLen; ++i) {
    cv1[i]     = heldCV1 * kCvOutScale;
    cv2[i]     = heldCV2 * kCvOutScale;
    cv3[i]     = heldCV3 * kCvOutScale;
    gateLen[i] = heldGateLen;
    stepLen[i] = heldStepLen;
    if (gateRemainingSamples > 0) {
      gateAmp[i] = heldGateAmp;
      --gateRemainingSamples;
    } else {
      gateAmp[i] = 0.0f;
    }
  }

  samplesUntilTick -= frameLen;
}

void Slot::setL1(int col, int row, float value)
{
  if (col < 0 || col >= kNumColumns) return;
  if (row < 0 || row >= kMaxStepsPerColumn) return;
  columns[col].l1[row].value = value;
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
  // Clamp to engine maximum (kMaxStepsPerColumn), then auto-grow the
  // column's logical length so the higher of (m1, m2) fits inside it.
  // Without the grow, default length = 16 silently clamped any marker
  // past row 15 -- the UI has no separate length control yet, so the
  // user's mark gesture would just appear to land at row 15 with no
  // feedback. Length only grows here; shrinking remains the explicit
  // job of setColumnLength.
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
  heldCV1 = heldCV2 = heldCV3 = 0.0f;
  heldGateAmp = 0.0f;
  gateRemainingSamples = 0;
  firedThisTick = false;
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

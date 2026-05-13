#include <od/sequencer/PredicateEval.h>

#include <cmath>

namespace od { namespace sequencer {

bool evaluate(Slot& slot, const Predicate& p, int hostCol)
{
  // Default colA to hostCol when -1 (most common case: predicate references
  // the column the L2 cell lives in).
  int testCol = (p.colA >= 0 && p.colA < kNumColumns) ? p.colA : hostCol;
  if (testCol < 0 || testCol >= kNumColumns) {
    return false;
  }
  const Column& tc = slot.columns[testCol];
  // Row pin: when colARow >= 0, the predicate inspects that specific
  // cell of testCol; otherwise (-1) it inspects testCol's current
  // playhead row. Lets users author rules that fire based on a fixed
  // cell rather than a moving target.
  const int inspectRow = (p.colARow >= 0 && p.colARow < kMaxStepsPerColumn)
                         ? p.colARow
                         : tc.playhead;
  const float v = tc.l1[inspectRow].value;

  switch (p.op) {
    case PRED_MODULO: {
      // Every N passes of column `testCol`. Fires once per N passes at the
      // row this L2 cell occupies (since evaluate is called only when the
      // playhead lands on that row).
      const int N = static_cast<int>(p.operand);
      if (N <= 0) return false;
      return tc.passCount > 0 && (tc.passCount % N == 0);
    }

    case PRED_EQ:
      return v == p.operand;

    case PRED_GT:
      return v > p.operand;

    case PRED_LT:
      return v < p.operand;

    case PRED_PROBABILITY: {
      // operand interpreted as percent in [0, 100]. Compare a uniform
      // [0, 1) draw to operand / 100.
      const float pct = p.operand * 0.01f;
      if (pct <= 0.0f) return false;
      if (pct >= 1.0f) return true;
      std::uniform_real_distribution<float> uni(0.0f, 1.0f);
      return uni(slot.rng) < pct;
    }

    case PRED_APPROX: {
      // Fixed epsilon. 0.05 = ~0.6 semitones on V/oct, 50 mV on raw CV.
      // Tunable; per-column-aware epsilon is a possible Phase 2+ refinement.
      return std::fabs(v - p.operand) <= 0.05f;
    }

    case PRED_FIRE:
      // Slot-level (per the gate-row TODO model -- there's one gate
      // per slot, sourced from CV1's playhead row). colA ignored.
      return slot.firedThisTick;

    case PRED_CHANGED: {
      // Compare the inspected column's current playhead-row value to
      // the value captured at the end of last fireTick. NaN sentinel
      // means "no prior tick" -> never fires on the first tick after
      // init / reset.
      //
      // Row pin is intentionally ignored here -- tc.lastTickValue only
      // tracks the playhead row's prior value; pinned-row CHANGED
      // would need per-row history (multiplying state by
      // kMaxStepsPerColumn). PRED_CHANGED with colARow set silently
      // falls back to playhead-row behaviour; revisit if real
      // authoring patterns need it.
      const float prev = tc.lastTickValue;
      if (prev != prev) return false;        // NaN-safe
      return tc.l1[tc.playhead].value != prev;
    }

    // PRED_STEP_RANGE remains unimplemented in Phase 1.5 -- it needs a
    // second operand on the Predicate struct and ABI churn through
    // setL2 + bench + L2 getters. Folded into Phase 2 grammar/modal work.
    case PRED_STEP_RANGE:
    case PRED_NONE:
    default:
      return false;
  }
}

}}  // namespace od::sequencer

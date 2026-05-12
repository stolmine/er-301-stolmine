#include <od/sequencer/PredicateEval.h>

namespace od { namespace sequencer {

bool evaluate(const Slot& slot, const Predicate& p, int hostCol)
{
  // Default colA to hostCol when -1 (most common case: predicate references
  // the column the L2 cell lives in).
  int testCol = (p.colA >= 0 && p.colA < kNumColumns) ? p.colA : hostCol;
  if (testCol < 0 || testCol >= kNumColumns) {
    return false;
  }
  const Column& tc = slot.columns[testCol];
  const float v = tc.l1[tc.playhead].value;

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

    // Step-1-polish / Step 5 predicates — declared but not yet evaluated.
    // Returning false means L2 cells using these ops have no effect until
    // implemented.
    case PRED_PROBABILITY:  // needs mutable RNG; defer (would need non-const slot)
    case PRED_APPROX:
    case PRED_FIRE:
    case PRED_CHANGED:
    case PRED_STEP_RANGE:
    case PRED_NONE:
    default:
      return false;
  }
}

}}  // namespace od::sequencer

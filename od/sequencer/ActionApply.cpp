#include <od/sequencer/ActionApply.h>

namespace od { namespace sequencer {

void apply(Slot& slot, const Action& a, int hostCol)
{
  // Resolve target column: -1 means hostCol (self).
  int target = (a.targetCol >= 0 && a.targetCol < kNumColumns) ? a.targetCol : hostCol;
  if (target < 0 || target >= kNumColumns) {
    return;
  }
  Column& tc = slot.columns[target];
  const int row = tc.playhead;  // act at target column's current playhead row

  switch (a.op) {
    case ACTION_ADD:
      tc.l1[row].value += a.operand;
      break;

    case ACTION_SUB:
      tc.l1[row].value -= a.operand;
      break;

    case ACTION_SET:
      tc.l1[row].value = a.operand;
      break;

    case ACTION_MUL:
      tc.l1[row].value *= a.operand;
      break;

    case ACTION_DIV:
      if (a.operand != 0.0f) {
        tc.l1[row].value /= a.operand;
      }
      break;

    case ACTION_JUMP_THIS:
    case ACTION_JUMP_SELF:
      // Queue deferred jump for the target column. Applied at the next
      // tick boundary by Slot::fireTick.
      tc.pendingJump = static_cast<int>(a.operand);
      break;

    case ACTION_JUMP_GLOBAL:
      for (int c = 0; c < kNumColumns; ++c) {
        slot.columns[c].pendingJump = static_cast<int>(a.operand);
      }
      break;

    // Step-1-polish / Step 5 actions — declared but not yet applied.
    case ACTION_FIRE:   // gate-retrigger semantics ambiguous (see TODO(gate-row))
    case ACTION_RAND:   // needs RNG access; defer
    case ACTION_MUTE:
    case ACTION_NONE:
    default:
      break;
  }
}

}}  // namespace od::sequencer

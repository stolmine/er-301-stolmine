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
  // Row pin: when targetRow >= 0, the action writes to that specific
  // cell of `target`; otherwise (-1) it writes to `target`'s current
  // playhead row. JUMP* actions use a.operand as the row to jump TO
  // (not a cell to write at), so they reach for `row` here only when
  // they'd need to touch L1 cells (they don't).
  const int row = (a.targetRow >= 0 && a.targetRow < kMaxStepsPerColumn)
                  ? a.targetRow
                  : tc.playhead;

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

    case ACTION_FIRE: {
      // Re-arm the gate envelope. Duration = current heldGateLen *
      // samplesPerBeat using cached BPM / sample-rate. Amp keeps the
      // current heldGateAmp, falling back to 1.0 when zero so the
      // action has audible effect even on rows whose own gate-amp is
      // zero. No targetCol use (gate is slot-level).
      const float amp = slot.heldGateAmp > 0.0f ? slot.heldGateAmp : 1.0f;
      slot.heldGateAmp = amp;
      const float gateLen = slot.heldGateLen > 0.0f ? slot.heldGateLen : 0.0625f;
      const float samplesPerBeat = 60.0f * slot.cachedSampleRate / slot.cachedBpm;
      int n = static_cast<int>(gateLen * samplesPerBeat);
      if (n < 1) n = 1;
      slot.gateRemainingSamples = n;
      break;
    }

    case ACTION_RAND: {
      // Column-typed random per Sequencer's column conventions. Matches
      // the Lua-side randomForColumn in xroot/Sequencer/GridView.lua so
      // the L2 rand action and the selection-mode RANDOMIZE softkey draw
      // from the same distributions.
      switch (target) {
        case 0: {  // CV1 V/oct -- semitone-stepped, -5..+5 octaves
          std::uniform_int_distribution<int> semi(-60, 60);
          tc.l1[row].value = semi(slot.rng) / 12.0f;
          break;
        }
        case 1:
        case 2: {  // CV2 / CV3 raw volts, 0.1 V step in -5..+5 V
          std::uniform_int_distribution<int> v(-50, 50);
          tc.l1[row].value = v(slot.rng) * 0.1f;
          break;
        }
        case 3:
        case 5: {  // gate-len / step-len from the common-fraction set
          static const float beats[] = {
            0.0625f, 0.125f, 0.25f, 0.5f, 1.0f, 2.0f, 4.0f
          };
          std::uniform_int_distribution<int> b(0, 6);
          tc.l1[row].value = beats[b(slot.rng)];
          break;
        }
        case 4: {  // gate-amp 0..1, 0.05 step
          std::uniform_int_distribution<int> a(0, 20);
          tc.l1[row].value = a(slot.rng) * 0.05f;
          break;
        }
      }
      break;
    }

    case ACTION_MUTE:
      // Persistent zero of the target cell. Semantic alias for
      // ACTION_SET with operand 0; the M symbol conveys intent more
      // clearly in the cell editor.
      tc.l1[row].value = 0.0f;
      break;

    case ACTION_NONE:
    default:
      break;
  }
}

}}  // namespace od::sequencer

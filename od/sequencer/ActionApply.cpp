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

  // Normalize after every arithmetic write so columns with stricter
  // typing (currently just kColTranspose -> integer semitones) can't
  // be smuggled fractional by an L2 action. Other columns pass through
  // unchanged.
  switch (a.op) {
    case ACTION_ADD:
      tc.l1[row].value = normalizeL1Value(target, tc.l1[row].value + a.operand);
      break;

    case ACTION_SUB:
      tc.l1[row].value = normalizeL1Value(target, tc.l1[row].value - a.operand);
      break;

    case ACTION_SET:
      tc.l1[row].value = normalizeL1Value(target, a.operand);
      break;

    case ACTION_MUL:
      tc.l1[row].value = normalizeL1Value(target, tc.l1[row].value * a.operand);
      break;

    case ACTION_DIV:
      if (a.operand != 0.0f) {
        tc.l1[row].value = normalizeL1Value(target, tc.l1[row].value / a.operand);
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

    case ACTION_FIRE:
    case ACTION_FIRE1: {
      // Re-arm gate1's envelope. Duration = current heldGate1Len *
      // samplesPerBeat using cached BPM / sample-rate, with a
      // 0.0625-beat floor when heldGate1Len is zero so the action
      // stays audible on rows whose own g1L is zero. Amp constant 1.0
      // in v2. ACTION_FIRE (= 6) is the v0.1 back-compat alias; v2
      // authoring uses ACTION_FIRE1 (= 12). Both land here.
      slot.heldGate1Amp = 1.0f;
      const float gateLen = slot.heldGate1Len > 0.0f ? slot.heldGate1Len : 0.0625f;
      const float samplesPerBeat = 60.0f * slot.cachedSampleRate / slot.cachedBpm;
      int n = static_cast<int>(gateLen * samplesPerBeat);
      if (n < 1) n = 1;
      slot.gate1RemainingSamples = n;
      break;
    }

    case ACTION_FIRE2: {
      // Re-arm gate2's envelope. Symmetric to gate1: 0.0625-beat floor
      // when heldGate2Len is zero. Amp constant 1.0.
      slot.heldGate2Amp = 1.0f;
      const float gateLen = slot.heldGate2Len > 0.0f ? slot.heldGate2Len : 0.0625f;
      const float samplesPerBeat = 60.0f * slot.cachedSampleRate / slot.cachedBpm;
      int n = static_cast<int>(gateLen * samplesPerBeat);
      if (n < 1) n = 1;
      slot.gate2RemainingSamples = n;
      break;
    }

    case ACTION_RAND: {
      // Column-typed random per Sequencer's v2 column conventions.
      // Mirrors Lua-side randomForColumn in xroot/Sequencer/GridView.lua
      // so the L2 rand action and the selection-mode RANDOMIZE softkey
      // draw from matching distributions.
      switch (target) {
        case 0: {  // cv1 V/oct -- semitone-stepped, -5..+5 octaves
          std::uniform_int_distribution<int> semi(-60, 60);
          tc.l1[row].value = semi(slot.rng) / 12.0f;
          break;
        }
        case 1: {  // cv2 raw volts, 0.1 V step in -5..+5 V
          std::uniform_int_distribution<int> v(-50, 50);
          tc.l1[row].value = v(slot.rng) * 0.1f;
          break;
        }
        case 2:
        case 3: {  // g1L / g2L: gate-len common fractions; 4.0 is TIE,
                   // excluded from the random pool (Step 9 item 20).
          static const float beats[] = {
            0.0625f, 0.125f, 0.25f, 0.5f, 1.0f, 2.0f
          };
          std::uniform_int_distribution<int> b(0, 5);
          tc.l1[row].value = beats[b(slot.rng)];
          break;
        }
        case 4: {  // stL: step-len tick counts converted back to beats.
          static const int ticks[] = { 1, 2, 4, 8, 16, 32 };
          std::uniform_int_distribution<int> t(0, 5);
          tc.l1[row].value = ticks[t(slot.rng)] * 0.25f;
          break;
        }
        case 5: {  // tr: transpose semitones from a biased palette
                   // (zero-weighted, perfect 5ths, octaves).
          static const float palette[] = {
            0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
            -12.0f, -7.0f, -5.0f,
            0.0f, 5.0f, 7.0f, 12.0f
          };
          std::uniform_int_distribution<int> p(0, 11);
          tc.l1[row].value = palette[p(slot.rng)];
          break;
        }
      }
      break;
    }

    case ACTION_MUTE:
      // Persistent zero of the target cell. Semantic alias for
      // ACTION_SET with operand 0; the M symbol conveys intent more
      // clearly in the cell editor. normalizeL1Value clamps stL up
      // to 1 tick since 0 is not a valid step length.
      tc.l1[row].value = normalizeL1Value(target, 0.0f);
      break;

    case ACTION_NONE:
    default:
      break;
  }
}

}}  // namespace od::sequencer

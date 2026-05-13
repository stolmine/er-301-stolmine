#pragma once

// ER-301 stolmine sequencer — engine data structures.
//
// See docs/planning/sequencer-implementation-plan.md ("Locked decisions"
// section) for the v0.1 design contract this file implements.
//
// Real-time discipline: Slot::processFrame() runs on the audio thread.
// It MUST NOT allocate, take locks, or call into Lua. All std::vector
// members on Column / Slot are pre-sized in the ctor to
// kMaxStepsPerColumn so no .resize() is needed at runtime.

#include <cstdint>
#include <limits>
#include <random>
#include <vector>

namespace od { namespace sequencer {

// ---------------------------------------------------------------------------
// Top-level constants
// ---------------------------------------------------------------------------

constexpr int kNumSlots          = 4;
constexpr int kNumColumns        = 6;
constexpr int kMaxStepsPerColumn = 64;
constexpr int kPpqn              = 4;  // 1/16-note base tick (locked decision #4)

// Column indices — fixed assignment per the plan's grid layout:
//   ply1 = cv1, ply2 = cv2, ply3 = cv3,
//   ply4 = gate-len, ply5 = gate-amp, ply6 = step-len.
constexpr int kColCV1     = 0;
constexpr int kColCV2     = 1;
constexpr int kColCV3     = 2;
constexpr int kColGateLen = 3;
constexpr int kColGateAmp = 4;
constexpr int kColStepLen = 5;

enum ColumnType : uint8_t {
  CT_CV       = 0,  // -1..+1 typical, but accepts any float
  CT_GATE_LEN = 1,  // stored as beats (1.0 = quarter note)
  CT_GATE_AMP = 2,  // 0..1 typical
  CT_STEP_LEN = 3   // stored as beats; defines tick spacing
};

// ---------------------------------------------------------------------------
// L1 — typed-zero defaults, no nulls (locked decision: no nulls in L1)
// ---------------------------------------------------------------------------

struct L1Cell {
  float value = 0.0f;
};

// ---------------------------------------------------------------------------
// L2 grammar — predicate : action
//
// Symbol assignments here are internal engine enums; UI cell-editor symbol
// reconciliation is a separate concern (see "Deferred ambiguities" in the
// planning doc).
// ---------------------------------------------------------------------------

enum PredicateOp : uint8_t {
  PRED_NONE        = 0,
  // Step-1 subset (implemented now):
  PRED_MODULO      = 1,  // % N : true every Nth pass over this column
  PRED_EQ          = 2,  // = N : true when colA's L1 value == N
  PRED_GT          = 3,  // > N : true when colA's L1 value > N
  PRED_LT          = 4,  // < N : true when colA's L1 value < N
  // Step-1 polish / Step 5 (declared, not yet evaluated):
  PRED_PROBABILITY = 5,  // ? P : true with P% probability per tick
  PRED_APPROX      = 6,  // ~ N : true when colA approx == N
  PRED_FIRE        = 7,  // ! : detector — did colA fire this tick?
  PRED_CHANGED     = 8,  // detector — did colA's value change this tick?
  PRED_STEP_RANGE  = 9   // @ [a,b] : current step in inclusive range
};

enum ActionOp : uint8_t {
  ACTION_NONE        = 0,
  // Step-1 subset (implemented now):
  ACTION_ADD         = 1,  // +N : targetCol.l1[playhead] += N
  ACTION_SUB         = 2,  // -N : targetCol.l1[playhead] -= N
  ACTION_SET         = 3,  // =N : targetCol.l1[playhead] = N
  // Step-1 polish / Step 5 (declared, not yet applied):
  ACTION_MUL         = 4,  // *N
  ACTION_DIV         = 5,  // /N
  ACTION_FIRE        = 6,  // ! : retrigger gate (semantics TODO, see plan)
  ACTION_RAND        = 7,  // ? : set to random
  ACTION_MUTE        = 8,
  ACTION_JUMP_THIS   = 9,  // n : jump THIS column's playhead to row n
  ACTION_JUMP_GLOBAL = 10, // *n : jump ALL columns' playheads to row n
  ACTION_JUMP_SELF   = 11  // .n : jump own column to row n (== JUMP_THIS for L2)
};

struct Predicate {
  PredicateOp op = PRED_NONE;
  int8_t      colA = -1;    // referenced column for comparators (-1 = host col)
  int8_t      colARow = -1; // row pin within colA: -1 = use colA's playhead;
                            // 0..kMaxStepsPerColumn-1 = read this exact row
  float       operand = 0.0f;
};

struct Action {
  ActionOp op       = ACTION_NONE;
  int8_t   targetCol = -1;   // column the action mutates / fires
  int8_t   targetRow = -1;   // row pin within targetCol: -1 = use playhead;
                             // 0..kMaxStepsPerColumn-1 = write this exact row
  float    operand   = 0.0f;
};

struct L2Cell {
  bool      present = false;  // sentinel: when false, no rule on this row
  Predicate pred;
  Action    action;
};

// ---------------------------------------------------------------------------
// Column — one ply of one slot
// ---------------------------------------------------------------------------

class Column {
public:
  Column();

  std::vector<L1Cell> l1;   // size = kMaxStepsPerColumn; logical size = `length`
  std::vector<L2Cell> l2;   // parallel; .present gates eval

  int length    = 16;        // logical number of rows in use
  int marker1   = 0;         // raw markers; loop region = [min(m1,m2), max(m1,m2)]
  int marker2   = 15;
  int playhead  = 0;         // row that the NEXT fireTick will read
  int currentRow = 0;        // row that the engine is presently emitting
                             // (captured at top of fireTick before the
                             // playhead advance at the end). UI reads
                             // this via SequencerTask::playhead so the
                             // visible highlight matches what's audible.
  int passCount = 0;         // increments each time playhead wraps the loop end

  // Reserved for tick-boundary deferred jumps (e.g. ACTION_JUMP_*).
  // -1 = no pending jump; >= 0 = jump target row, applied at next tick start.
  int pendingJump = -1;

  // Last-tick playhead-row L1 value, captured at the END of fireTick
  // (after L2 actions may have mutated L1). Used by PRED_CHANGED:
  // "did THIS column's playhead-row value differ from last tick's?"
  // NaN sentinel means "no prior tick" -- PRED_CHANGED returns false
  // on the first tick after init/reset.
  float lastTickValue = std::numeric_limits<float>::quiet_NaN();

  // Last row where this column's L2 cell evaluated true and applied
  // its action. -1 = never fired (or reset). Set in fireTick step 3
  // when the L2 cell at the playhead row fires. UI side uses this to
  // render a "fired" indicator dot that decays Lua-side after a few
  // frames. Survives across ticks (engine only writes when a fire
  // actually happens); the UI handles decay timing.
  int lastL2FiredRow = -1;
  // Monotonic counter of fires on this column. Incremented each
  // time an L2 cell here evaluates true. UI compares deltas so a
  // SAME-row repeat fire (e.g. a %N rule on a single cell) is
  // detected as a fresh event rather than as "same as last time."
  uint32_t l2FireSerial = 0;

  // Loop-region helpers (direction-tolerant per locked decision #2).
  int loopMin() const;
  int loopMax() const;
};

// ---------------------------------------------------------------------------
// Slot — one sequencer instance (4 of these per SequencerTask)
// ---------------------------------------------------------------------------

class Slot {
public:
  Slot();
  void init(int slotIdx);  // explicit init so SequencerTask can have Slot[] arrays

  Column        columns[kNumColumns];
  std::mt19937  rng;
  int           samplesUntilTick = 0;
  bool          running          = false;

  // Sample-and-hold of column values, refreshed on every tick:
  float heldCV1     = 0.0f;
  float heldCV2     = 0.0f;
  float heldCV3     = 0.0f;
  float heldGateLen = 0.0f;  // raw beats (from gate-len column at CV1's row)
  float heldStepLen = 0.0f;  // raw beats (from step-len column's own row)

  // Gate-amp output is an ENVELOPE, not a plain S&H:
  //   on tick fire, if the row's gate-amp value > 0 we retrigger:
  //     gateEnvelopeAmp     = rowValue
  //     gateRemainingSamples = gateLenBeats * samplesPerBeat
  //   else we leave the existing envelope counting down.
  //   On every output sample, emit gateEnvelopeAmp if remaining > 0 else 0.
  float heldGateAmp        = 0.0f;
  int   gateRemainingSamples = 0;

  // Cached at start of processFrame so fireTick() can reach BPM/SR
  float cachedBpm        = 120.0f;
  float cachedSampleRate = 48000.0f;

  // Set true at the top of every fireTick whenever this tick retriggers
  // the gate (gate-amp > 0 at CV1's playhead row, per the gate-row TODO
  // model). Read by PRED_FIRE. Slot-level until the per-column gate
  // resolution lands (Sequencer.h gate-row TODO).
  bool firedThisTick = false;

  // ---- audio-thread API ----
  // Fill `frameLen` samples into each of the 6 output buffers. May fire
  // 0 or more ticks during this frame. NOT thread-safe; must run on
  // the audio thread, called by SequencerTask::process.
  void processFrame(int frameLen,
                    float* cv1, float* cv2, float* cv3,
                    float* gateLen, float* gateAmp, float* stepLen,
                    float bpm, float sampleRate);

  // ---- bench / Lua API ----
  // Safe to call from non-audio threads; not real-time clean.
  // (For Step 1 bench harness: poke values and start, then read audio buffers.)
  void setL1(int col, int row, float value);
  void setColumnLength(int col, int length);
  void setMarkers(int col, int m1, int m2);
  void setL2(int col, int row, const Predicate& p, const Action& a);
  void clearL2(int col, int row);
  void start();
  void stop();
  void reset();
  void seedRng(uint32_t seed);

  // ---- introspection ----
  int playhead(int col) const;
  float l1Value(int col, int row) const;

  // ---- bench-only ----
  // Synchronously fire one tick (sample-and-hold + L2 eval + advance),
  // bypassing the audio thread's scheduling. Intended for the Lua bench
  // harness with a stopped slot (running=false), where deterministic
  // state inspection is the goal. If called on a running slot, the
  // audio thread's own ticks will continue in parallel and timing will
  // become non-deterministic.
  void tickOnce();

private:
  // Fire one tick: emit current-row sample-and-hold, gate retrigger if
  // applicable, then advance each column's playhead within its loop region
  // (applying any pendingJump). Returns the number of samples until the
  // next tick should fire (driven by the step-len column at its just-emitted
  // row).
  int fireTick();
};

// TODO(gate-row): Working assumption for v0.1 — gate-len and gate-amp values
// are read from CV1's playhead row when any tick fires. The polymetric model
// permits each column to have its own playhead, so "which column's row
// defines THE step?" is a real spec question. Needs resolution before Step 4
// (grid view UI). See docs/planning/sequencer-implementation-plan.md
// "Open ambiguities flagged" section.

}}  // namespace od::sequencer

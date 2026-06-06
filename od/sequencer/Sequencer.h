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

// Column indices — v2 layout (Milestone B, 2026-05-15):
//   ply1 = cv1 (V/oct, transpose pre-applied),
//   ply2 = cv2 (raw modulator),
//   ply3 = g1L (gate-1 length; amp constant 1.0),
//   ply4 = g2L (gate-2 length; amp constant 1.0),
//   ply5 = stL (step-len, host-only),
//   ply6 = tr  (transpose semitones, meta -- shifts cv1 only).
// Drops cv3 and gate-amp from the v0.1 layout in favour of an
// independent second gate and a per-row transpose lane.
constexpr int kColCV1       = 0;
constexpr int kColCV2       = 1;
constexpr int kColGate1Len  = 2;
constexpr int kColGate2Len  = 3;
constexpr int kColStepLen   = 4;
constexpr int kColTranspose = 5;

enum ColumnType : uint8_t {
  CT_CV        = 0,  // -1..+1 typical, but accepts any float
  CT_GATE_LEN  = 1,  // stored as beats (1.0 = quarter note)
  CT_STEP_LEN  = 2,  // stored as beats; defines tick spacing
  CT_TRANSPOSE = 3   // integer semitones (stored as float); pre-applied to cv1
};

// ---------------------------------------------------------------------------
// L1 — typed-zero defaults, no nulls (locked decision: no nulls in L1)
// ---------------------------------------------------------------------------

struct L1Cell {
  float value = 0.0f;
};

// Per-column write normalizer. tr (transpose) snaps to the nearest
// integer semitone -- microtones aren't expressive enough to justify
// the off-grid drift, the UI clamp already snaps interactive edits
// to ints, and L2 actions / pastes would otherwise sneak fractional
// values in (e.g. ACTION_DIV with a non-integer divisor). Other
// columns pass through unchanged.
inline float normalizeL1Value(int col, float v) {
  if (col == kColTranspose) {
    // floor(x + 0.5) round, NaN-safe (NaN > 0 is false, NaN < 0 is
    // false, so NaN falls through to 0.0 -- acceptable for a hidden
    // sentinel that should never reach storage anyway).
    if (v != v) return 0.0f;
    if (v >= 0.0f) {
      float n = (float)((int)(v + 0.5f));
      return n;
    }
    float n = (float)(-(int)(-v + 0.5f));
    return n;
  }
  return v;
}

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
  PRED_FIRE        = 7,  // ! : detector — did slot fire (either gate) this tick?
  PRED_CHANGED     = 8,  // detector — did colA's value change this tick?
  PRED_STEP_RANGE  = 9,  // @ [a,b] : current step in inclusive range
  // v2 grammar additions (Milestone B): per-gate detectors. PRED_FIRE
  // stays as the slot-level OR so v0.1 quicksaves keep meaningful
  // semantics ("any gate fired") after migration.
  PRED_FIRE1       = 10, // !1 : did gate1 retrigger this tick?
  PRED_FIRE2       = 11  // !2 : did gate2 retrigger this tick?
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
  ACTION_FIRE        = 6,  // ! : retrigger gate1 (v0.1 alias; v2 saves use ACTION_FIRE1 explicitly)
  ACTION_RAND        = 7,  // ? : set to random
  ACTION_MUTE        = 8,
  ACTION_JUMP_THIS   = 9,  // n : jump THIS column's playhead to row n
  ACTION_JUMP_GLOBAL = 10, // *n : jump ALL columns' playheads to row n
  ACTION_JUMP_SELF   = 11, // .n : jump own column to row n (== JUMP_THIS for L2)
  // v2 grammar additions (Milestone B): per-gate retrigger.
  // ACTION_FIRE = 6 stays as the back-compat alias for "fire gate1".
  // v0.1 quicksaves with ACTION_FIRE keep working; v2 authoring uses
  // the explicit FIRE1 / FIRE2 names cycled in the cell editor.
  ACTION_FIRE1       = 12, // !1 : retrigger gate1 (explicit)
  ACTION_FIRE2       = 13  // !2 : retrigger gate2
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
  float heldCV1       = 0.0f;  // cv1Raw + heldTranspose / 12 (pre-applied)
  float heldCV2       = 0.0f;
  float heldGate1Len  = 0.0f;  // raw beats (>= 3.999 = TIE sentinel)
  float heldGate2Len  = 0.0f;  // raw beats (>= 3.999 = TIE sentinel)
  float heldStepLen   = 0.0f;  // raw beats
  float heldTranspose = 0.0f;  // semitones (int-valued in practice)

  // Gate outputs are ENVELOPES, not plain S&H:
  //   on tick fire, if the row's gate-len > 0 we retrigger:
  //     heldGateNAmp           = 1.0  (v2 amp is constant)
  //     gateNRemainingSamples  = gateLenBeats * samplesPerBeat
  //   else we leave the existing envelope counting down. TIE rows
  //   (gateLen >= kTieThreshold) extend an in-flight gate without
  //   re-edging (firedGateNThisTick stays false) or start fresh if
  //   no gate is in flight.
  float heldGate1Amp = 0.0f;
  float heldGate2Amp = 0.0f;
  int   gate1RemainingSamples = 0;
  int   gate2RemainingSamples = 0;

  // Cached at start of processFrame so fireTick() can reach BPM/SR
  float cachedBpm        = 120.0f;
  float cachedSampleRate = 48000.0f;

  // Per-gate "did this tick produce an EDGE on this gate?" flags.
  // TIE-extend preserves an in-flight gate without re-edging so the
  // corresponding firedGateNThisTick stays false. firedThisTick is
  // the slot-level OR of both -- v0.1 PRED_FIRE keeps its
  // "any gate fired" semantics for back-compat. PRED_FIRE1 /
  // PRED_FIRE2 (v2 grammar) read the per-gate flags directly.
  bool firedThisTick      = false;
  bool firedGate1ThisTick = false;
  bool firedGate2ThisTick = false;

  // ---- audio-thread API ----
  // Fill `frameLen` samples into each of the output buffers. Four are
  // picker-exposed (cv1, cv2, gate1Amp, gate2Amp); two are internal
  // (stepLen, transpose) -- present for debug / future tooling but
  // not registered as picker sources. May fire 0 or more ticks during
  // this frame. NOT thread-safe; must run on the audio thread,
  // called by SequencerTask::process.
  //
  // Used when SequencerTask::clockSource == CLOCK_INTERNAL. The slot
  // owns its own samplesUntilTick countdown driven by the just-emitted
  // stepLen column row.
  void processFrame(int frameLen,
                    float* cv1, float* cv2,
                    float* gate1Amp, float* gate2Amp,
                    float* stepLen, float* transpose,
                    float bpm, float sampleRate);

  // Externally-clocked counterpart of processFrame. Emits the same
  // six output buffers (S&H + gate envelopes) but does NOT decrement
  // samplesUntilTick or call fireTick() internally. Ticks are driven
  // externally via Slot::externalTick() called from SequencerTask on
  // master-tick boundaries. Used when SequencerTask::clockSource ==
  // CLOCK_EXTERNAL. Per-slot polymetric stepLen-driven scheduling
  // is suppressed in this mode; the divider counter in SequencerTask
  // takes over.
  void processFrameExternal(int frameLen,
                            float* cv1, float* cv2,
                            float* gate1Amp, float* gate2Amp,
                            float* stepLen, float* transpose);

  // Public entry point for an externally-driven tick. Same body as
  // the private fireTick() (S&H + L2 eval + advance + envelope
  // retrigger). Discards the next-interval return value because the
  // external clock owns scheduling. BPM is used for gate-length
  // math only (samplesPerBeat in fireGate); SR is needed for the
  // same calculation. No-op when !running, matching processFrame's
  // gate-silent behaviour when stopped.
  void externalTick(float bpm, float sampleRate);

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

// Gate-row resolution: each column reads from its OWN playhead row
// (cv1, cv2, g1L, g2L, stL, tr all polymetric). PRED_FIRE reads the
// slot's firedThisTick (any-gate OR); PRED_FIRE1 / PRED_FIRE2 read
// the per-gate firedGateNThisTick flags directly. Transpose is
// pre-applied to cv1's sample-and-hold at the top of fireTick so
// the cv1 audio buffer carries the transposed value -- the UI grid
// continues to display the un-transposed cv1 cell value for
// authoring clarity (transpose is its own column to edit).

}}  // namespace od::sequencer

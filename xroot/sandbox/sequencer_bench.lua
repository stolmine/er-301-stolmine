-- ER-301 stolmine sequencer Step-1 bench harness.
--
-- Loaded automatically near the end of xroot/boot/start.lua for Step-1
-- verification. Output goes to app.logInfo / logError which appears in
-- the emu log at /tmp/emu.log.
--
-- Strategy: keep slots STOPPED (no audio-thread ticking) and use the
-- synchronous tickOnce() proxy on SequencerTask to advance ticks
-- deterministically. Verifies engine state via playhead / heldCV /
-- l1Value proxies. Audio-thread integration is verified separately by
-- the fact that the emu boots without crashes (SequencerTask::process
-- runs each frame, filling the 24 outlet buffers).
--
-- Bench uses slot 3 so its mutations to column length / markers / L1
-- cells do NOT leak into slot 0 (the slot the UI displays by default).
-- resetSlot() only rewinds the playhead; it does NOT restore length
-- or markers, so running these tests on slot 0 leaves it in a state
-- where col 0 and col 1 are length 2 with markers (0,1) -- causing
-- the visible UI to look like the playhead "skips" rows 2-15 on
-- those columns after a fresh boot. Routing bench through slot 3
-- keeps slot 0 at its C++ init defaults.

local seq = app.AudioThread.getSequencerTask()
if not seq then
  app.logError("sequencer_bench: SequencerTask not available; aborting.")
  return
end

-- PredicateOp / ActionOp enum values, mirroring od/sequencer/Sequencer.h
local PRED_MODULO  = 1
local PRED_EQ      = 2
local PRED_GT      = 3
local PRED_LT      = 4

local PRED_PROBABILITY = 5
local PRED_APPROX      = 6
local PRED_FIRE        = 7
local PRED_CHANGED     = 8

local ACTION_ADD   = 1
local ACTION_SUB   = 2
local ACTION_SET   = 3
local ACTION_FIRE  = 6
local ACTION_RAND  = 7
local ACTION_MUTE  = 8

-- Column indices, mirroring od/sequencer/Sequencer.h
local COL_CV1      = 0
local COL_CV2      = 1
local COL_CV3      = 2
local COL_GATE_LEN = 3
local COL_GATE_AMP = 4
local COL_STEP_LEN = 5

-- Slot used by all bench tests. Anything but 0 (the UI's default).
local SLOT = 3

local function approxEq(a, b, eps)
  eps = eps or 1e-5
  return math.abs(a - b) < eps
end

local results = {}
local function pass(name)
  results[#results + 1] = { name = name, ok = true }
  app.logInfo("sequencer_bench: %s ... PASS", name)
end

local function fail(name, msg)
  results[#results + 1] = { name = name, ok = false, msg = msg }
  app.logError("sequencer_bench: %s ... FAIL: %s", name, msg or "(no detail)")
end

-- ---------------------------------------------------------------------------
-- Test 1: static 16-step CV pattern on a single column
-- ---------------------------------------------------------------------------
local function test_static_16_step()
  local name = "static-16-step-cv"
  seq:resetSlot(SLOT)
  seq:setColumnLength(SLOT, COL_CV1, 16)
  seq:setMarkers(SLOT, COL_CV1, 0, 15)
  for r = 0, 15 do
    seq:setL1(SLOT, COL_CV1, r, r * 0.1)
  end

  -- Each tickOnce captures heldCV1 from the current playhead BEFORE
  -- advancing, then advances. Iteration i fires tick (i+1):
  --   iter 0 -> heldCV1 == row 0 value (0.0)
  --   iter 15 -> heldCV1 == row 15 value (1.5)
  for iter = 0, 15 do
    seq:tickOnce(SLOT)
    local expected = iter * 0.1
    local got = seq:heldCV1(SLOT)
    if not approxEq(got, expected) then
      fail(name, string.format("iter %d: expected heldCV1=%.3f, got %.3f",
                                iter, expected, got))
      return
    end
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 2: polymetric 5/7 -- columns with different lengths advance
-- independently. After LCM(5,7) + 1 = 36 ticks, both columns have just
-- emitted row 0, so seq:playhead (which returns currentRow = the
-- last-emitted row) reads 0 on both. The +1 accounts for the new
-- "playhead returns currently-emitting row, not next-to-emit row"
-- semantic introduced in Step 9.
-- ---------------------------------------------------------------------------
local function test_polymetric_5_7()
  local name = "polymetric-5-and-7"
  seq:resetSlot(SLOT)
  -- Column 0: length 5
  seq:setColumnLength(SLOT, COL_CV1, 5)
  seq:setMarkers(SLOT, COL_CV1, 0, 4)
  for r = 0, 4 do seq:setL1(SLOT, COL_CV1, r, r) end
  -- Column 1: length 7
  seq:setColumnLength(SLOT, COL_CV2, 7)
  seq:setMarkers(SLOT, COL_CV2, 0, 6)
  for r = 0, 6 do seq:setL1(SLOT, COL_CV2, r, 100 + r) end

  for _ = 1, 36 do seq:tickOnce(SLOT) end

  local ph0 = seq:playhead(SLOT, COL_CV1)
  local ph1 = seq:playhead(SLOT, COL_CV2)
  if ph0 ~= 0 then
    fail(name, string.format("col 0 playhead expected 0 after 35 ticks, got %d", ph0))
    return
  end
  if ph1 ~= 0 then
    fail(name, string.format("col 1 playhead expected 0 after 35 ticks, got %d", ph1))
    return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 3: L2 destructive write -- %2 : B+1 on col 0 row 0.
--
-- length=2, markers=(0,1) for both cols. Trace:
--   tick 1: col0 row 0, passCount=0; L2 eval: 0>0 false; advance 0->1
--   tick 2: col0 row 1; advance 1->0 (wrap, passCount=1)
--   tick 3: col0 row 0, passCount=1; L2 eval: 1%2=1 false; advance 0->1
--   tick 4: col0 row 1; advance 1->0 (wrap, passCount=2)
--   tick 5: col0 row 0, passCount=2; L2 eval: 2>0 && 2%2=0 TRUE!
--           action: +1 to col1[col1.playhead=0]. col1[0] 5.0 -> 6.0
-- After 5 ticks, col1[0] should be 6.0.
-- ---------------------------------------------------------------------------
local function test_l2_destructive_write()
  local name = "l2-destructive-mod2-add1"
  seq:resetSlot(SLOT)
  seq:setColumnLength(SLOT, COL_CV1, 2)
  seq:setMarkers(SLOT, COL_CV1, 0, 1)
  seq:setColumnLength(SLOT, COL_CV2, 2)
  seq:setMarkers(SLOT, COL_CV2, 0, 1)
  seq:setL1(SLOT, COL_CV2, 0, 5.0)

  -- L2 cell on col 0 row 0: predicate %2 (every 2 passes of host),
  -- action +1 to col 1 at col 1's current playhead. -1 for both row
  -- pins so the rule keeps its original playhead-relative semantics.
  seq:setL2(SLOT, COL_CV1, 0,
            PRED_MODULO, -1, -1, 2,         -- predicate: %2 on host column
            ACTION_ADD,  COL_CV2, -1, 1.0)  -- action: +1 to col 1

  for _ = 1, 5 do seq:tickOnce(SLOT) end

  local v = seq:l1Value(SLOT, COL_CV2, 0)
  if not approxEq(v, 6.0) then
    fail(name, string.format("col 1 row 0 expected 6.0 after 5 ticks, got %.3f", v))
    return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 4: L2 Phase 1.5 polish ops -- exercise the four new predicates
-- (PRED_PROBABILITY, PRED_APPROX, PRED_FIRE, PRED_CHANGED) and three new
-- actions (ACTION_MUTE, plus ACTION_FIRE and ACTION_RAND are
-- non-deterministic targets, so we cover the deterministic ones).
--
-- Layout: CV1 is a 4-step loop driving the L2 program; CV2 is pinned to
-- a 1-step loop (length=1, markers 0..0) so its playhead stays at row 0
-- and acts as a target accumulator we can read back.
--   CV1 row 0: ?100  : B+1   (always fires, accumulates CV2)
--   CV1 row 1: !     : B=5   (fires on slot gate retrigger -> CV2 := 5)
--   CV1 row 2: c     : B+1   (CV1's value didn't change -> skip)
--   CV1 row 3: ~0    : BM    (CV1[3]=0 approx 0 -> MUTE CV2)
-- Gate-amp[1] = 1.0 so tick 2 retriggers the slot gate; other rows = 0.
-- ---------------------------------------------------------------------------
local function test_l2_phase15_polish()
  local name = "l2-phase15-polish"
  seq:resetSlot(SLOT)
  -- Clear any L2 cells left over from prior tests on CV1's first 4 rows.
  for r = 0, 3 do seq:clearL2(SLOT, COL_CV1, r) end

  -- CV1: 4-step loop with all cells explicitly zeroed. resetSlot only
  -- rewinds the playhead -- it does NOT clear L1 values, so prior tests
  -- (e.g. static-16-step leaves cv1[r] = r*0.1) would otherwise leak
  -- non-zero values into PRED_CHANGED / PRED_APPROX assertions below.
  seq:setColumnLength(SLOT, COL_CV1, 4)
  seq:setMarkers(SLOT, COL_CV1, 0, 3)
  for r = 0, 3 do seq:setL1(SLOT, COL_CV1, r, 0.0) end
  -- CV2: 1-step loop pinned at row 0 -- the target accumulator.
  seq:setColumnLength(SLOT, COL_CV2, 1)
  seq:setMarkers(SLOT, COL_CV2, 0, 0)
  seq:setL1(SLOT, COL_CV2, 0, 0.0)
  -- Gate-amp pattern: only row 1 is non-zero so tick 2 retriggers gate.
  seq:setL1(SLOT, COL_GATE_AMP, 0, 0.0)
  seq:setL1(SLOT, COL_GATE_AMP, 1, 1.0)
  seq:setL1(SLOT, COL_GATE_AMP, 2, 0.0)
  seq:setL1(SLOT, COL_GATE_AMP, 3, 0.0)
  seq:seedRng(SLOT, 0xCAFE)

  -- All rules use -1 for both row pins (predColARow / actTargetRow)
  -- so behaviour matches pre-row-pin semantics.
  seq:setL2(SLOT, COL_CV1, 0,
            PRED_PROBABILITY, -1, -1, 100.0,
            ACTION_ADD, COL_CV2, -1, 1.0)
  seq:setL2(SLOT, COL_CV1, 1,
            PRED_FIRE, -1, -1, 0.0,
            ACTION_SET, COL_CV2, -1, 5.0)
  seq:setL2(SLOT, COL_CV1, 2,
            PRED_CHANGED, -1, -1, 0.0,
            ACTION_ADD, COL_CV2, -1, 1.0)
  seq:setL2(SLOT, COL_CV1, 3,
            PRED_APPROX, -1, -1, 0.0,
            ACTION_MUTE, COL_CV2, -1, 0.0)

  -- Tick 1: PROB 100 -> ADD +1 -> CV2 = 1.
  seq:tickOnce(SLOT)
  local v = seq:l1Value(SLOT, COL_CV2, 0)
  if not approxEq(v, 1.0) then
    fail(name, string.format("tick1 expected CV2=1.0 (PROB+ADD), got %.3f", v))
    return
  end
  -- Tick 2: gate-amp[1]=1.0 -> firedThisTick -> PRED_FIRE -> SET 5.
  seq:tickOnce(SLOT)
  v = seq:l1Value(SLOT, COL_CV2, 0)
  if not approxEq(v, 5.0) then
    fail(name, string.format("tick2 expected CV2=5.0 (FIRE+SET), got %.3f", v))
    return
  end
  -- Tick 3: PRED_CHANGED on CV1: cv1[2]=0 vs lastTickValue=0 -> not
  -- changed -> ACTION_ADD skipped. CV2 stays at 5.
  seq:tickOnce(SLOT)
  v = seq:l1Value(SLOT, COL_CV2, 0)
  if not approxEq(v, 5.0) then
    fail(name, string.format("tick3 expected CV2=5.0 (CHANGED stays false), got %.3f", v))
    return
  end
  -- Tick 4: PRED_APPROX 0 -> cv1[3]=0 within eps -> MUTE -> CV2 = 0.
  seq:tickOnce(SLOT)
  v = seq:l1Value(SLOT, COL_CV2, 0)
  if not approxEq(v, 0.0) then
    fail(name, string.format("tick4 expected CV2=0.0 (APPROX+MUTE), got %.3f", v))
    return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 5: persistence roundtrip
--
-- Authors a known state, serializes via xroot/Sequencer/Persist.lua,
-- wipes the slot, deserializes, asserts the state survived. Catches
-- schema breaks at boot before they bite a real quicksave save+load.
-- ---------------------------------------------------------------------------
local function test_persistence_roundtrip()
  local name = "persistence-roundtrip"
  local Persist = require "Sequencer.Persist"

  -- 1. Author a recognizable slot state.
  seq:resetSlot(SLOT)
  seq:setColumnLength(SLOT, COL_CV1, 12)
  seq:setMarkers(SLOT, COL_CV1, 2, 9)
  seq:setL1(SLOT, COL_CV1, 0, 0.5)
  seq:setL1(SLOT, COL_CV1, 1, -1.25)
  seq:setL1(SLOT, COL_CV1, 5, 3.0)
  -- L2 rule on cv1 row 4: PRED_APPROX A07 ~ 0.5 -> ACTION_SET B12 = 7.
  -- Exercises both row pins to cover the Phase 2 fields end-to-end.
  for r = 0, 15 do seq:clearL2(SLOT, COL_CV1, r) end
  seq:setL2(SLOT, COL_CV1, 4,
            PRED_APPROX, COL_CV1, 7, 0.5,
            ACTION_SET,  COL_CV2, 12, 7.0)

  -- 2. Snapshot via the persist module.
  local data = Persist.serialize()
  if not (data and data.slots and data.slots[SLOT + 1]) then
    fail(name, "serialize() returned empty data")
    return
  end

  -- 3. Wipe the slot so any surviving values prove deserialize works.
  seq:setColumnLength(SLOT, COL_CV1, 4)
  seq:setMarkers(SLOT, COL_CV1, 0, 3)
  for r = 0, 15 do
    seq:setL1(SLOT, COL_CV1, r, 0.0)
    seq:clearL2(SLOT, COL_CV1, r)
  end

  -- 4. Apply the snapshot back.
  Persist.deserialize(data)

  -- 5. Assert the persistent fields all round-tripped.
  if seq:columnLength(SLOT, COL_CV1) ~= 12 then
    fail(name, string.format("columnLength expected 12, got %d",
                              seq:columnLength(SLOT, COL_CV1)))
    return
  end
  if seq:marker1(SLOT, COL_CV1) ~= 2
     or seq:marker2(SLOT, COL_CV1) ~= 9 then
    fail(name, string.format("markers expected (2,9), got (%d,%d)",
                              seq:marker1(SLOT, COL_CV1),
                              seq:marker2(SLOT, COL_CV1)))
    return
  end
  if not approxEq(seq:l1Value(SLOT, COL_CV1, 0), 0.5) then
    fail(name, "l1[0] != 0.5"); return
  end
  if not approxEq(seq:l1Value(SLOT, COL_CV1, 1), -1.25) then
    fail(name, "l1[1] != -1.25"); return
  end
  if not approxEq(seq:l1Value(SLOT, COL_CV1, 5), 3.0) then
    fail(name, "l1[5] != 3.0"); return
  end
  if not seq:l2Present(SLOT, COL_CV1, 4) then
    fail(name, "L2 cell at row 4 missing after roundtrip"); return
  end
  if seq:l2PredOp(SLOT, COL_CV1, 4) ~= PRED_APPROX
     or seq:l2PredColA(SLOT, COL_CV1, 4) ~= COL_CV1
     or seq:l2PredColARow(SLOT, COL_CV1, 4) ~= 7
     or not approxEq(seq:l2PredVal(SLOT, COL_CV1, 4), 0.5) then
    fail(name, "L2 predicate fields drifted"); return
  end
  if seq:l2ActOp(SLOT, COL_CV1, 4) ~= ACTION_SET
     or seq:l2ActTgt(SLOT, COL_CV1, 4) ~= COL_CV2
     or seq:l2ActTgtRow(SLOT, COL_CV1, 4) ~= 12
     or not approxEq(seq:l2ActVal(SLOT, COL_CV1, 4), 7.0) then
    fail(name, "L2 action fields drifted"); return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Run all tests, then reset the slot state so the bench leaves no trace.
-- ---------------------------------------------------------------------------
app.logInfo("sequencer_bench: starting Step-1 bench tests")

test_static_16_step()
test_polymetric_5_7()
test_l2_destructive_write()
test_l2_phase15_polish()
test_persistence_roundtrip()

local total = #results
local pass_count = 0
for _, r in ipairs(results) do
  if r.ok then pass_count = pass_count + 1 end
end
app.logInfo("sequencer_bench: %d/%d PASS", pass_count, total)

-- Leave all slots clean
for s = 0, 3 do seq:resetSlot(s) end

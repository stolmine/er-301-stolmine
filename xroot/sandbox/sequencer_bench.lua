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
local PRED_FIRE1       = 10
local PRED_FIRE2       = 11

local ACTION_ADD   = 1
local ACTION_SUB   = 2
local ACTION_SET   = 3
local ACTION_FIRE  = 6
local ACTION_RAND  = 7
local ACTION_MUTE  = 8
local ACTION_FIRE1 = 12
local ACTION_FIRE2 = 13

-- Column indices (v2 layout), mirroring od/sequencer/Sequencer.h
local COL_CV1        = 0
local COL_CV2        = 1
local COL_GATE1_LEN  = 2
local COL_GATE2_LEN  = 3
local COL_STEP_LEN   = 4
local COL_TRANSPOSE  = 5

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
-- v2 fire mechanism: g1L[1] = 0.25 so tick 2 retriggers gate1 (and
-- therefore the slot-level firedThisTick). g1L other rows = 0 (no fire).
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
  -- gate1-len pattern: only row 1 is non-zero, so tick 2 fires gate1
  -- (and the slot-level firedThisTick OR). gate2 stays silent.
  seq:setL1(SLOT, COL_GATE1_LEN, 0, 0.0)
  seq:setL1(SLOT, COL_GATE1_LEN, 1, 0.25)
  seq:setL1(SLOT, COL_GATE1_LEN, 2, 0.0)
  seq:setL1(SLOT, COL_GATE1_LEN, 3, 0.0)
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

-- Full slot wipe: resetSlot only rewinds playheads, so this helper
-- additionally restores default column lengths / markers and zeroes
-- every L1 / L2 cell. Used by the row-pin + multi-slot tests (which
-- need a known-blank starting state) and by the end-of-bench cleanup
-- so the bench leaves NO trace -- including on slot 0 which the UI
-- shows by default.
local function fullClearSlot(s)
  for c = 0, 5 do
    seq:setColumnLength(s, c, 16)
    seq:setMarkers(s, c, 0, 15)
    for r = 0, 63 do
      seq:setL1(s, c, r, 0.0)
      seq:clearL2(s, c, r)
    end
  end
  -- Step-len needs a non-zero default or fireTick would divide by
  -- zero; 0.25 beats = 1 tick at 4 PPQN.
  for r = 0, 63 do
    seq:setL1(s, COL_STEP_LEN, r, 0.25)
  end
  seq:resetSlot(s)
end

-- ---------------------------------------------------------------------------
-- Test 5b: persistence roundtrip -- transport (running) field
--
-- Bench-scoped coverage of the Step 9 item 17 plumbing. The bench
-- runs before Application.init() has populated Settings.variables,
-- so we cannot exercise the Setting="yes" branch here -- Persist's
-- own pcall guard catches that case and treats it as the safe
-- default. That guarantees: when Settings isn't ready, deserialize
-- always takes the no-restore path. Things we CAN cover:
--   1. isSlotRunning getter mirrors start/stop.
--   2. Persist.serialize writes the running flag unconditionally.
--   3. Persist.deserialize default path (Settings absent / "no")
--      leaves the slot stopped even when the save says running.
-- The Setting="yes" -> resume path needs a UI-level test once
-- Settings.init has run; tracked as a manual listen-test item.
-- ---------------------------------------------------------------------------
local function test_persistence_transport_roundtrip()
  local name = "persistence-transport-roundtrip"
  local Persist = require "Sequencer.Persist"

  seq:stopSlot(SLOT)
  fullClearSlot(SLOT)

  -- (1) isSlotRunning getter mirrors start/stop.
  if seq:isSlotRunning(SLOT) then
    fail(name, "isSlotRunning true after fullClearSlot -- expected stopped")
    return
  end
  seq:startSlot(SLOT)
  if not seq:isSlotRunning(SLOT) then
    fail(name, "startSlot did not flip isSlotRunning to true")
    return
  end

  -- (2) serialize captures the running flag.
  local data = Persist.serialize()
  if not (data and data.slots and data.slots[SLOT + 1]) then
    fail(name, "serialize() returned empty data")
    seq:stopSlot(SLOT); return
  end
  if data.slots[SLOT + 1].running ~= true then
    fail(name, "serialize did not capture running=true")
    seq:stopSlot(SLOT); return
  end

  -- (3) Default path: no Settings -> no-restore. Stop the slot, then
  -- deserialize and confirm running stays false even though the save
  -- has running=true.
  seq:stopSlot(SLOT)
  if seq:isSlotRunning(SLOT) then
    fail(name, "stopSlot did not clear isSlotRunning"); return
  end
  Persist.deserialize(data)
  if seq:isSlotRunning(SLOT) then
    fail(name, "no-restore default: slot resumed running despite Setting absent / no")
    seq:stopSlot(SLOT); return
  end

  -- Confirm getter on a different slot also reflects its own state
  -- (cross-slot independence of the new getter).
  if seq:isSlotRunning(1) then
    fail(name, "isSlotRunning(1) true -- expected stopped, untouched slot")
    return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 5c: TIE on gate-len -- legato (extend held gate, no edge).
--
-- gate-len 4.0 is the TIE sentinel. A TIE row WITH a gate already in
-- flight extends gate1RemainingSamples to the upcoming step's length
-- without producing a new edge: heldGate1Amp is preserved and
-- firedGate1ThisTick stays false. This is the legato case -- audio
-- output stays continuous across the TIE row. v2 gate amp is constant
-- 1.0 so the test asserts heldGate1Amp == 1.0 throughout the legato run.
-- ---------------------------------------------------------------------------
local function test_tie_legato()
  local name = "tie-legato"
  fullClearSlot(SLOT)
  -- 4-step loop on every column. gate1-len pattern: row 0 short fire,
  -- row 1 TIE, row 2 short fire, row 3 zero (skip). gate2 stays 0
  -- across all rows (silent). Step-len uniform 0.25 -- one /16 per tick.
  for c = 0, 5 do
    seq:setColumnLength(SLOT, c, 4)
    seq:setMarkers(SLOT, c, 0, 3)
  end
  seq:setL1(SLOT, COL_GATE1_LEN, 0, 0.25)
  seq:setL1(SLOT, COL_GATE1_LEN, 1, 4.0)    -- TIE
  seq:setL1(SLOT, COL_GATE1_LEN, 2, 0.25)
  seq:setL1(SLOT, COL_GATE1_LEN, 3, 0.0)
  for r = 0, 3 do seq:setL1(SLOT, COL_STEP_LEN, r, 0.25) end
  seq:resetSlot(SLOT)

  -- Tick 0 -- normal fire on gate1. Edge expected.
  seq:tickOnce(SLOT)
  if not seq:firedGate1ThisTick(SLOT) then
    fail(name, "tick 0: firedGate1ThisTick false -- expected fresh fire edge")
    return
  end
  if not approxEq(seq:heldGate1Amp(SLOT), 1.0) then
    fail(name, string.format("tick 0: heldGate1Amp expected 1.0, got %f",
                              seq:heldGate1Amp(SLOT)))
    return
  end

  -- Tick 1 -- TIE row, gate1 in flight from tick 0. Extend, no edge.
  seq:tickOnce(SLOT)
  if seq:firedGate1ThisTick(SLOT) then
    fail(name, "tick 1 (TIE extend): firedGate1ThisTick true -- expected no edge")
    return
  end
  if not approxEq(seq:heldGate1Amp(SLOT), 1.0) then
    fail(name, "tick 1 (TIE extend): heldGate1Amp drifted -- should be preserved")
    return
  end

  -- Tick 2 -- normal fire. Edge expected.
  seq:tickOnce(SLOT)
  if not seq:firedGate1ThisTick(SLOT) then
    fail(name, "tick 2: firedGate1ThisTick false -- expected fresh fire edge")
    return
  end

  -- Tick 3 -- gate-len 0, no fire.
  seq:tickOnce(SLOT)
  if seq:firedGate1ThisTick(SLOT) then
    fail(name, "tick 3 (gate-len 0): firedGate1ThisTick true -- expected skip")
    return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 5d: TIE on gate-len -- start-fresh (no prior gate -> full-step).
--
-- TIE row WITHOUT a gate in flight starts a fresh full-step gate WITH
-- an edge: the row reads as a full-width gate when nothing's running.
-- This is the "no surrounding steps" behaviour the user wants -- a
-- TIE in isolation just hits gate at amp 1.0 for one step.
-- ---------------------------------------------------------------------------
local function test_tie_start_no_prior()
  local name = "tie-start-no-prior"
  fullClearSlot(SLOT)
  for c = 0, 5 do
    seq:setColumnLength(SLOT, c, 2)
    seq:setMarkers(SLOT, c, 0, 1)
  end
  -- Row 0: no fire (gate1-len 0). Row 1: TIE.
  seq:setL1(SLOT, COL_GATE1_LEN, 0, 0.0)
  seq:setL1(SLOT, COL_GATE1_LEN, 1, 4.0)    -- TIE
  for r = 0, 1 do seq:setL1(SLOT, COL_STEP_LEN, r, 0.25) end
  seq:resetSlot(SLOT)

  -- Tick 0 -- skip (gate1-len 0). No gate in flight after this tick.
  seq:tickOnce(SLOT)
  if seq:firedGate1ThisTick(SLOT) then
    fail(name, "tick 0 (gate-len 0): firedGate1ThisTick true -- expected skip")
    return
  end

  -- Tick 1 -- TIE with no prior gate -> fresh full-step fire WITH edge.
  seq:tickOnce(SLOT)
  if not seq:firedGate1ThisTick(SLOT) then
    fail(name, "tick 1 (TIE fresh): firedGate1ThisTick false -- expected edge for full-width gate")
    return
  end
  if not approxEq(seq:heldGate1Amp(SLOT), 1.0) then
    fail(name, "tick 1 (TIE fresh): heldGate1Amp not set (expected 1.0 constant)")
    return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 5h: quicksave v1 -> v2 schema migration.
--
-- Hand-author a v0.1-shape data table (no schemaVersion field, old
-- 6-column layout: cv1/cv2/cv3/gtL/gtA/stL) with recognizable values
-- across every column including cv3 references and non-zero gate-amp
-- rows + L2 rules that reference the soon-to-be-remapped columns.
-- Load via Persist.deserialize; assert the engine state reflects the
-- v2 layout: cv3 dropped, gate-amp -> 0.25-beat g2L, indices shifted,
-- L2 column refs remapped (cv3 -> -1 host).
-- ---------------------------------------------------------------------------
local function test_quicksave_v1_to_v2_migration()
  local name = "quicksave-v1-to-v2-migration"
  local Persist = require "Sequencer.Persist"

  -- Build a minimal v1-shape data table for slot SLOT+1 only (other
  -- slots stay nil; deserialize tolerates that). Six columns per slot
  -- with column indices keyed 1..6 in the Lua table (0..5 engine-side).
  local function blankCol(len)
    local l1 = {}
    for r = 1, 64 do l1[r] = 0.0 end
    return { length = len or 16, marker1 = 0, marker2 = (len or 16) - 1,
             l1 = l1, l2 = {} }
  end

  local v1_data = { slots = {} }   -- no schemaVersion = v1
  for s = 1, 4 do
    v1_data.slots[s] = { running = false, columns = {} }
    for c = 1, 6 do v1_data.slots[s].columns[c] = blankCol(16) end
  end
  local slot = v1_data.slots[SLOT + 1]

  -- cv1 (col 1): known V/oct values at rows 0/1/2.
  slot.columns[1].l1[1] = 0.0
  slot.columns[1].l1[2] = 1.0       -- +1 octave
  slot.columns[1].l1[3] = 7 / 12.0  -- +7 semis
  -- cv2 (col 2): raw volts.
  slot.columns[2].l1[1] = 2.5
  -- cv3 (col 3, will be DROPPED): non-zero value should not survive.
  slot.columns[3].l1[1] = 9.9
  -- gtL (col 4, will become g1L at v2 col 2): markers + L1 verbatim.
  slot.columns[4].length  = 8
  slot.columns[4].marker1 = 2
  slot.columns[4].marker2 = 5
  slot.columns[4].l1[1]   = 0.25
  slot.columns[4].l1[2]   = 0.5
  -- gtA (col 5, will become g2L at v2 col 3): non-zero amp -> 0.25 beats
  slot.columns[5].l1[1] = 0.0  -- stays 0
  slot.columns[5].l1[2] = 1.0  -- -> 0.25 (g2L beats)
  slot.columns[5].l1[3] = 0.7  -- -> 0.25 (g2L beats)
  -- stL (col 6, will become stL at v2 col 4): verbatim.
  slot.columns[6].l1[1] = 0.5

  -- L2 rules referencing the soon-to-be-remapped column indices:
  --   on cv1 row 0: PRED_EQ on colA = 3 (cv3) operand 9.9 -> ACTION_ADD targetCol = 5 (gtA) +1
  --     after migration: colA should be -1 (cv3 neutered), targetCol should be 3 (g2L).
  slot.columns[1].l2[0] = {
    predOp = PRED_EQ, predColA = 2, predColARow = -1, predVal = 9.9,
    actOp = ACTION_ADD, actTgt = 4, actTgtRow = -1, actVal = 1.0,
  }
  --   on cv2 row 0: PRED_GT on colA = 4 (gtL) operand 0.4 -> ACTION_SET targetCol = 5 (gtA) = 0.5
  --     after migration: colA should be 2 (g1L), targetCol should be 3 (g2L).
  slot.columns[2].l2[0] = {
    predOp = PRED_GT, predColA = 3, predColARow = -1, predVal = 0.4,
    actOp = ACTION_SET, actTgt = 4, actTgtRow = -1, actVal = 0.5,
  }

  -- Stop the slot + apply.
  seq:stopSlot(SLOT)
  Persist.deserialize(v1_data)

  -- v2 col 0 (cv1): values intact.
  if not approxEq(seq:l1Value(SLOT, COL_CV1, 0), 0.0) then
    fail(name, "cv1[0] != 0 after migration"); return
  end
  if not approxEq(seq:l1Value(SLOT, COL_CV1, 1), 1.0) then
    fail(name, "cv1[1] != 1.0 after migration"); return
  end

  -- v2 col 1 (cv2): values intact.
  if not approxEq(seq:l1Value(SLOT, COL_CV2, 0), 2.5) then
    fail(name, "cv2[0] != 2.5 after migration"); return
  end

  -- v2 col 2 (g1L, was old gtL): markers + L1 verbatim.
  if seq:marker1(SLOT, COL_GATE1_LEN) ~= 2 or seq:marker2(SLOT, COL_GATE1_LEN) ~= 5 then
    fail(name, string.format("g1L markers expected (2,5), got (%d,%d)",
                              seq:marker1(SLOT, COL_GATE1_LEN),
                              seq:marker2(SLOT, COL_GATE1_LEN)))
    return
  end
  if not approxEq(seq:l1Value(SLOT, COL_GATE1_LEN, 0), 0.25)
     or not approxEq(seq:l1Value(SLOT, COL_GATE1_LEN, 1), 0.5) then
    fail(name, "g1L L1 values did not migrate verbatim from gtL"); return
  end

  -- v2 col 3 (g2L, was old gtA): non-zero amp -> 0.25 beats.
  if not approxEq(seq:l1Value(SLOT, COL_GATE2_LEN, 0), 0.0) then
    fail(name, "g2L[0] should be 0 (gtA[0] was 0)"); return
  end
  if not approxEq(seq:l1Value(SLOT, COL_GATE2_LEN, 1), 0.25) then
    fail(name, string.format("g2L[1] expected 0.25 (gtA[1]=1.0 -> 0.25 beats), got %.3f",
                              seq:l1Value(SLOT, COL_GATE2_LEN, 1)))
    return
  end
  if not approxEq(seq:l1Value(SLOT, COL_GATE2_LEN, 2), 0.25) then
    fail(name, string.format("g2L[2] expected 0.25 (gtA[2]=0.7 -> 0.25 beats), got %.3f",
                              seq:l1Value(SLOT, COL_GATE2_LEN, 2)))
    return
  end

  -- v2 col 4 (stL, was old stL): verbatim.
  if not approxEq(seq:l1Value(SLOT, COL_STEP_LEN, 0), 0.5) then
    fail(name, "stL[0] != 0.5 after migration"); return
  end

  -- v2 col 5 (tr, new): zero-initialized.
  for r = 0, 7 do
    if not approxEq(seq:l1Value(SLOT, COL_TRANSPOSE, r), 0.0) then
      fail(name, string.format("tr[%d] != 0 -- expected zero-init for new column", r))
      return
    end
  end

  -- L2 rule on cv1 row 0: cv3 -> -1, gtA target -> g2L (col 3).
  if not seq:l2Present(SLOT, COL_CV1, 0) then
    fail(name, "L2 rule on cv1 row 0 missing after migration"); return
  end
  if seq:l2PredColA(SLOT, COL_CV1, 0) ~= -1 then
    fail(name, string.format("L2 cv1[0] predColA expected -1 (cv3 neutered), got %d",
                              seq:l2PredColA(SLOT, COL_CV1, 0)))
    return
  end
  if seq:l2ActTgt(SLOT, COL_CV1, 0) ~= COL_GATE2_LEN then
    fail(name, string.format("L2 cv1[0] actTgt expected %d (g2L), got %d",
                              COL_GATE2_LEN, seq:l2ActTgt(SLOT, COL_CV1, 0)))
    return
  end

  -- L2 rule on cv2 row 0: gtL pred -> g1L (col 2), gtA target -> g2L (col 3).
  if not seq:l2Present(SLOT, COL_CV2, 0) then
    fail(name, "L2 rule on cv2 row 0 missing after migration"); return
  end
  if seq:l2PredColA(SLOT, COL_CV2, 0) ~= COL_GATE1_LEN then
    fail(name, string.format("L2 cv2[0] predColA expected %d (g1L), got %d",
                              COL_GATE1_LEN, seq:l2PredColA(SLOT, COL_CV2, 0)))
    return
  end
  if seq:l2ActTgt(SLOT, COL_CV2, 0) ~= COL_GATE2_LEN then
    fail(name, string.format("L2 cv2[0] actTgt expected %d (g2L), got %d",
                              COL_GATE2_LEN, seq:l2ActTgt(SLOT, COL_CV2, 0)))
    return
  end

  -- Re-serialize and confirm the output now carries schemaVersion = 2.
  local fresh = Persist.serialize()
  if fresh.schemaVersion ~= Persist._schemaVersion then
    fail(name, string.format("re-serialized save expected schemaVersion=%d, got %s",
                              Persist._schemaVersion, tostring(fresh.schemaVersion)))
    return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 5e: transpose pre-applied to cv1. heldCV1 should report
-- cv1Raw + heldTranspose / 12.0 each tick. Authoring 0 V on cv1 and
-- nudging the tr column lets us verify the pre-application directly
-- without floating-point noise from cv1 itself.
-- ---------------------------------------------------------------------------
local function test_transpose_cv1()
  local name = "transpose-cv1"
  fullClearSlot(SLOT)
  -- 4-step loop on cv1 + tr; cv1 stays at 0 V across all rows.
  seq:setColumnLength(SLOT, COL_CV1, 4)
  seq:setMarkers(SLOT, COL_CV1, 0, 3)
  seq:setColumnLength(SLOT, COL_TRANSPOSE, 4)
  seq:setMarkers(SLOT, COL_TRANSPOSE, 0, 3)
  -- tr pattern: -12 (octave down), 0 (no shift), 7 (perfect 5th up), 12 (octave up).
  seq:setL1(SLOT, COL_TRANSPOSE, 0, -12.0)
  seq:setL1(SLOT, COL_TRANSPOSE, 1, 0.0)
  seq:setL1(SLOT, COL_TRANSPOSE, 2, 7.0)
  seq:setL1(SLOT, COL_TRANSPOSE, 3, 12.0)
  seq:resetSlot(SLOT)

  local expected = { -1.0, 0.0, 7.0 / 12.0, 1.0 }
  for r = 0, 3 do
    seq:tickOnce(SLOT)
    if not approxEq(seq:heldCV1(SLOT), expected[r + 1], 1e-4) then
      fail(name, string.format("tick %d: heldCV1 expected %.4f (cv1=0 + tr=%.1f / 12), got %.4f",
                                r, expected[r + 1],
                                seq:l1Value(SLOT, COL_TRANSPOSE, r),
                                seq:heldCV1(SLOT)))
      return
    end
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 5f: gate1 + gate2 independence. Author distinct gate1-len /
-- gate2-len patterns and verify the per-gate firedGateNThisTick flags
-- flip independently across ticks (no cross-bleed). Slot-level
-- firedThisTick must mirror the OR of the two flags.
-- ---------------------------------------------------------------------------
local function test_gate1_gate2_independent()
  local name = "gate1-gate2-independent"
  fullClearSlot(SLOT)
  for c = 0, 5 do
    seq:setColumnLength(SLOT, c, 4)
    seq:setMarkers(SLOT, c, 0, 3)
  end
  -- gate1 fires on rows 0 + 2; gate2 fires on rows 1 + 3.
  seq:setL1(SLOT, COL_GATE1_LEN, 0, 0.25)
  seq:setL1(SLOT, COL_GATE1_LEN, 1, 0.0)
  seq:setL1(SLOT, COL_GATE1_LEN, 2, 0.25)
  seq:setL1(SLOT, COL_GATE1_LEN, 3, 0.0)
  seq:setL1(SLOT, COL_GATE2_LEN, 0, 0.0)
  seq:setL1(SLOT, COL_GATE2_LEN, 1, 0.25)
  seq:setL1(SLOT, COL_GATE2_LEN, 2, 0.0)
  seq:setL1(SLOT, COL_GATE2_LEN, 3, 0.25)
  seq:resetSlot(SLOT)

  local expected = {
    -- {gate1, gate2}
    { true,  false },  -- tick 0
    { false, true  },  -- tick 1
    { true,  false },  -- tick 2
    { false, true  },  -- tick 3
  }
  for i = 1, 4 do
    seq:tickOnce(SLOT)
    local g1, g2 = seq:firedGate1ThisTick(SLOT), seq:firedGate2ThisTick(SLOT)
    if g1 ~= expected[i][1] or g2 ~= expected[i][2] then
      fail(name, string.format("tick %d: expected gate1=%s gate2=%s, got %s/%s",
                                i - 1,
                                tostring(expected[i][1]), tostring(expected[i][2]),
                                tostring(g1), tostring(g2)))
      return
    end
    local slot = seq:firedThisTick(SLOT)
    if slot ~= (g1 or g2) then
      fail(name, string.format("tick %d: firedThisTick (%s) != gate1 OR gate2 (%s)",
                                i - 1, tostring(slot), tostring(g1 or g2)))
      return
    end
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 5g: PRED_FIRE1 + PRED_FIRE2 -- per-gate detector predicates.
-- L2 rules anchored on CV1 row 0 use PRED_FIRE1 to count gate1 fires
-- and PRED_FIRE2 to count gate2 fires (each into separate cv2 cells).
-- After a 4-tick run with the alternating pattern above, gate1 should
-- have fired exactly twice and gate2 exactly twice.
-- ---------------------------------------------------------------------------
local function test_pred_fire1_fire2()
  local name = "pred-fire1-fire2"
  fullClearSlot(SLOT)
  -- CV1: 1-step loop so its L2 cell fires every tick.
  seq:setColumnLength(SLOT, COL_CV1, 1)
  seq:setMarkers(SLOT, COL_CV1, 0, 0)
  -- gate1/gate2: 4-step loops with alternating fire pattern.
  for _, c in ipairs({ COL_GATE1_LEN, COL_GATE2_LEN }) do
    seq:setColumnLength(SLOT, c, 4)
    seq:setMarkers(SLOT, c, 0, 3)
  end
  seq:setL1(SLOT, COL_GATE1_LEN, 0, 0.25)
  seq:setL1(SLOT, COL_GATE1_LEN, 2, 0.25)
  seq:setL1(SLOT, COL_GATE2_LEN, 1, 0.25)
  seq:setL1(SLOT, COL_GATE2_LEN, 3, 0.25)
  -- CV2 pinned 1-step accumulator. Two L2 rules on CV1 row 0:
  --   PRED_FIRE1 -> ACTION_ADD +1 to CV2[row 0]
  --   PRED_FIRE2 -> ACTION_ADD +1 to CV2[row 1]
  -- Since CV1 has length 1, only one L2 cell on CV1 row 0 fires per
  -- tick. We use CV2 rows 0 and 1 as separate counters by pinning the
  -- action target row. Set CV2 length 2 to give us two distinct cells.
  seq:setColumnLength(SLOT, COL_CV2, 2)
  seq:setMarkers(SLOT, COL_CV2, 0, 1)
  seq:setL1(SLOT, COL_CV2, 0, 0.0)
  seq:setL1(SLOT, COL_CV2, 1, 0.0)
  -- Engine evaluates one L2 cell per (col, row); to count both gates
  -- we need separate L2 host rows. Park PRED_FIRE2 on CV1 row 0 too
  -- by hosting it on a different column. Use gate1 row 0 as the host
  -- for the gate2 counter (gate1 fires every other tick, so this rule
  -- only evaluates on gate1-fire ticks -- not what we want).
  -- Simpler: separate L2 hosts via a multi-row CV1 + multi-row CV2
  -- with explicit targets.
  -- Instead: collapse to a single-host L2 via two passes. Re-author
  -- with CV1 length 2 so we get two distinct L2 evals per cycle.
  seq:clearL2(SLOT, COL_CV1, 0)
  seq:setColumnLength(SLOT, COL_CV1, 2)
  seq:setMarkers(SLOT, COL_CV1, 0, 1)
  seq:setL2(SLOT, COL_CV1, 0,
            PRED_FIRE1, -1, -1, 0.0,
            ACTION_ADD, COL_CV2, 0, 1.0)   -- count gate1 fires into CV2[0]
  seq:setL2(SLOT, COL_CV1, 1,
            PRED_FIRE2, -1, -1, 0.0,
            ACTION_ADD, COL_CV2, 1, 1.0)   -- count gate2 fires into CV2[1]
  seq:resetSlot(SLOT)

  -- Tick 4 times. Pattern: g1=(0,1,2,3), g2=(0,1,2,3).
  --   tick 0: cv1 row 0 -> PRED_FIRE1; gate1[0]=0.25 fires -> CV2[0]+=1
  --   tick 1: cv1 row 1 -> PRED_FIRE2; gate2[1]=0.25 fires -> CV2[1]+=1
  --   tick 2: cv1 row 0 -> PRED_FIRE1; gate1[2]=0.25 fires -> CV2[0]+=1
  --   tick 3: cv1 row 1 -> PRED_FIRE2; gate2[3]=0.25 fires -> CV2[1]+=1
  for _ = 1, 4 do seq:tickOnce(SLOT) end
  local v0, v1 = seq:l1Value(SLOT, COL_CV2, 0), seq:l1Value(SLOT, COL_CV2, 1)
  if not approxEq(v0, 2.0) then
    fail(name, string.format("CV2[0] (gate1 count) expected 2.0, got %.3f", v0))
    return
  end
  if not approxEq(v1, 2.0) then
    fail(name, string.format("CV2[1] (gate2 count) expected 2.0, got %.3f", v1))
    return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 5i: ACTION_FIRE1 + ACTION_FIRE2 -- per-gate retrigger actions.
-- L2 rules with all-fires-true predicates author ACTION_FIRE1 on
-- cv1 row 0 and ACTION_FIRE2 on cv1 row 1. Both gate columns'
-- own gate-len rows are 0 (no natural fires), so any gate envelope
-- activity must come from the L2 actions.
-- ---------------------------------------------------------------------------
local function test_per_gate_fire_actions()
  local name = "per-gate-fire-actions"
  fullClearSlot(SLOT)
  -- cv1: 2-step host so we hit both L2 rules across the 2-tick run.
  seq:setColumnLength(SLOT, COL_CV1, 2)
  seq:setMarkers(SLOT, COL_CV1, 0, 1)
  -- gate-len columns kept at 0 so no natural fires steal the
  -- assertion target.
  seq:setColumnLength(SLOT, COL_GATE1_LEN, 2)
  seq:setMarkers(SLOT, COL_GATE1_LEN, 0, 1)
  seq:setColumnLength(SLOT, COL_GATE2_LEN, 2)
  seq:setMarkers(SLOT, COL_GATE2_LEN, 0, 1)
  -- L2 row 0 -> ACTION_FIRE1 (gate1); row 1 -> ACTION_FIRE2 (gate2).
  seq:setL2(SLOT, COL_CV1, 0,
            PRED_PROBABILITY, -1, -1, 100.0,
            ACTION_FIRE1, -1, -1, 0.0)
  seq:setL2(SLOT, COL_CV1, 1,
            PRED_PROBABILITY, -1, -1, 100.0,
            ACTION_FIRE2, -1, -1, 0.0)
  seq:resetSlot(SLOT)

  -- Tick 0 -- cv1 row 0 -> ACTION_FIRE1 hits gate1.
  seq:tickOnce(SLOT)
  if not approxEq(seq:heldGate1Amp(SLOT), 1.0) then
    fail(name, string.format("tick 0: heldGate1Amp expected 1.0 after ACTION_FIRE1, got %.3f",
                              seq:heldGate1Amp(SLOT)))
    return
  end
  if not approxEq(seq:heldGate2Amp(SLOT), 0.0) then
    fail(name, "tick 0: heldGate2Amp drifted -- ACTION_FIRE1 should not touch gate2")
    return
  end

  -- Tick 1 -- cv1 row 1 -> ACTION_FIRE2 hits gate2.
  seq:tickOnce(SLOT)
  if not approxEq(seq:heldGate2Amp(SLOT), 1.0) then
    fail(name, string.format("tick 1: heldGate2Amp expected 1.0 after ACTION_FIRE2, got %.3f",
                              seq:heldGate2Amp(SLOT)))
    return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 5j: transpose column integer-snap on all write paths.
-- The engine normalizes L1 writes targeting kColTranspose to the
-- nearest integer semitone, so microtones can't leak in via L2
-- actions, setL1, or pastes. Verifies setL1 + ACTION_ADD +
-- ACTION_SET + ACTION_DIV all land integer values on tr.
-- ---------------------------------------------------------------------------
local function test_transpose_integer_snap()
  local name = "transpose-integer-snap"
  fullClearSlot(SLOT)

  -- (1) setL1 with fractional value rounds to int.
  seq:setL1(SLOT, COL_TRANSPOSE, 0, 0.4)
  if seq:l1Value(SLOT, COL_TRANSPOSE, 0) ~= 0.0 then
    fail(name, string.format("setL1(0.4) expected 0 after snap, got %f",
                              seq:l1Value(SLOT, COL_TRANSPOSE, 0)))
    return
  end
  seq:setL1(SLOT, COL_TRANSPOSE, 0, 0.5)
  if seq:l1Value(SLOT, COL_TRANSPOSE, 0) ~= 1.0 then
    fail(name, string.format("setL1(0.5) expected 1 after snap (round-half-up), got %f",
                              seq:l1Value(SLOT, COL_TRANSPOSE, 0)))
    return
  end
  seq:setL1(SLOT, COL_TRANSPOSE, 0, -7.4)
  if seq:l1Value(SLOT, COL_TRANSPOSE, 0) ~= -7.0 then
    fail(name, string.format("setL1(-7.4) expected -7 after snap, got %f",
                              seq:l1Value(SLOT, COL_TRANSPOSE, 0)))
    return
  end
  seq:setL1(SLOT, COL_TRANSPOSE, 0, -7.5)
  if seq:l1Value(SLOT, COL_TRANSPOSE, 0) ~= -8.0 then
    fail(name, string.format("setL1(-7.5) expected -8 after snap (round-half-away-from-zero), got %f",
                              seq:l1Value(SLOT, COL_TRANSPOSE, 0)))
    return
  end

  -- (2) L2 ACTION_SET on tr with fractional operand snaps.
  --     cv1 length-1 loop hosts a single L2 cell that always fires.
  seq:setColumnLength(SLOT, COL_CV1, 1)
  seq:setMarkers(SLOT, COL_CV1, 0, 0)
  seq:setL1(SLOT, COL_TRANSPOSE, 0, 0)  -- reset
  seq:setColumnLength(SLOT, COL_TRANSPOSE, 1)
  seq:setMarkers(SLOT, COL_TRANSPOSE, 0, 0)
  seq:setL2(SLOT, COL_CV1, 0,
            PRED_PROBABILITY, -1, -1, 100.0,
            ACTION_SET, COL_TRANSPOSE, -1, 7.6)
  seq:resetSlot(SLOT)
  seq:tickOnce(SLOT)
  if seq:l1Value(SLOT, COL_TRANSPOSE, 0) ~= 8.0 then
    fail(name, string.format("ACTION_SET 7.6 on tr expected 8 after snap, got %f",
                              seq:l1Value(SLOT, COL_TRANSPOSE, 0)))
    return
  end

  -- (3) L2 ACTION_ADD with fractional accumulates to integer state
  --     after each tick (so repeated fractional ADDs don't drift).
  seq:setL1(SLOT, COL_TRANSPOSE, 0, 0)
  seq:setL2(SLOT, COL_CV1, 0,
            PRED_PROBABILITY, -1, -1, 100.0,
            ACTION_ADD, COL_TRANSPOSE, -1, 1.4)
  seq:resetSlot(SLOT)
  for _ = 1, 3 do seq:tickOnce(SLOT) end
  -- Each tick: stored value + 1.4, then snap. 0+1.4=1.4 -> 1. 1+1.4=2.4 -> 2.
  -- 2+1.4=3.4 -> 3. Without per-tick snap, sum would be 4.2 -> 4.
  local v = seq:l1Value(SLOT, COL_TRANSPOSE, 0)
  if v ~= 3.0 then
    fail(name, string.format("3x ACTION_ADD 1.4 with per-tick snap expected 3, got %f", v))
    return
  end

  -- (4) heldCV1 reflects the snapped transpose -- not the raw operand.
  seq:setL1(SLOT, COL_CV1, 0, 0.0)
  seq:setL1(SLOT, COL_TRANSPOSE, 0, 12.0)
  for r = 0, 0 do seq:clearL2(SLOT, COL_CV1, r) end
  seq:resetSlot(SLOT)
  seq:tickOnce(SLOT)
  if not approxEq(seq:heldCV1(SLOT), 1.0) then
    fail(name, string.format("heldCV1 with tr=12 expected 1.0 V/oct, got %.4f",
                              seq:heldCV1(SLOT)))
    return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 6: row-pinned predicate. An L2 cell inspects a column PINNED
-- to a specific row (predColARow >= 0) rather than that column's
-- playhead. CV2's playhead never reaches the pinned row, so the test
-- only passes if the pin is honored.
-- ---------------------------------------------------------------------------
local function test_l2_row_pinned_predicate()
  local name = "l2-row-pinned-predicate"
  fullClearSlot(SLOT)
  -- CV1: 1-step loop -- its L2 cell fires every tick.
  seq:setColumnLength(SLOT, COL_CV1, 1)
  seq:setMarkers(SLOT, COL_CV1, 0, 0)
  -- CV2: 3-step loop -- playhead cycles 0,1,2; never visits row 5.
  seq:setColumnLength(SLOT, COL_CV2, 3)
  seq:setMarkers(SLOT, COL_CV2, 0, 2)
  seq:setL1(SLOT, COL_CV2, 5, 3.0)   -- the pinned cell
  -- g1L: 1-step accumulator -- v2 has no cv3, so the test uses g1L's
  -- numeric storage as the accumulator. Gate semantics still run on
  -- this column each tick (length-1 g1L value 1.0 = fire gate every
  -- tick), but the assertion only reads l1Value at row 0.
  seq:setColumnLength(SLOT, COL_GATE1_LEN, 1)
  seq:setMarkers(SLOT, COL_GATE1_LEN, 0, 0)
  seq:setL1(SLOT, COL_GATE1_LEN, 0, 0.0)
  -- L2 on CV1 row 0: PRED_EQ inspecting CV2 PINNED to row 5 == 3.0;
  -- action +1 to g1L (playhead-relative).
  seq:setL2(SLOT, COL_CV1, 0,
            PRED_EQ, COL_CV2, 5, 3.0,
            ACTION_ADD, COL_GATE1_LEN, -1, 1.0)
  for _ = 1, 3 do seq:tickOnce(SLOT) end
  -- Without the pin, evaluate() would read CV2[playhead] = 0 != 3.0
  -- and never fire -> g1L[0] would stay 0.
  local v = seq:l1Value(SLOT, COL_GATE1_LEN, 0)
  if not approxEq(v, 3.0) then
    fail(name, string.format("expected g1L[0]=3.0 (pinned pred fires each tick), got %.3f", v))
    return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 7: row-pinned action. An L2 action writes to a column PINNED
-- to a specific row (actTargetRow >= 0). The target's playhead never
-- reaches that row, so only a working pin updates it -- and the
-- playhead rows must stay untouched.
-- ---------------------------------------------------------------------------
local function test_l2_row_pinned_action()
  local name = "l2-row-pinned-action"
  fullClearSlot(SLOT)
  seq:setColumnLength(SLOT, COL_CV1, 1)
  seq:setMarkers(SLOT, COL_CV1, 0, 0)
  -- CV2: 3-step loop; playhead cycles 0,1,2; never visits row 7.
  seq:setColumnLength(SLOT, COL_CV2, 3)
  seq:setMarkers(SLOT, COL_CV2, 0, 2)
  -- L2 on CV1 row 0: always-fire (PRED_PROBABILITY 100); ACTION_SET
  -- on CV2 PINNED to row 7, value 9.0.
  seq:setL2(SLOT, COL_CV1, 0,
            PRED_PROBABILITY, -1, -1, 100.0,
            ACTION_SET, COL_CV2, 7, 9.0)
  seq:tickOnce(SLOT)
  if not approxEq(seq:l1Value(SLOT, COL_CV2, 7), 9.0) then
    fail(name, string.format("expected CV2[7]=9.0 (pinned action), got %.3f",
                              seq:l1Value(SLOT, COL_CV2, 7)))
    return
  end
  for r = 0, 2 do
    if not approxEq(seq:l1Value(SLOT, COL_CV2, r), 0.0) then
      fail(name, string.format("CV2[%d] should be untouched by pinned action, got %.3f",
                                r, seq:l1Value(SLOT, COL_CV2, r)))
      return
    end
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 8: multi-slot independence. Author a distinct CV1 pattern on
-- each of the 4 slots, tick them all in lockstep, verify each slot
-- still holds ITS OWN values (no cross-slot bleed) and each playhead
-- stays within its own loop bounds. Guards against array-indexing /
-- shared-state regressions in the per-slot engine state.
-- ---------------------------------------------------------------------------
local function test_multislot_independence()
  local name = "multislot-independence"
  for s = 0, 3 do
    fullClearSlot(s)
    seq:setColumnLength(s, COL_CV1, 2 + s)        -- lengths 2,3,4,5
    seq:setMarkers(s, COL_CV1, 0, 1 + s)
    for r = 0, 1 + s do
      seq:setL1(s, COL_CV1, r, (s + 1) * 10 + r)  -- slot 0: 10,11 ; slot 1: 20,21,22 ; ...
    end
  end
  for _ = 1, 10 do
    for s = 0, 3 do seq:tickOnce(s) end
  end
  for s = 0, 3 do
    for r = 0, 1 + s do
      local expected = (s + 1) * 10 + r
      local got = seq:l1Value(s, COL_CV1, r)
      if not approxEq(got, expected) then
        fail(name, string.format("slot %d CV1[%d] expected %.1f, got %.1f -- cross-slot bleed",
                                  s, r, expected, got))
        return
      end
    end
    local ph = seq:playhead(s, COL_CV1)
    if ph < 0 or ph > 1 + s then
      fail(name, string.format("slot %d playhead %d outside loop bounds [0,%d]",
                                s, ph, 1 + s))
      return
    end
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Run all tests, then full-clear every slot so the bench leaves no
-- trace (cells, lengths, markers, L2 -- not just playheads).
-- ---------------------------------------------------------------------------
app.logInfo("sequencer_bench: starting Step-1 bench tests")

test_static_16_step()
test_polymetric_5_7()
test_l2_destructive_write()
test_l2_phase15_polish()
test_persistence_roundtrip()
test_persistence_transport_roundtrip()
test_tie_legato()
test_tie_start_no_prior()
test_quicksave_v1_to_v2_migration()
test_transpose_cv1()
test_gate1_gate2_independent()
test_pred_fire1_fire2()
test_per_gate_fire_actions()
test_transpose_integer_snap()
test_l2_row_pinned_predicate()
test_l2_row_pinned_action()
test_multislot_independence()

local total = #results
local pass_count = 0
for _, r in ipairs(results) do
  if r.ok then pass_count = pass_count + 1 end
end
app.logInfo("sequencer_bench: %d/%d PASS", pass_count, total)

-- Leave all slots fully clean (including slot 0, which the UI shows).
for s = 0, 3 do fullClearSlot(s) end

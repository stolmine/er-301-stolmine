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
-- All slot state is reset at the end so normal sequencer usage isn't
-- polluted by the bench. Until Step 1 is locked in, this script
-- self-runs on every boot.

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

local ACTION_ADD   = 1
local ACTION_SUB   = 2
local ACTION_SET   = 3

-- Column indices, mirroring od/sequencer/Sequencer.h
local COL_CV1      = 0
local COL_CV2      = 1
local COL_CV3      = 2
local COL_GATE_LEN = 3
local COL_GATE_AMP = 4
local COL_STEP_LEN = 5

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
  seq:resetSlot(0)
  seq:setColumnLength(0, COL_CV1, 16)
  seq:setMarkers(0, COL_CV1, 0, 15)
  for r = 0, 15 do
    seq:setL1(0, COL_CV1, r, r * 0.1)
  end

  -- Each tickOnce captures heldCV1 from the current playhead BEFORE
  -- advancing, then advances. Iteration i fires tick (i+1):
  --   iter 0 -> heldCV1 == row 0 value (0.0)
  --   iter 15 -> heldCV1 == row 15 value (1.5)
  for iter = 0, 15 do
    seq:tickOnce(0)
    local expected = iter * 0.1
    local got = seq:heldCV1(0)
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
-- independently. After LCM(5,7) = 35 ticks, both playheads back to 0.
-- ---------------------------------------------------------------------------
local function test_polymetric_5_7()
  local name = "polymetric-5-and-7"
  seq:resetSlot(0)
  -- Column 0: length 5
  seq:setColumnLength(0, COL_CV1, 5)
  seq:setMarkers(0, COL_CV1, 0, 4)
  for r = 0, 4 do seq:setL1(0, COL_CV1, r, r) end
  -- Column 1: length 7
  seq:setColumnLength(0, COL_CV2, 7)
  seq:setMarkers(0, COL_CV2, 0, 6)
  for r = 0, 6 do seq:setL1(0, COL_CV2, r, 100 + r) end

  for _ = 1, 35 do seq:tickOnce(0) end

  local ph0 = seq:playhead(0, COL_CV1)
  local ph1 = seq:playhead(0, COL_CV2)
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
  seq:resetSlot(0)
  seq:setColumnLength(0, COL_CV1, 2)
  seq:setMarkers(0, COL_CV1, 0, 1)
  seq:setColumnLength(0, COL_CV2, 2)
  seq:setMarkers(0, COL_CV2, 0, 1)
  seq:setL1(0, COL_CV2, 0, 5.0)

  -- L2 cell on col 0 row 0: predicate %2 (every 2 passes of host),
  -- action +1 to col 1 at col 1's current playhead.
  seq:setL2(0, COL_CV1, 0,
            PRED_MODULO, -1, 2,         -- predicate: %2 on host column
            ACTION_ADD,  COL_CV2, 1.0)  -- action: +1 to col 1

  for _ = 1, 5 do seq:tickOnce(0) end

  local v = seq:l1Value(0, COL_CV2, 0)
  if not approxEq(v, 6.0) then
    fail(name, string.format("col 1 row 0 expected 6.0 after 5 ticks, got %.3f", v))
    return
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

local total = #results
local pass_count = 0
for _, r in ipairs(results) do
  if r.ok then pass_count = pass_count + 1 end
end
app.logInfo("sequencer_bench: %d/%d PASS", pass_count, total)

-- Leave all slots clean
for s = 0, 3 do seq:resetSlot(s) end

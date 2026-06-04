-- SceneIndexArbiter isolation bench (v1.1 phase 5.3a).
--
-- Drives the new C++ arbiter directly without any chain / morpher
-- wiring, so the state machine, Schmitt threshold, manual-write
-- fast path, and bank-shrink clipping can be verified before any
-- audio path consumes the output.
--
-- Without an audio thread connection, mInput.buffer() returns the
-- ZeroOutput buffer (all zeros). The bench inserts a wrapper that
-- writes a synthetic CV value into the arbiter via the existing
-- "fake an audio-frame call" idiom: call arbiter:process() directly
-- after using a side-channel to push the CV value.
--
-- The arbiter's mInput is an Inlet that reads its buffer; we don't
-- have a way to inject samples into it from Lua. So this bench
-- doesn't exercise the CV path. Instead it exercises the
-- Lua-facing surface that has no Inlet dependency:
--   - mGain / mBias hardSet via Parameter API
--   - setSceneCount() clip
--   - hardSetBias() manual write
--   - getState / getCurrentIndex inspection
--   - consumeTransitionFlag latching
-- which is sufficient to prove the arbiter compiled + SWIG-bound
-- correctly and behaves consistently for manual-side operations.
-- The CV-driven path is bench-validated end-to-end once the
-- morpher hookup lands in 5.3b.

if not app.SceneIndexArbiter then
  app.logError("scene_arbiter_bench: app.SceneIndexArbiter not bound; aborting.")
  return
end

local results = {}
local function pass(name)
  results[#results + 1] = { name = name, ok = true }
  app.logInfo("scene_arbiter_bench: %s ... PASS", name)
end
local function fail(name, msg)
  results[#results + 1] = { name = name, ok = false, msg = msg }
  app.logError("scene_arbiter_bench: %s ... FAIL: %s",
               name, msg or "(no detail)")
end

local function test_construct_and_defaults()
  local name = "construct-and-defaults"
  local arb = app.SceneIndexArbiter()
  arb:setName("bench.arbiter")

  if arb:getSceneCount() ~= 0 then
    return fail(name, "fresh sceneCount expected 0, got " .. arb:getSceneCount())
  end
  if arb:getState() ~= 0 then
    return fail(name, "fresh state expected 0 (Tracking-Manual), got " .. arb:getState())
  end
  if arb:getCurrentIndex() ~= 0 then
    return fail(name, "fresh currentIndex expected 0, got " .. arb:getCurrentIndex())
  end
  if arb:getParameter("Gain"):target() ~= 1.0 then
    return fail(name, "default Gain expected 1.0")
  end
  if arb:getParameter("Bias"):target() ~= 0.0 then
    return fail(name, "default Bias expected 0.0")
  end
  pass(name)
end

local function test_setSceneCount_clip()
  local name = "setSceneCount-clip"
  local arb = app.SceneIndexArbiter()
  arb:setName("bench.arbiter")
  arb:setSceneCount(16)
  arb:getParameter("Bias"):hardSet(8.0)
  -- shrink the bank; bias should clip down
  arb:setSceneCount(4)
  if arb:getParameter("Bias"):target() ~= 4.0 then
    return fail(name, string.format(
      "bias expected clipped to 4.0, got %f", arb:getParameter("Bias"):target()))
  end
  if arb:getSceneCount() ~= 4 then
    return fail(name, "sceneCount expected 4, got " .. arb:getSceneCount())
  end
  pass(name)
end

local function test_hardSetBias_clip_and_state()
  local name = "hardSetBias-clip-and-state"
  local arb = app.SceneIndexArbiter()
  arb:setName("bench.arbiter")
  arb:setSceneCount(8)

  -- Negative biases clip to 0.
  arb:hardSetBias(-3.0)
  if arb:getParameter("Bias"):target() ~= 0.0 then
    return fail(name, "negative bias should clip to 0")
  end
  -- Over-bank biases clip to sceneCount.
  arb:hardSetBias(99.0)
  if arb:getParameter("Bias"):target() ~= 8.0 then
    return fail(name, "over-bank bias should clip to sceneCount")
  end
  -- State should be Tracking-Manual after any hardSetBias.
  if arb:getState() ~= 0 then
    return fail(name, "hardSetBias should force Tracking-Manual")
  end
  pass(name)
end

local function test_transition_flag_latches_on_hardSetBias()
  local name = "transition-flag-latches-on-hardSetBias"
  local arb = app.SceneIndexArbiter()
  arb:setName("bench.arbiter")
  arb:setSceneCount(8)

  -- Drain any pending flag from construction-time clips.
  arb:consumeTransitionFlag()
  -- Bias was at 0; hard-set to 3 should change the rounded output
  -- index and latch the flag.
  arb:hardSetBias(3.0)
  if not arb:consumeTransitionFlag() then
    return fail(name, "transition flag should latch after index change")
  end
  -- Second consume should return false (auto-cleared).
  if arb:consumeTransitionFlag() then
    return fail(name, "transition flag should auto-clear after consume")
  end
  -- Same bias again: no new transition.
  arb:hardSetBias(3.0)
  if arb:consumeTransitionFlag() then
    return fail(name, "same bias write should not re-latch the flag")
  end
  pass(name)
end

local function test_currentIndex_tracks_bias_in_manual()
  local name = "currentIndex-tracks-bias-in-manual"
  local arb = app.SceneIndexArbiter()
  arb:setName("bench.arbiter")
  arb:setSceneCount(16)

  arb:hardSetBias(5.0)
  if arb:getCurrentIndex() ~= 5 then
    return fail(name, "currentIndex expected 5, got " .. arb:getCurrentIndex())
  end
  -- Fractional bias rounds to nearest integer.
  arb:hardSetBias(7.4)
  if arb:getCurrentIndex() ~= 7 then
    return fail(name, "bias 7.4 should round to 7")
  end
  arb:hardSetBias(7.6)
  if arb:getCurrentIndex() ~= 8 then
    return fail(name, "bias 7.6 should round to 8")
  end
  pass(name)
end

local function test_setSceneCount_clip_currentIndex()
  local name = "setSceneCount-clip-currentIndex"
  local arb = app.SceneIndexArbiter()
  arb:setName("bench.arbiter")
  arb:setSceneCount(16)
  arb:hardSetBias(12.0)
  if arb:getCurrentIndex() ~= 12 then
    return fail(name, "pre-shrink index expected 12")
  end
  arb:setSceneCount(8)
  -- Bias has clipped to 8; currentIndex tracks via the same
  -- clamp (last-fired-index reset path).
  if arb:getCurrentIndex() > 8 then
    return fail(name, "currentIndex should clip to new sceneCount")
  end
  pass(name)
end

app.logInfo("scene_arbiter_bench: starting v1.1 phase 5.3a arbiter tests")
test_construct_and_defaults()
test_setSceneCount_clip()
test_hardSetBias_clip_and_state()
test_transition_flag_latches_on_hardSetBias()
test_currentIndex_tracks_bias_in_manual()
test_setSceneCount_clip_currentIndex()

local total = #results
local pass_count = 0
for _, r in ipairs(results) do if r.ok then pass_count = pass_count + 1 end end
app.logInfo("scene_arbiter_bench: %d/%d PASS", pass_count, total)

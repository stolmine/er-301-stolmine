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
  -- kIndex: cold-start Gain = 0 (CV inert until user enables it).
  if arb:getParameter("Gain"):target() ~= 0.0 then
    return fail(name, "default Gain expected 0.0, got " ..
                 tostring(arb:getParameter("Gain"):target()))
  end
  if arb:getParameter("Bias"):target() ~= 0.0 then
    return fail(name, "default Bias expected 0.0")
  end
  pass(name)
end

local function test_setSceneCount_preserves_normalized_bias()
  local name = "setSceneCount-preserves-bias"
  local arb = app.SceneIndexArbiter()
  arb:setName("bench.arbiter")
  arb:setSceneCount(16)
  arb:hardSetBias(0.5)  -- normalized midpoint
  if math.abs(arb:getParameter("Bias"):target() - 0.5) > 1e-6 then
    return fail(name, "bias should accept normalized midpoint")
  end
  -- kIndex: bank shrink does NOT shrink Bias. The normalized
  -- position is the user's intent and stays put; the audible
  -- output rescales via the new N.
  arb:setSceneCount(4)
  if math.abs(arb:getParameter("Bias"):target() - 0.5) > 1e-6 then
    return fail(name, "bias should stay at 0.5 after sceneCount change")
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
  arb:hardSetBias(-0.5)
  if arb:getParameter("Bias"):target() ~= 0.0 then
    return fail(name, "negative bias should clip to 0")
  end
  -- Over-1 biases clip to 1 (normalized).
  arb:hardSetBias(2.5)
  if arb:getParameter("Bias"):target() ~= 1.0 then
    return fail(name, "over-1 bias should clip to 1.0")
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

  arb:consumeTransitionFlag()
  -- Bias 0.0 -> 0.5 with N=8 -> output 0 -> 4. Index changes.
  arb:hardSetBias(0.5)
  if not arb:consumeTransitionFlag() then
    return fail(name, "transition flag should latch after index change")
  end
  if arb:consumeTransitionFlag() then
    return fail(name, "transition flag should auto-clear after consume")
  end
  -- Same bias again: no new transition.
  arb:hardSetBias(0.5)
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

  -- bias 0.5 with N=16 -> round(8.0) = 8
  arb:hardSetBias(0.5)
  if arb:getCurrentIndex() ~= 8 then
    return fail(name, "bias 0.5 * 16 expected 8, got " .. arb:getCurrentIndex())
  end
  -- bias 7/16 -> round(7.0) = 7
  arb:hardSetBias(7 / 16)
  if arb:getCurrentIndex() ~= 7 then
    return fail(name, "bias 7/16 expected currentIndex 7")
  end
  -- bias 0.97 -> round(15.52) = 16, clipped to 16 (sceneCount)
  arb:hardSetBias(0.97)
  if arb:getCurrentIndex() ~= 16 then
    return fail(name, "bias 0.97 * 16 expected currentIndex 16")
  end
  -- bias 1.0 -> round(16) = 16
  arb:hardSetBias(1.0)
  if arb:getCurrentIndex() ~= 16 then
    return fail(name, "bias 1.0 expected currentIndex 16")
  end
  pass(name)
end

local function test_sceneCount_change_rescales_output()
  -- kIndex: bias stays normalized across bank changes, but the
  -- output index rescales since it's round(bias * N).
  local name = "sceneCount-change-rescales-output"
  local arb = app.SceneIndexArbiter()
  arb:setName("bench.arbiter")
  arb:setSceneCount(16)
  arb:hardSetBias(0.5)
  if arb:getCurrentIndex() ~= 8 then
    return fail(name, "16-scene bank at 0.5 expected index 8")
  end
  arb:setSceneCount(8)
  if arb:getCurrentIndex() ~= 4 then
    return fail(name, "8-scene bank at 0.5 expected index 4, got " ..
                 arb:getCurrentIndex())
  end
  arb:setSceneCount(2)
  if arb:getCurrentIndex() ~= 1 then
    return fail(name, "2-scene bank at 0.5 expected index 1")
  end
  pass(name)
end

app.logInfo("scene_arbiter_bench: starting v1.1 phase 5.3a arbiter tests")
test_construct_and_defaults()
test_setSceneCount_preserves_normalized_bias()
test_hardSetBias_clip_and_state()
test_transition_flag_latches_on_hardSetBias()
test_currentIndex_tracks_bias_in_manual()
test_sceneCount_change_rescales_output()

local total = #results
local pass_count = 0
for _, r in ipairs(results) do if r.ok then pass_count = pass_count + 1 end end
app.logInfo("scene_arbiter_bench: %d/%d PASS", pass_count, total)

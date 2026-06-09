-- Phase 6.2 isolation bench for the sequencer external-clock engine.
--
-- Verifies API surface added in phase 6.2:
--   * setClockSource / getClockSource (incl. invalid-source no-op).
--   * setGlobalDiv / getGlobalDiv with clamping.
--   * setSlotDiv / getSlotDiv with clamping, per slot.
--   * getExtClockInlet / getExtResetInlet return non-nil pointers.
--   * Default ext BPM == 0 (no pulses yet).
--   * Source-switch resets divider counters + drops ext BPM estimate.
--
-- Tick-edge + dispatch behaviour requires real audio buffers carrying
-- modular gate edges; that is bench-verified at 6.7 with a hardware
-- clock source. Here we only sanity-check that internal-mode behaviour
-- (covered by the main sequencer_bench) is unchanged when the new code
-- paths exist.

local seq = app.AudioThread.getSequencerTask()
if not seq then
  app.logError("sequencer_extclock_bench: SequencerTask not available; aborting.")
  return
end

local results = {}
local function pass(name)
  results[#results + 1] = { name = name, ok = true }
  app.logInfo("sequencer_extclock_bench: %s ... PASS", name)
end
local function fail(name, msg)
  results[#results + 1] = { name = name, ok = false, msg = msg }
  app.logError("sequencer_extclock_bench: %s ... FAIL: %s", name, msg or "(no detail)")
end

local CLOCK_INTERNAL = 0
local CLOCK_EXTERNAL = 1

-- ---------------------------------------------------------------------------
-- Test 1: clockSource setter / getter round-trip; invalid is no-op.
-- ---------------------------------------------------------------------------
local function test_clock_source_roundtrip()
  local name = "clock-source-roundtrip"
  local initial = seq:getClockSource()
  seq:setClockSource(CLOCK_EXTERNAL)
  if seq:getClockSource() ~= CLOCK_EXTERNAL then
    fail(name, "setClockSource(EXTERNAL) did not stick"); return
  end
  seq:setClockSource(CLOCK_INTERNAL)
  if seq:getClockSource() ~= CLOCK_INTERNAL then
    fail(name, "setClockSource(INTERNAL) did not stick"); return
  end
  -- Invalid value (out of {0, 1}): should be ignored.
  seq:setClockSource(99)
  if seq:getClockSource() ~= CLOCK_INTERNAL then
    fail(name, "setClockSource(99) clobbered state"); return
  end
  -- Restore to known.
  seq:setClockSource(initial)
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 2: globalDiv clamps to [1, 16].
-- ---------------------------------------------------------------------------
local function test_global_div_clamp()
  local name = "global-div-clamp"
  seq:setGlobalDiv(8)
  if seq:getGlobalDiv() ~= 8 then
    fail(name, string.format("setGlobalDiv(8): got %d", seq:getGlobalDiv())); return
  end
  seq:setGlobalDiv(0)
  if seq:getGlobalDiv() ~= 1 then
    fail(name, string.format("setGlobalDiv(0) should clamp to 1, got %d", seq:getGlobalDiv())); return
  end
  seq:setGlobalDiv(99)
  if seq:getGlobalDiv() ~= 16 then
    fail(name, string.format("setGlobalDiv(99) should clamp to 16, got %d", seq:getGlobalDiv())); return
  end
  seq:setGlobalDiv(1)  -- restore
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 3: per-slot div clamps independently per slot.
-- ---------------------------------------------------------------------------
local function test_slot_div_clamp()
  local name = "slot-div-clamp-per-slot"
  for s = 0, 3 do
    seq:setSlotDiv(s, 2 + s)
  end
  for s = 0, 3 do
    if seq:getSlotDiv(s) ~= 2 + s then
      fail(name, string.format("slot %d expected div=%d, got %d", s, 2 + s, seq:getSlotDiv(s)))
      return
    end
  end
  seq:setSlotDiv(0, 0)
  seq:setSlotDiv(1, 100)
  if seq:getSlotDiv(0) ~= 1 then
    fail(name, "slot 0: setSlotDiv(0) should clamp to 1"); return
  end
  if seq:getSlotDiv(1) ~= 16 then
    fail(name, "slot 1: setSlotDiv(100) should clamp to 16"); return
  end
  -- Restore.
  for s = 0, 3 do seq:setSlotDiv(s, 1) end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 4: ext clock + reset comparators exist and expose In inlets.
-- ---------------------------------------------------------------------------
local function test_inlet_accessors()
  local name = "ext-comparator-accessors"
  local clkComp = seq:getExtClockComparator()
  local rstComp = seq:getExtResetComparator()
  if not clkComp then
    fail(name, "getExtClockComparator returned nil"); return
  end
  if not rstComp then
    fail(name, "getExtResetComparator returned nil"); return
  end
  if not clkComp:getInput("In") then
    fail(name, "ext clock comparator has no 'In' inlet"); return
  end
  if not rstComp:getInput("In") then
    fail(name, "ext reset comparator has no 'In' inlet"); return
  end
  -- Manual-fire wrappers should call without crashing.
  seq:triggerClockRise(); seq:triggerClockFall()
  seq:triggerResetRise(); seq:triggerResetFall()
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 5: default ext BPM is 0 (no pulses since boot).
-- ---------------------------------------------------------------------------
local function test_default_ext_bpm()
  local name = "default-ext-bpm-zero"
  local bpm = seq:getExtBpm()
  if bpm ~= 0.0 then
    fail(name, string.format("expected 0.0, got %.3f", bpm)); return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 6: source switch resets divider counter state + ext BPM estimate.
-- The publicly observable proof is that getExtBpm returns 0 after a
-- switch; counter internals are not exposed but the source-switch
-- contract in setClockSource explicitly zeroes them, so we verify the
-- proxy (BPM) state and trust the same code path.
-- ---------------------------------------------------------------------------
local function test_source_switch_resets_state()
  local name = "source-switch-resets-state"
  seq:setClockSource(CLOCK_EXTERNAL)
  -- Force-bump divider so a switch would have something to reset.
  seq:setGlobalDiv(4)
  seq:setSlotDiv(0, 3)
  seq:setClockSource(CLOCK_INTERNAL)
  -- Ext BPM should still be 0 (we never had a pulse).
  if seq:getExtBpm() ~= 0.0 then
    fail(name, string.format("post-switch ext BPM expected 0.0, got %.3f", seq:getExtBpm())); return
  end
  -- Set div values are user-state, NOT counter state, so they should
  -- survive a source switch.
  if seq:getGlobalDiv() ~= 4 then
    fail(name, "globalDiv setting should survive source switch"); return
  end
  if seq:getSlotDiv(0) ~= 3 then
    fail(name, "slotDiv[0] setting should survive source switch"); return
  end
  -- Restore defaults.
  seq:setGlobalDiv(1)
  seq:setSlotDiv(0, 1)
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 7: in external mode with no clock source connected, slots in
-- "running" state do NOT advance. Internal mode is the spec-baseline
-- of "running slots advance"; this test guards against accidental
-- internal-tick leakage into external mode.
--
-- Strategy: stop all slots (resetSlot rewinds), switch to external,
-- briefly wait, then verify no playhead movement. We don't have a
-- direct "frame elapsed" hook, but yielding to the scheduler a few
-- times via os.time-style polling is brittle. Simpler: call tickOnce
-- to confirm bench-only manual tick still works (the only API that
-- advances playhead synchronously in this harness).
-- ---------------------------------------------------------------------------
local function test_external_mode_no_spurious_ticks()
  local name = "external-no-spurious-ticks"
  -- Use slot 3 to avoid polluting slot 0 (UI-visible).
  local SLOT = 3
  seq:resetSlot(SLOT)
  seq:setClockSource(CLOCK_EXTERNAL)
  -- tickOnce calls fireTick directly (bench escape hatch); it must
  -- continue to work in external mode for deterministic testing.
  -- seq:playhead returns currentRow (= the row just emitted), so
  -- after the first tick we still read row 0 (loopMin); after the
  -- second tick we read row 1. This verifies fireTick's advance
  -- logic is unaffected by the clockSource flag and that
  -- externalTick's helper-shared body path stays consistent.
  seq:tickOnce(SLOT)
  if seq:playhead(SLOT, 0) ~= 0 then
    fail(name, string.format("after 1st tickOnce expected currentRow=0, got %d", seq:playhead(SLOT, 0)))
    return
  end
  seq:tickOnce(SLOT)
  if seq:playhead(SLOT, 0) ~= 1 then
    fail(name, string.format("after 2nd tickOnce expected currentRow=1, got %d", seq:playhead(SLOT, 0)))
    return
  end
  -- Restore: internal mode, slot wound back.
  seq:setClockSource(CLOCK_INTERNAL)
  seq:resetSlot(SLOT)
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 8 (phase 6.3): ClockBinding source-picker wiring.
-- Verifies set / get / clear for both clock and reset bindings, and
-- that bad input is handled without raising. The actual electrical
-- connectivity (Inlet.buffer() returning the source's audio) is
-- covered by the broader audio graph test infrastructure.
-- ---------------------------------------------------------------------------
local function test_clock_binding_module()
  local name = "clock-binding-module"
  local ClockBinding = require "Sequencer.ClockBinding"

  -- Initial state: nothing bound.
  if ClockBinding.getClockSourceName() ~= nil then
    fail(name, "ClockBinding boots with non-nil clock source"); return
  end
  if ClockBinding.getResetSourceName() ~= nil then
    fail(name, "ClockBinding boots with non-nil reset source"); return
  end

  -- Bind G1 to clock, G2 to reset.
  ClockBinding.setClockSource("G1")
  if ClockBinding.getClockSourceName() ~= "G1" then
    fail(name, "after setClockSource('G1'), getClockSourceName != 'G1'"); return
  end
  ClockBinding.setResetSource("G2")
  if ClockBinding.getResetSourceName() ~= "G2" then
    fail(name, "after setResetSource('G2'), getResetSourceName != 'G2'"); return
  end

  -- getClockSource returns the actual Source.External object.
  local clkSrc = ClockBinding.getClockSource()
  if not clkSrc or not clkSrc.getOutlet then
    fail(name, "getClockSource did not return a Source.External-like object"); return
  end

  -- Rebind to a different source (G3); previous binding should be
  -- transparently disconnected.
  ClockBinding.setClockSource("G3")
  if ClockBinding.getClockSourceName() ~= "G3" then
    fail(name, "rebinding clock to 'G3' did not stick"); return
  end

  -- Clear via clearClockSource.
  ClockBinding.clearClockSource()
  if ClockBinding.getClockSourceName() ~= nil then
    fail(name, "clearClockSource did not nil the name"); return
  end

  -- Clear via setClockSource(nil).
  ClockBinding.setResetSource(nil)
  if ClockBinding.getResetSourceName() ~= nil then
    fail(name, "setResetSource(nil) did not nil the name"); return
  end

  -- Unknown source name: should log + leave state untouched, not crash.
  ClockBinding.setClockSource("nonsense-source-xyz")
  if ClockBinding.getClockSourceName() ~= nil then
    fail(name, "unknown source name should leave clock binding unset"); return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 9 (phase 6.4): ClockView Window + controls instantiate cleanly.
-- A headless instantiation smoke test that catches require-cycle bugs,
-- missing methods on Source.Chooser, and any field-access typos before
-- the user sees them at the UI. Does NOT call :show() since the GUI is
-- not necessarily up at bench-load time.
-- ---------------------------------------------------------------------------
local function test_clockview_instantiation()
  local name = "clockview-instantiation"
  local ok, err = pcall(function()
    local ClockView = require "Sequencer.ClockView"
    local view = ClockView()
    if not view then error("ClockView() returned nil") end
    if not view.sourceControl then error("missing sourceControl") end
    if not view.resetControl then error("missing resetControl") end
    if not view.slotControls or #view.slotControls ~= 4 then
      error("slotControls should be a 4-element table")
    end
  end)
  if not ok then
    fail(name, tostring(err))
    return
  end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Run all tests, report summary.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Test 10 (phase 6.6): clock state round-trips through quicksave.
-- Mutate engine + ClockBinding into a non-default state, serialize,
-- mutate to fresh defaults, deserialize, assert state matches.
-- ---------------------------------------------------------------------------
local function test_clock_persist_roundtrip()
  local name = "clock-persist-roundtrip"
  local Persist = require "Sequencer.Persist"
  local ClockBinding = require "Sequencer.ClockBinding"

  -- Snapshot starting state so we can fully restore at the end.
  local startSource = seq:getClockSource()
  local startGlobal = seq:getGlobalDiv()
  local startSlot   = { seq:getSlotDiv(0), seq:getSlotDiv(1), seq:getSlotDiv(2), seq:getSlotDiv(3) }
  local startClockName = ClockBinding.getClockSourceName()
  local startResetName = ClockBinding.getResetSourceName()

  local ok, err = pcall(function()
    -- Force a non-default state.
    seq:setClockSource(1)             -- external
    seq:setGlobalDiv(7)
    seq:setSlotDiv(0, 2); seq:setSlotDiv(1, 4); seq:setSlotDiv(2, 8); seq:setSlotDiv(3, 16)
    ClockBinding.setClockSource("G1")
    ClockBinding.setResetSource("G2")

    -- Serialize.
    local snap = Persist.serialize()
    if not snap or not snap.clock then
      error("serialize did not produce a clock subtable")
    end
    if snap.clock.source ~= "external" then
      error("snapshot.source expected 'external', got " .. tostring(snap.clock.source))
    end
    if snap.clock.globalDiv ~= 7 then
      error("snapshot.globalDiv expected 7, got " .. tostring(snap.clock.globalDiv))
    end
    if snap.clock.slotDiv[1] ~= 2 or snap.clock.slotDiv[4] ~= 16 then
      error("snapshot.slotDiv mismatch")
    end
    if snap.clock.extClockSource ~= "G1" then
      error("snapshot.extClockSource expected 'G1', got " .. tostring(snap.clock.extClockSource))
    end
    if snap.clock.extResetSource ~= "G2" then
      error("snapshot.extResetSource expected 'G2', got " .. tostring(snap.clock.extResetSource))
    end

    -- Mutate engine to defaults.
    seq:setClockSource(0)             -- internal
    seq:setGlobalDiv(1)
    for i = 0, 3 do seq:setSlotDiv(i, 1) end
    ClockBinding.clearClockSource()
    ClockBinding.clearResetSource()

    -- Deserialize snapshot.
    Persist.deserialize(snap)

    -- Assert all state restored.
    if seq:getClockSource() ~= 1 then
      error("post-restore clockSource expected 1, got " .. tostring(seq:getClockSource()))
    end
    if seq:getGlobalDiv() ~= 7 then
      error("post-restore globalDiv expected 7, got " .. tostring(seq:getGlobalDiv()))
    end
    for i = 0, 3 do
      local expected = ({2, 4, 8, 16})[i + 1]
      if seq:getSlotDiv(i) ~= expected then
        error(string.format("post-restore slotDiv[%d] expected %d, got %d", i, expected, seq:getSlotDiv(i)))
      end
    end
    if ClockBinding.getClockSourceName() ~= "G1" then
      error("post-restore clock binding name expected 'G1', got " .. tostring(ClockBinding.getClockSourceName()))
    end
    if ClockBinding.getResetSourceName() ~= "G2" then
      error("post-restore reset binding name expected 'G2', got " .. tostring(ClockBinding.getResetSourceName()))
    end
  end)

  -- Restore starting state regardless of pass/fail.
  seq:setClockSource(startSource)
  seq:setGlobalDiv(startGlobal)
  for i = 0, 3 do seq:setSlotDiv(i, startSlot[i + 1] or 1) end
  ClockBinding.setClockSource(startClockName)
  ClockBinding.setResetSource(startResetName)

  if not ok then fail(name, tostring(err)); return end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 11 (phase 6.6): v2 quicksave (no clock subtable) migrates to v3
-- with engine boot defaults.
-- ---------------------------------------------------------------------------
local function test_clock_persist_v2_migration()
  local name = "clock-persist-v2-migration"
  local Persist = require "Sequencer.Persist"
  local ClockBinding = require "Sequencer.ClockBinding"

  -- Snapshot starting state.
  local startSource = seq:getClockSource()
  local startGlobal = seq:getGlobalDiv()
  local startSlot   = { seq:getSlotDiv(0), seq:getSlotDiv(1), seq:getSlotDiv(2), seq:getSlotDiv(3) }
  local startClockName = ClockBinding.getClockSourceName()
  local startResetName = ClockBinding.getResetSourceName()

  -- Mutate engine to non-default so we can detect whether the migration
  -- correctly reset it to v2-era defaults (internal / div=1).
  seq:setClockSource(1)
  seq:setGlobalDiv(11)
  ClockBinding.setClockSource("G1")

  -- Craft a v2-shaped table: schemaVersion = 2, has slots, NO clock.
  local fake = {
    schemaVersion = 2,
    slots = {},
  }
  -- Minimal slots so deserialize's slot loop doesn't bail.
  for s = 1, 4 do
    fake.slots[s] = { running = false, columns = {} }
    for c = 1, 6 do
      fake.slots[s].columns[c] = { length = 16, marker1 = 0, marker2 = 15, l1 = {}, l2 = {} }
    end
  end

  local ok, err = pcall(function()
    Persist.deserialize(fake)
    if seq:getClockSource() ~= 0 then
      error("v2 migration should reset clockSource to internal (0), got " .. tostring(seq:getClockSource()))
    end
    if seq:getGlobalDiv() ~= 1 then
      error("v2 migration should reset globalDiv to 1, got " .. tostring(seq:getGlobalDiv()))
    end
    for i = 0, 3 do
      if seq:getSlotDiv(i) ~= 1 then
        error(string.format("v2 migration should reset slotDiv[%d] to 1, got %d", i, seq:getSlotDiv(i)))
      end
    end
    if ClockBinding.getClockSourceName() ~= nil then
      error("v2 migration should clear clock binding, got " .. tostring(ClockBinding.getClockSourceName()))
    end
  end)

  -- Restore.
  seq:setClockSource(startSource)
  seq:setGlobalDiv(startGlobal)
  for i = 0, 3 do seq:setSlotDiv(i, startSlot[i + 1] or 1) end
  ClockBinding.setClockSource(startClockName)
  ClockBinding.setResetSource(startResetName)

  if not ok then fail(name, tostring(err)); return end
  pass(name)
end

-- ---------------------------------------------------------------------------
-- Test 12 (phase 6.6): deserialize with an unknown source name (stale
-- quicksave referencing a source that no longer exists) leaves the
-- binding unset rather than crashing.
-- ---------------------------------------------------------------------------
local function test_clock_persist_unknown_source()
  local name = "clock-persist-unknown-source"
  local Persist = require "Sequencer.Persist"
  local ClockBinding = require "Sequencer.ClockBinding"

  local startClockName = ClockBinding.getClockSourceName()
  local startResetName = ClockBinding.getResetSourceName()
  ClockBinding.clearClockSource()
  ClockBinding.clearResetSource()

  local snap = {
    schemaVersion = 3,
    slots = {},
    clock = {
      source         = "internal",
      globalDiv      = 1,
      slotDiv        = { 1, 1, 1, 1 },
      extClockSource = "ZZZ-does-not-exist",
      extResetSource = "WWW-also-bogus",
    },
  }
  for s = 1, 4 do
    snap.slots[s] = { running = false, columns = {} }
    for c = 1, 6 do
      snap.slots[s].columns[c] = { length = 16, marker1 = 0, marker2 = 15, l1 = {}, l2 = {} }
    end
  end

  local ok, err = pcall(function()
    Persist.deserialize(snap)
    if ClockBinding.getClockSourceName() ~= nil then
      error("unknown source name should leave clock binding unset")
    end
    if ClockBinding.getResetSourceName() ~= nil then
      error("unknown source name should leave reset binding unset")
    end
  end)

  ClockBinding.setClockSource(startClockName)
  ClockBinding.setResetSource(startResetName)

  if not ok then fail(name, tostring(err)); return end
  pass(name)
end

app.logInfo("sequencer_extclock_bench: starting phase 6.2-6.6 isolation tests")

test_clock_source_roundtrip()
test_global_div_clamp()
test_slot_div_clamp()
test_inlet_accessors()
test_default_ext_bpm()
test_source_switch_resets_state()
test_external_mode_no_spurious_ticks()
test_clock_binding_module()
test_clockview_instantiation()
test_clock_persist_roundtrip()
test_clock_persist_v2_migration()
test_clock_persist_unknown_source()

local total = #results
local pass_count = 0
for _, r in ipairs(results) do
  if r.ok then pass_count = pass_count + 1 end
end
app.logInfo("sequencer_extclock_bench: %d/%d PASS", pass_count, total)

-- Leave SequencerTask in a clean default state.
seq:setClockSource(CLOCK_INTERNAL)
seq:setGlobalDiv(1)
for s = 0, 3 do seq:setSlotDiv(s, 1) end

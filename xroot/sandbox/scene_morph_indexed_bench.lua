-- ParamSetMorph kVeeIndexed isolation bench (v1.1 phase 5.3b).
--
-- Drives the new addVeeIndexed entry point on the existing
-- ParamSetMorph to verify Lua-binding shape, item bookkeeping,
-- and clear/remove behavior. The audio-path apply() that consumes
-- mIndexA/mIndexB Inlets is bench-validated end-to-end when the
-- 5.4 engage path emits addVeeIndexed against a real Chain.Root;
-- here we just verify the morpher accepts the new shape without
-- regressing the existing kCached2 / kLive3 / kVee4 paths.

if not app.ParamSetMorph then
  app.logError("scene_morph_indexed_bench: ParamSetMorph not bound; aborting.")
  return
end

local results = {}
local function pass(name)
  results[#results + 1] = { name = name, ok = true }
  app.logInfo("scene_morph_indexed_bench: %s ... PASS", name)
end
local function fail(name, msg)
  results[#results + 1] = { name = name, ok = false, msg = msg }
  app.logError("scene_morph_indexed_bench: %s ... FAIL: %s",
               name, msg or "(no detail)")
end

local function mkParam(name, value)
  return app.Parameter(name, value or 0.0)
end

local function test_morph_construct_with_index_inlets()
  local name = "construct-with-index-inlets"
  local m = app.ParamSetMorph()
  m:setName("bench.morph")
  -- All three audio-input inlets must exist on the binding.
  if m:getInput("CV") == nil then
    return fail(name, "CV inlet missing")
  end
  if m:getInput("IndexA") == nil then
    return fail(name, "IndexA inlet missing")
  end
  if m:getInput("IndexB") == nil then
    return fail(name, "IndexB inlet missing")
  end
  pass(name)
end

local function test_addVeeIndexed_size_clear()
  local name = "addVeeIndexed-size-clear"
  local m = app.ParamSetMorph()
  m:setName("bench.morph")
  local target = mkParam("target", 0.0)
  local base = mkParam("base", 0.5)

  local scenes = {
    mkParam("s1", 0.1),
    mkParam("s2", 0.2),
    mkParam("s3", 0.3),
    mkParam("s4", 0.4),
  }
  m:addVeeIndexed(target, base, scenes)
  if m:size() ~= 1 then
    return fail(name, string.format(
      "size after one addVeeIndexed expected 1, got %d", m:size()))
  end
  m:clear()
  if m:size() ~= 0 then
    return fail(name, string.format(
      "size after clear expected 0, got %d", m:size()))
  end
  pass(name)
end

local function test_addVeeIndexed_dedup_by_target()
  -- Second addVeeIndexed for the same target should be a no-op,
  -- same dedup behavior as add and addVee.
  local name = "addVeeIndexed-dedup-by-target"
  local m = app.ParamSetMorph()
  m:setName("bench.morph")
  local target = mkParam("target", 0.0)
  local base = mkParam("base", 0.0)
  local scenes1 = { mkParam("s1", 0.1) }
  local scenes2 = { mkParam("s2", 0.9) }

  m:addVeeIndexed(target, base, scenes1)
  m:addVeeIndexed(target, base, scenes2)
  if m:size() ~= 1 then
    return fail(name, string.format(
      "dedup expected size 1, got %d", m:size()))
  end
  pass(name)
end

local function test_mixed_kinds_coexist()
  -- A morpher carrying a kVee4 item plus a kVeeIndexed item must
  -- not regress: size = 2, clear drains both.
  local name = "mixed-kinds-coexist"
  local m = app.ParamSetMorph()
  m:setName("bench.morph")
  local t1 = mkParam("t1", 0.0)
  local t2 = mkParam("t2", 0.0)
  local base = mkParam("base", 0.0)
  local a = mkParam("a", 0.1)
  local b = mkParam("b", 0.9)

  m:addVee(t1, base, a, b)
  m:addVeeIndexed(t2, base, { a, b })
  if m:size() ~= 2 then
    return fail(name, string.format(
      "mixed kinds expected size 2, got %d", m:size()))
  end
  m:clear()
  if m:size() ~= 0 then
    return fail(name, string.format(
      "post-clear expected size 0, got %d", m:size()))
  end
  pass(name)
end

local function test_remove_kVeeIndexed_item()
  local name = "remove-kVeeIndexed-item"
  local m = app.ParamSetMorph()
  m:setName("bench.morph")
  local t1 = mkParam("t1", 0.0)
  local t2 = mkParam("t2", 0.0)
  local base = mkParam("base", 0.0)
  local a = mkParam("a", 0.1)
  local b = mkParam("b", 0.9)

  m:addVeeIndexed(t1, base, { a })
  m:addVeeIndexed(t2, base, { b })
  m:remove(t1)
  if m:size() ~= 1 then
    return fail(name, string.format(
      "post-remove expected size 1, got %d", m:size()))
  end
  pass(name)
end

local function test_empty_scenes_vector_is_legal()
  -- Bank of size 0 (no scenes authored). addVeeIndexed should
  -- accept it; apply will clip every index to 0 and always pick
  -- baseParam. No crash.
  local name = "empty-scenes-vector-legal"
  local m = app.ParamSetMorph()
  m:setName("bench.morph")
  local target = mkParam("target", 0.0)
  local base = mkParam("base", 0.0)
  m:addVeeIndexed(target, base, {})
  if m:size() ~= 1 then
    return fail(name, "empty scenes vector should still register an item")
  end
  pass(name)
end

app.logInfo("scene_morph_indexed_bench: starting v1.1 phase 5.3b tests")
test_morph_construct_with_index_inlets()
test_addVeeIndexed_size_clear()
test_addVeeIndexed_dedup_by_target()
test_mixed_kinds_coexist()
test_remove_kVeeIndexed_item()
test_empty_scenes_vector_is_legal()

local total = #results
local pass_count = 0
for _, r in ipairs(results) do if r.ok then pass_count = pass_count + 1 end end
app.logInfo("scene_morph_indexed_bench: %d/%d PASS", pass_count, total)

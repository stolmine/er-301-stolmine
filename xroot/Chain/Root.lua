local app = app
local Class = require "Base.Class"
local Chain = require "Chain"
local ScopeView = require "Chain.ScopeView"
local PinView = require "PinView"
local SequencerView = require "Sequencer.GridView"
local Branch = require "Chain.Branch"

local Root = Class {}
Root:include(Chain)

function Root:init(args)
  Chain.init(self, args)
  self:setClassName("Chain.Root")
  self.isRoot = true
  self.scopeView = ScopeView(self)
  self.pinView = PinView(self)
  self.sequencerView = SequencerView(self)
  -- SceneView state container is created LAZILY (see getSceneView).
  -- The scene mode rework is in-development; users with scene
  -- mode never enabled pay zero boot cost from it. The state
  -- container itself is cheap, but lazy avoids any chance of an
  -- in-flight SceneView change side-effecting the chain init path.
end

function Root:getSceneView()
  if self.sceneView == nil then
    local SceneView = require "SceneView"
    self.sceneView = SceneView(self)
  end
  return self.sceneView
end

function Root:getRootChain()
  return self
end

-- True while the chain is armed for scene authoring. Patch-state
-- gestures (insert / paste / delete / bypass / move / rename /
-- preset-replace) check this and refuse with a flash message;
-- only parameter edits via encoder/readout are allowed in that
-- mode. The scene delta map only tracks param values, so allowing
-- structural edits would silently produce changes that survive
-- exiting the scene (defeating the "scene as an editable preset
-- of values" model).
function Root:isLockedForSceneAuthoring()
  return self.activeAuthoringScene ~= nil
end

-- Helper for the gated callsites. Shows a flash message and
-- returns true when locked; callsites do `if ... then return end`.
function Root:rejectSceneAuthoringEdit()
  if self.activeAuthoringScene == nil then return false end
  local Overlay = require "Overlay"
  Overlay.flashMainMessage("Locked while editing scene.")
  return true
end

function Root:addPinSet(name)
  return self.pinView:addPinSet(name)
end

function Root:suggestPinSetName()
  return self.pinView:suggestPinSetName()
end

function Root:getPinSetByName(name)
  return self.pinView:getPinSetByName(name)
end

function Root:getPinSetMembership(control)
  return self.pinView:getPinSetMembership(control)
end

function Root:getPinSetNames(optionalControl)
  return self.pinView:getPinSetNames(optionalControl)
end

function Root:pinControlToAllPinSets(control)
  self.pinView:pinControlToAllPinSets(control)
end

function Root:unpinControlFromAllPinSets(control)
  self.pinView:unpinControlFromAllPinSets(control)
end

function Root:serializePins()
  return self.pinView:serialize()
end

function Root:deserializePins(data)
  self.pinView:deserialize(data)
end

function Root:serialize()
  -- If scene mode is engaged, temporarily yank the morpher task
  -- off the audio thread so it can't write audio = blend during
  -- the unit-walk. Hard-restore audio Params to base, capture
  -- state, then re-add the task. The audio thread's next pass
  -- writes audio = blend(base, A, B) again.
  --
  -- An earlier (.30) version held _sceneTask:lock across the
  -- whole serialize. That worked semantically but blocked the
  -- audio thread at the task's mutex for the full unit-walk
  -- duration -- watchdog kill / hard crash. removeTask /
  -- addTask is the lighter-weight equivalent: the audio thread
  -- just doesn't schedule the morpher for the window.
  local snappedForSave = false
  if self._sceneEngaged and self._sceneTask then
    app.AudioThread.removeTask(self._sceneTask)
    self:_hardRestoreAudioToBase()
    snappedForSave = true
  end

  local t = Chain.serialize(self)
  t.pinView = self.pinView:serialize()
  -- Only serialize scene state if SceneView has actually been
  -- created (user enabled scene mode at some point). Lazy init
  -- means most users get nothing extra written to their presets.
  if self.sceneView then
    t.sceneView = self.sceneView:serialize()
  end
  -- Scene-CV pipeline state per role (M1 dive contents + bias/
  -- gain for "morph"; v1.1 adds "A" / "B" with their own dive +
  -- arbiter params). Branches are held directly on Root, NOT in
  -- self.units, so the standard Chain.serialize walk doesn't reach
  -- them. Only written if scene mode has been engaged at least
  -- once this session (the pipeline is lazy-built by
  -- _getOrBuildSceneMorph). Legacy single-role saves are read back
  -- under role "morph" in deserialize.
  if self._sceneCVBranches and next(self._sceneCVBranches) then
    t.sceneCVBranches = {}
    for role, entry in pairs(self._sceneCVBranches) do
      t.sceneCVBranches[role] = {
        branch = entry.branch:serialize(),
        params = {
          bias = entry.valueSource:getParameter("Bias"):target(),
          gain = entry.valueSource:getParameter("Gain"):target(),
        },
      }
    end
  end

  if snappedForSave then
    -- Re-add task; morpher's next apply writes audio = blend(
    -- base, A, B), audio returns to its pre-snapshot blended
    -- state. Audible glitch is one audio frame of "audio at
    -- base" -- imperceptible unless bias was at an extreme.
    app.AudioThread.addTask(self._sceneTask, 0)
  end
  return t
end

function Root:deserialize(t)
  Chain.deserialize(self, t)
  if t.pinView then
    self.pinView:deserialize(t.pinView)
  else
    self.pinView:removeAllPinSets()
  end
  if t.sceneView then
    -- Force-create SceneView only if the preset actually carries
    -- scene state. Restores the data verbatim.
    self:getSceneView():deserialize(t.sceneView)
  end
  -- Scene-CV pipeline restore. Force-build the morpher + per-role
  -- GainBias / branch BEFORE restoring state (same lazy entry
  -- point the HOLD-press path takes). Bias / gain restored via
  -- hardSet so values land immediately without softSet ramp
  -- dynamics.
  --
  -- v1.1 reads the new sceneCVBranches map keyed by role; legacy
  -- v1.0 saves carry sceneCVBranch + sceneCVParams (single morph
  -- role) and migrate transparently. v1.1 phase 5.3 will add
  -- "A" and "B" roles; for now only "morph" is built so unknown
  -- roles in a preset (none should exist yet) are ignored.
  local hadLegacySceneCV = false
  if t.sceneCVBranches then
    self:_getOrBuildSceneMorph()
    for role, entry in pairs(t.sceneCVBranches) do
      local target = self._sceneCVBranches[role]
      if target then
        if entry.branch then
          target.branch:deserialize(entry.branch)
        end
        if entry.params then
          if entry.params.bias then
            target.valueSource:getParameter("Bias"):hardSet(entry.params.bias)
          end
          if entry.params.gain then
            target.valueSource:getParameter("Gain"):hardSet(entry.params.gain)
          end
        end
      end
    end
  elseif t.sceneCVBranch or t.sceneCVParams then
    -- Legacy v1.0 single-role format.
    hadLegacySceneCV = true
    self:_getOrBuildSceneMorph()
    local morph = self._sceneCVBranches.morph
    if t.sceneCVBranch then
      morph.branch:deserialize(t.sceneCVBranch)
    end
    if t.sceneCVParams then
      if t.sceneCVParams.bias then
        morph.valueSource:getParameter("Bias"):hardSet(t.sceneCVParams.bias)
      end
      if t.sceneCVParams.gain then
        morph.valueSource:getParameter("Gain"):hardSet(t.sceneCVParams.gain)
      end
    end
  end

  -- Post-restore arbiter wakeup. Parameter:hardSet above bypasses
  -- arbiter:hardSetBias, so each A/B arbiter's state-machine
  -- baseline (mGainAtEntry / mCVInputAtEntry) is still at the
  -- cold-start default of 0 -- the Schmitt comparison evaluates
  -- to 0 and CV input is inert until the user manually nudges a
  -- control. Relatch the baseline from the just-restored
  -- Gain/Bias so CV is responsive on the first audio frame
  -- after reboot. v1.0 saves additionally need crossfaderA/B ints
  -- migrated into the arbiters because the legacy format didn't
  -- carry per-role Bias values.
  if self._sceneCVBranches then
    if hadLegacySceneCV then
      self:_migrateLegacyCrossfaders()
    end
    self:_relatchSceneArbiters()
  end
end

-- Post-deserialize: call arbiter:hardSetBias on each A/B arbiter
-- so the state machine latches mGainAtEntry / mCVInputAtEntry
-- from current Gain.target and the cached last CV sample. Bias
-- value itself is preserved (we pass its current target back in).
-- Without this, Schmitt math degenerates to 0 * delta = 0 and
-- CV-driven scene selection can never trip until the user
-- manually nudges Bias / Gain via encoder or chip tap.
function Root:_relatchSceneArbiters()
  if not self._sceneCVBranches then return end
  for _, entry in pairs(self._sceneCVBranches) do
    if entry.arbiter then
      local biasTarget = entry.arbiter:getParameter("Bias"):target()
      entry.arbiter:hardSetBias(biasTarget)
    end
  end
end

-- Migration helper for legacy v1.0 saves that carry A/B
-- assignment only in SceneView.crossfaderA/B integers (no
-- arbiter Bias in the persisted state). Populate each arbiter's
-- Bias from idx / N so the audible assignment survives the
-- upgrade. Only runs on the legacy-path elseif branch in
-- deserialize; modern saves have arbiter Bias restored directly
-- and don't need this.
function Root:_migrateLegacyCrossfaders()
  if not (self.sceneView and self._sceneCVBranches) then return end
  local n = self.sceneView:getSceneCount()
  if n <= 0 then return end
  local roleToIdx = {
    A = self.sceneView:getCrossfaderA(),
    B = self.sceneView:getCrossfaderB(),
  }
  for role, idx in pairs(roleToIdx) do
    local entry = self._sceneCVBranches[role]
    if entry and entry.arbiter and idx and idx > 0 then
      entry.arbiter:hardSetBias(idx / n)
    end
  end
end

-- Reset all scene-mode state on this chain to "user has never
-- touched scene mode for this chain" equivalent. Used by the
-- admin menu's "Reset scene mode" action and by the Channels
-- link/unlink path (which strips scene state from the cross-
-- chain snapshot, so the destination chain inherits no scene
-- data from the source). Idempotent.
--
-- Order matters: disengage first so the modulated-display swap
-- is undone and audio Parameters get restored to their base
-- values BEFORE we drop the scene Parameters those values came
-- from. Otherwise the audio could glitch to whatever sample-
-- accurate junk the morpher last computed.
function Root:resetSceneMode()
  -- Bail early if scene mode infrastructure was never built;
  -- nothing to reset.
  if not (self._sceneMorph or self.sceneView) then return end

  if self._sceneEngaged then
    self:disengageSceneMorph()
  end

  if self.sceneView then
    self.sceneView:removeAllScenes()
  end

  if self._sceneCVBranches then
    for _, entry in pairs(self._sceneCVBranches) do
      -- Clear any user-inserted modulation source units from
      -- the role's CV subchain.
      if entry.branch and entry.branch.clear then
        entry.branch:clear()
      end
      -- Reset value-source Parameters to defaults: Bias = 0
      -- (cold-start manual home), Gain = 0 (cold-start CV
      -- inert until user re-enables).
      if entry.valueSource then
        local bias = entry.valueSource:getParameter("Bias")
        local gain = entry.valueSource:getParameter("Gain")
        if bias then bias:hardSet(0) end
        if gain then gain:hardSet(0) end
      end
      -- Relatch arbiter state machines so mGainAtEntry /
      -- mCVInputAtEntry track the reset Bias/Gain. Same logic
      -- as the deserialize-side _relatchSceneArbiters; matches
      -- the cold-start contract for fresh chains.
      if entry.arbiter then
        entry.arbiter:hardSetBias(0)
      end
    end
  end
end

function Root:pin(control, pinSetName)
  self.pinView:pin(control, pinSetName)
end

function Root:unpin(control, pinSetName)
  self.pinView:unpin(control, pinSetName)
end

function Root:enterHoldMode()
end

function Root:leaveHoldMode()
end

-- Recursively visit every unit reachable from a chain: the chain's
-- own units, plus every unit inside any child chain each unit
-- exposes via Unit:walkChildChains. The default walkChildChains
-- visits self.branches (mod branches); CustomEffect/CustomSource
-- also visit self.patch (the container interior); MultiBand also
-- visits self.bands[1..N]. Adding a new container type only needs
-- to override walkChildChains; the walker stays generic.
--
-- Used by the scene-authoring enter/exit walks. The delta map's
-- unit-instance keys are globally unique inside the root chain, so
-- nested units land in the same flat storage table with no clash.
local function _walkAllUnits(chain, callback)
  for i = 1, chain:length() do
    local unit = chain:getUnit(i)
    if unit then
      callback(unit)
      if unit.walkChildChains then
        unit:walkChildChains(function(childChain)
          _walkAllUnits(childChain, callback)
        end)
      end
    end
  end
end

-- Parallel walker that visits the root chain and every reachable
-- sub-chain (via Unit:walkChildChains). Used for the scene
-- subtitle propagation so the "editing Sn" indicator shows on
-- every chain header the user can dive into, not just the root.
local function _walkAllChains(chain, callback)
  callback(chain)
  for i = 1, chain:length() do
    local unit = chain:getUnit(i)
    if unit and unit.walkChildChains then
      unit:walkChildChains(function(childChain)
        _walkAllChains(childChain, callback)
      end)
    end
  end
end

-- Hard-restore every audio Parameter that the morpher writes to,
-- back to its user-edit base value. Used at disengage and at
-- save time so the audio Param matches the user's pre-scene
-- value rather than the morpher's last blend output.
--
-- Without the save-time call, persisting while scene mode is
-- engaged would capture audio = blend(base, sceneA, sceneB) into
-- the preset. On reload, re-engaging snapshots base from
-- audio.target -- so the *blended* value becomes the new base,
-- permanently baking in whatever scene contribution was active
-- at save time.
--
-- Lives AFTER _walkAllUnits / _walkAllChains so the closure
-- captures them as locals. An earlier (.29 - .31) placement
-- before the walker definitions made `_walkAllUnits` resolve to
-- the nil global, hard-crashing the .30 quicksave
-- (Chain.Root.lua:109: attempt to call a nil value).
function Root:_hardRestoreAudioToBase()
  if self._sceneBaseParams == nil then return end
  _walkAllUnits(self, function(unit)
    if not unit.controls then return end
    local unitKey = unit:getInstanceKey()
    local perUnit = self._sceneBaseParams[unitKey]
    if not perUnit then return end
    for ctrlId, control in pairs(unit.controls) do
      if control.getSceneAudioParam then
        local baseParam = perUnit[ctrlId]
        if baseParam then
          local audioParam = control:getSceneAudioParam()
          if audioParam then
            audioParam:hardSet(baseParam:target())
          end
        end
      end
    end
  end)
end

-- Arm every delta-able control reachable from the root chain for
-- scene authoring. The walk descends through mod branches AND
-- Custom-Unit interiors so a tweak inside, say, a Reverb's wet
-- gain (which lives in a CustomEffect's self.patch) is captured
-- in the scene like any top-level fader.
--
-- For each control that exposes enterSceneMode, builds a per-scene
-- target parameter (initialized to the scene's existing delta if
-- one exists, else to the control's current live value) and tells
-- the control to swap its widget's control parameter to that
-- target. Audio doesn't change; the live value parameter still
-- holds the base value. The user's encoder edits inside scene
-- authoring write to the per-scene target.
function Root:enterSceneAuthoring(sceneView, sceneIdx)
  if self.activeAuthoringScene then return end  -- already armed
  local scene = sceneView:getScene(sceneIdx)
  if scene == nil then return end
  self.activeAuthoringScene = scene
  self.activeAuthoringIdx   = sceneIdx
  -- Header indicator so the user knows they're editing scene N,
  -- not making live audio-path changes. Propagated to every
  -- sub-chain so the cue survives a branch-dive. Previous
  -- subtitle on each chain (e.g. "muted") is saved and restored
  -- on exit so scene authoring doesn't clobber other indicators.
  local label = "editing " .. (scene.name or string.format("S%d", sceneIdx))
  self._scenePrevSubtitles = {}
  _walkAllChains(self, function(c)
    self._scenePrevSubtitles[#self._scenePrevSubtitles + 1] =
      { chain = c, prev = c.subTitle }
    c:setSubTitle(label)
  end)

  -- Corner dog-ear on the main display (page-fold metaphor:
  -- you're on the underside of the page, editing scene state).
  -- Flipped on every reachable chain so the cue survives a
  -- sub-chain dive at any depth -- the indicator graphic lives
  -- on each chain's mainGraphic, the walk just toggles them.
  _walkAllChains(self, function(c)
    if c._setSceneAuthoringIndicator then
      c:_setSceneAuthoringIndicator(true)
    end
  end)

  -- Arm any control not already in modulated display BEFORE
  -- swapping to scene-editing. enterSceneMode early-returns on
  -- _modAudioParam==nil so a unit added since the last
  -- engage/rebuild would otherwise have its widget stay bound
  -- to the live audio param: encoder writes during authoring
  -- would hard-edit audio (airlock break) and the widget's
  -- highlight would never transition, leaving it at the C++
  -- default mHighlightTarget=true which visually matches the
  -- scene-editing look. Funneling through _armAllControlsModulated
  -- guarantees every reachable delta-able control is in the
  -- expected pre-condition (modulated, baseParam holding the
  -- live audio value) before enterSceneMode swaps to editing.
  if self._sceneEngaged then
    self:_armAllControlsModulated()
  end

  _walkAllUnits(self, function(unit)
    if not unit.controls then return end
    local unitKey = unit:getInstanceKey()
    for ctrlId, control in pairs(unit.controls) do
      if control.enterSceneMode then
        local baseVal = control:getSceneBaseValue()
        -- Persistent per-scene Parameter (4.3). Same instance
        -- referenced by morpher items (4.5), so encoder writes
        -- here track audio live during authoring without
        -- requiring a morpher rebuild on every keystroke.
        local targetParam = scene:getOrCreateParam(unitKey, ctrlId, baseVal)
        control:enterSceneMode(targetParam)
      end
    end
  end)
end

-- Restore every armed control to its pre-scene state and capture
-- each per-scene target value back into the scene's delta map.
-- Only values that differ from the live base become deltas;
-- equal-to-base targets are cleared so the scene's delta count
-- stays meaningful (no-op deltas don't clutter the map).
function Root:exitSceneAuthoring()
  if self.activeAuthoringScene == nil then return end
  local scene = self.activeAuthoringScene

  _walkAllUnits(self, function(unit)
    if not unit.controls then return end
    local unitKey = unit:getInstanceKey()
    for ctrlId, control in pairs(unit.controls) do
      if control.exitSceneMode and control.getSceneTargetValue then
        -- Only controls that actually entered scene-editing
        -- (_sceneTargetParam non-nil) contribute a delta. With
        -- the _armAllControlsModulated pre-condition in
        -- enterSceneAuthoring this should be every delta-able
        -- control; the guard exists for safety so any future
        -- skipped path (a control without enterModulatedDisplay,
        -- a structural-lock corner case) can't pollute the scene
        -- with a spurious 0-delta from getSceneTargetValue's
        -- "return 0 when not editing" fallback.
        if control._sceneTargetParam then
          local targetVal = control:getSceneTargetValue()
          local baseVal   = control:getSceneBaseValue()
          if math.abs(targetVal - baseVal) > 1e-6 then
            scene:setDelta(unitKey, ctrlId, targetVal)
          else
            scene:setDelta(unitKey, ctrlId, nil)
            -- Drop the scene's persistent Parameter too. Without
            -- this the morpher's next rebuild would still see the
            -- (no-op) delta via scene.params and bind to it instead
            -- of falling back to the base Parameter. C++ refcount
            -- keeps the Parameter alive until the morpher releases
            -- its handle on next clear/rebuild.
            if scene.params[unitKey] then
              scene.params[unitKey][ctrlId] = nil
              if next(scene.params[unitKey]) == nil then
                scene.params[unitKey] = nil
              end
            end
          end
        end
        control:exitSceneMode()
      end
    end
  end)

  self.activeAuthoringScene = nil
  self.activeAuthoringIdx   = nil
  -- Restore each chain's pre-authoring subtitle (nil = clear).
  -- Chains added or removed during authoring are blocked by the
  -- structural-edit lock, so the saved list always matches.
  if self._scenePrevSubtitles then
    for _, entry in ipairs(self._scenePrevSubtitles) do
      if entry.prev then
        entry.chain:setSubTitle(entry.prev)
      else
        entry.chain:clearSubTitle()
      end
    end
    self._scenePrevSubtitles = nil
  end

  -- Newly-added deltas (first edits in this authoring session)
  -- and newly-pruned no-op deltas both change which endpoint
  -- Parameter the morpher should bind for the just-authored
  -- scene. Rebuild items so the Performance view sees the
  -- update on return. Idempotent / cheap; skipped if morpher
  -- isn't engaged (shouldn't be reachable: scene authoring is
  -- only entered from Performance which engages the morpher).
  if self._sceneEngaged then
    self:rebuildSceneMorph()
  end

  _walkAllChains(self, function(c)
    if c._setSceneAuthoringIndicator then
      c:_setSceneAuthoringIndicator(false)
    end
  end)
end

------------------------------------------------------
-- Scene crossfader engine.
--
-- A single per-Root ParamSetMorph (with the 4.1 3-Parameter Item
-- variant) interpolates every delta-able control's audio
-- Parameter between scene A's and scene B's stored Parameters,
-- weighted by the output of a chain-owned app.GainBias whose
-- bias is the manual weight (M1 encoder in Performance view) and
-- whose input branch is user-extensible (M1 dive in Performance
-- view; users drop CV sources / LFOs / S&H / whatever).
--
-- Lazy created on first engage; survives until the chain is
-- destroyed. Per-control base Parameter snapshots refreshed each
-- engage from each audio param's current target().

-- Lazy: build the morpher, the scene-cv GainBias + its mod
-- branch, the audio-rate task that runs them, and wire the
-- GainBias.Out -> morpher.mCV connection. Idempotent.
function Root:_getOrBuildSceneMorph()
  if self._sceneMorph then return self._sceneMorph end

  local morph = app.ParamSetMorph()
  morph:setName(self.title .. ".SceneMorph")
  -- Pin Vee semantics for the scene-cv pipeline. Without this the
  -- morpher's mVeeMode auto-flag only flips true once at least one
  -- VEE Item has been added, so a fresh chain with no scene deltas
  -- runs in the legacy linear (1-cv)/2 remap and the live "Weight"
  -- Parameter that views read for indicators reports the wrong
  -- semantics (halfway at 0, reversed at extremes).
  morph:setVeeMode(true)
  self._sceneMorph = morph

  -- Multi-role scene-CV map. Role -> {branch, gainBias|arbiter,
  -- valueSource, range}. "morph" carries a GainBias whose Out
  -- drives the morpher's CV inlet (continuous A<->B blend
  -- weight in [-1, +1]). "A" / "B" carry a SceneIndexArbiter
  -- whose Out drives the morpher's IndexA / IndexB inlets
  -- (integer scene index). The morpher consumes the index inlets
  -- only for kVeeIndexed items (added in phase 5.5); until then
  -- the arbiter outputs are wired but ignored, so the M2/M3 dive
  -- controls can render the arbiter state independent of the
  -- morpher's selection path.
  self._sceneCVBranches = {}
  self:_buildSceneCVMorphRole(morph:getInput("CV"))
  self:_buildSceneCVArbiterRole("A", morph:getInput("IndexA"))
  self:_buildSceneCVArbiterRole("B", morph:getInput("IndexB"))

  -- Per-control base Parameter snapshots, refreshed every engage.
  -- Map: [unitKey][ctrlId] = app.Parameter holding the user-mode
  -- value at the moment scene mode was engaged.
  self._sceneBaseParams = {}

  -- Audio-rate task that processes the GainBias then the morpher
  -- (process order = insertion order). Add/remove from
  -- AudioThread on engage/disengage.
  self._sceneTask = app.ObjectList(self.title .. ".SceneTask")

  -- Seed arbiter scene-count from current SceneView if one exists.
  self:_syncSceneArbiterCounts()

  return self._sceneMorph
end

-- Build the morph role: GainBias (linear sum, additive CV) +
-- MinMax range + Branch wrapping the GainBias input. Stored under
-- role "morph". GainBias.Out -> morpher.CV drives the continuous
-- A<->B weight in [-1, +1].
function Root:_buildSceneCVMorphRole(consumerInlet)
  local gb = app.GainBias()
  gb:setName(self.title .. ".SceneCV.morph")

  local range = app.MinMax()
  range:setName(self.title .. ".SceneCVRange.morph")

  local branch = Branch {
    title = self.title,
    subTitle = "scene-cv morph",
    depth = self.depth + 1,
    channelCount = 1,
    leftDestination = gb:getInput("In"),
    leftOutObject = gb,
    leftOutletName = "Out",
    unit = self,
  }

  app.AudioThread.connect(gb:getOutput("Out"), consumerInlet)
  app.AudioThread.connect(gb:getOutput("Out"), range:getInput("In"))

  self._sceneCVBranches["morph"] = {
    branch = branch,
    gainBias = gb,
    valueSource = gb,  -- uniform key for engage/serialize loops
    range = range,
  }
end

-- Build an A/B role: SceneIndexArbiter (2-state machine, last-
-- writer-wins between CV input and manual writes) + MinMax range
-- + Branch wrapping the arbiter input. Arbiter.Out drives the
-- morpher's IndexA or IndexB inlet for live scene-index
-- selection in kVeeIndexed items. Until the engage path emits
-- addVeeIndexed (phase 5.5), the morpher ignores these inlets;
-- the arbiter still runs each frame so M2/M3 dive controls can
-- render its state independent of the morpher's actual
-- selection path.
function Root:_buildSceneCVArbiterRole(role, consumerInlet)
  local arb = app.SceneIndexArbiter()
  arb:setName(self.title .. ".SceneCV." .. role)

  local range = app.MinMax()
  range:setName(self.title .. ".SceneCVRange." .. role)

  local branch = Branch {
    title = self.title,
    subTitle = "scene-cv " .. role,
    depth = self.depth + 1,
    channelCount = 1,
    leftDestination = arb:getInput("In"),
    leftOutObject = arb,
    leftOutletName = "Out",
    unit = self,
  }

  app.AudioThread.connect(arb:getOutput("Out"), consumerInlet)
  -- Range bar reads the normalized [0, 1] effective position so
  -- the M2/M3 fader's swing visualization sits in the fader's
  -- coord system (Bias is normalized too). Wiring the integer
  -- "Out" here would push values 0..N which clip outside the
  -- fader's 0..1 map.
  app.AudioThread.connect(arb:getOutput("OutNorm"), range:getInput("In"))

  self._sceneCVBranches[role] = {
    branch = branch,
    arbiter = arb,
    valueSource = arb,  -- uniform key for engage/serialize loops
    range = range,
  }
end

function Root:getSceneCVBranch(role)
  self:_getOrBuildSceneMorph()
  local entry = self._sceneCVBranches[role or "morph"]
  return entry and entry.branch
end

function Root:getSceneCVGainBias(role)
  self:_getOrBuildSceneMorph()
  local entry = self._sceneCVBranches[role or "morph"]
  return entry and entry.gainBias
end

-- A / B role accessor. Returns the SceneIndexArbiter for the
-- given role, or nil for "morph" (which has a GainBias instead).
-- SceneSelectorControl uses this to bind its Bias/Gain readouts
-- and to route chip-tap / encoder writes to hardSetBias.
function Root:getSceneArbiter(role)
  self:_getOrBuildSceneMorph()
  local entry = self._sceneCVBranches[role]
  return entry and entry.arbiter
end

-- Push the current SceneView count into every A/B arbiter so
-- Bias clips correctly and the morpher's IndexA/B Inlets see
-- valid index ranges. Called after build, on engage, and after
-- any scene add/delete (rebuildSceneMorph). No-op for the morph
-- role (no arbiter there).
function Root:_syncSceneArbiterCounts()
  if not self._sceneCVBranches then return end
  local n = self.sceneView and self.sceneView:getSceneCount() or 0
  for _, entry in pairs(self._sceneCVBranches) do
    if entry.arbiter then entry.arbiter:setSceneCount(n) end
  end
end

-- Expose the morpher itself so views can subscribe to its live
-- "Weight" Parameter (post-CV crossfade weight, [-1, +1]).
-- Performance view's per-slot bias-fill indicator reads this each
-- frame to animate. Built lazily like the rest of the scene-cv
-- chain so callers can hit this before scene mode is engaged.
function Root:getSceneMorph()
  self:_getOrBuildSceneMorph()
  return self._sceneMorph
end

function Root:getSceneCVRange(role)
  self:_getOrBuildSceneMorph()
  local entry = self._sceneCVBranches[role or "morph"]
  return entry and entry.range
end

function Root:_getOrCreateBaseParam(unitKey, ctrlId)
  local u = self._sceneBaseParams[unitKey]
  if u == nil then
    u = {}
    self._sceneBaseParams[unitKey] = u
  end
  local p = u[ctrlId]
  if p == nil then
    p = app.Parameter(string.format("scene-base/%s/%s",
                                    tostring(unitKey), ctrlId), 0)
    u[ctrlId] = p
  end
  return p
end

-- Arm a single control's modulated-display state. Idempotent.
-- Already-modulated controls: no-op (don't re-snapshot base, the
-- user has been editing it since the original engage).
-- New controls: snapshot base from the live audio target, then
-- swap the widget into modulated display so subsequent encoder
-- writes go to base.
--
-- Centralized because three entry points have to guarantee
-- "every delta-able control is armed before the next scene
-- operation touches it":
--   - engageSceneMorph: initial bulk arm.
--   - rebuildSceneMorph: defensive re-arm on scene assignment
--     changes (catches units added since engage).
--   - enterSceneAuthoring: defensive re-arm before swapping
--     widgets into scene-editing. Without this, a unit added
--     between the most recent rebuild and authoring entry would
--     hit enterSceneMode's "if not _modAudioParam then return"
--     guard and stay in normal-display state. Authoring's
--     encoder writes would then hit the live audio param
--     directly -- "airlock break" -- and exiting authoring
--     could leave the widget at the wrong highlight (C++
--     default mHighlightTarget=true reads as "scene-editing
--     look" because it was never transitioned).
function Root:_armControlModulated(unitKey, ctrlId, control)
  if not (control.enterModulatedDisplay and control.getSceneAudioParam) then
    return
  end
  if control._modAudioParam then return end
  local audioParam = control:getSceneAudioParam()
  if not audioParam then return end
  local baseParam = self:_getOrCreateBaseParam(unitKey, ctrlId)
  baseParam:hardSet(audioParam:target())
  control:enterModulatedDisplay(audioParam, baseParam)
end

-- Walk every delta-able control reachable from the root chain
-- and arm any that aren't already in modulated display. Used by
-- every scene-operation entry point so newly-added units never
-- slip through.
function Root:_armAllControlsModulated()
  _walkAllUnits(self, function(unit)
    if not unit.controls then return end
    local unitKey = unit:getInstanceKey()
    for ctrlId, control in pairs(unit.controls) do
      self:_armControlModulated(unitKey, ctrlId, control)
    end
  end)
end

-- Walk every delta-able control and add a 4-Parameter VEE morpher
-- item per (audio target, base, sceneA endpoint, sceneB endpoint).
-- The VEE blend keeps the live audio param at the user's pre-scene
-- value (base) when the bias is at center, and only pulls toward
-- a scene's stored value as the user moves bias to that side.
--
-- Unassigned endpoints pass baseParam as the "scene" so the
-- per-side multiplier collapses to (1-w)*base + w*base = base
-- and the side has no audible effect.
function Root:_buildSceneMorphItems()
  if self.sceneView == nil then return end
  local morph = self._sceneMorph
  if morph == nil then return end

  -- v1.1: emit kVeeIndexed items with the full per-scene Parameter
  -- list. apply() reads IndexA/IndexB Inlets each frame (driven
  -- by the A/B SceneIndexArbiter Outlets) and picks the
  -- corresponding scene Parameters from this table; index 0 maps
  -- to baseParam (the "unassigned" semantic v1.0 also used).
  -- Scenes that have no delta for a given control fall back to
  -- baseParam so a sweep through them reveals the user's
  -- pre-scene base value.
  local n = self.sceneView:getSceneCount()
  local scenes = {}
  for i = 1, n do
    scenes[i] = self.sceneView:getScene(i)
  end

  _walkAllUnits(self, function(unit)
    if not unit.controls then return end
    local unitKey = unit:getInstanceKey()
    for ctrlId, control in pairs(unit.controls) do
      if control.getSceneAudioParam then
        local audioParam = control:getSceneAudioParam()
        local baseParam  = self:_getOrCreateBaseParam(unitKey, ctrlId)
        local baseVal    = control:getSceneBaseValue()

        local perScene = {}
        for i = 1, n do
          local scene = scenes[i]
          if scene and scene:hasDelta(unitKey, ctrlId) then
            perScene[i] = scene:getOrCreateParam(unitKey, ctrlId, baseVal)
          else
            perScene[i] = baseParam
          end
        end

        morph:addVeeIndexed(audioParam, baseParam, perScene)
      end
    end
  end)
end

-- Engage. Refresh base snapshots from current user-mode values,
-- build morpher items per the crossfader A/B assignments, and
-- schedule the audio-rate task. Idempotent.
function Root:engageSceneMorph()
  if self._sceneEngaged then return end
  if self.sceneView == nil then return end  -- no scenes ever created

  self:_getOrBuildSceneMorph()
  -- Sync arbiter scene-counts before any audio starts so Bias
  -- clamps line up with the current bank size.
  self:_syncSceneArbiterCounts()

  -- Refresh base snapshots from audio params. This is the user's
  -- pre-scene-mode value captured into baseParam; once engaged,
  -- the morpher writes audio = base + scene_offset, the user's
  -- encoder writes go to baseParam (via the modulated-display
  -- widget swap below), and audio drifts no longer affect base.
  _walkAllUnits(self, function(unit)
    if not unit.controls then return end
    local unitKey = unit:getInstanceKey()
    for ctrlId, control in pairs(unit.controls) do
      if control.getSceneBaseValue then
        local baseParam = self:_getOrCreateBaseParam(unitKey, ctrlId)
        baseParam:hardSet(control:getSceneBaseValue())
      end
    end
  end)

  -- Swap every delta-able ViewControl into modulated display:
  -- box (hollow rectangle) shows the user-set base; line (grey)
  -- shows the audio param's morphed output. Encoder writes go
  -- to baseParam, never to the audio param. Mirrors the
  -- per-control state-machine spec in
  -- docs/planning/scene-modulation-in-user-edit.md.
  self:_armAllControlsModulated()

  self._sceneTask:lock()
  self._sceneTask:clear()
  self._sceneMorph:clear()
  self:_buildSceneMorphItems()
  -- Order matters: each role's GainBias writes its Out, then its
  -- range reads it, then the morpher reads from each role's Out
  -- (morph -> mCV; future A/B -> arbiter index inlets). All must
  -- be in the same task in this order so the morpher and ranges
  -- see fresh data each frame.
  for _, entry in pairs(self._sceneCVBranches) do
    self._sceneTask:add(entry.valueSource)
    if entry.range then
      self._sceneTask:add(entry.range)
    end
  end
  self._sceneTask:add(self._sceneMorph)
  self._sceneTask:unlock()

  app.AudioThread.addTask(self._sceneTask, 0)
  -- Start every role's scene-cv branch so any CV-source units the
  -- user has inserted gets scheduled by AudioThread. start() is
  -- refcounted (stopCount) -- safe to call across engages.
  for _, entry in pairs(self._sceneCVBranches) do
    entry.branch:start()
  end
  self._sceneEngaged = true
end

-- Disengage. Tear down the audio-rate scheduling and drop the
-- live Parameters from each scene (the on-disk float deltas
-- survive). Base Parameters stay -- cheap, reused next engage.
function Root:disengageSceneMorph()
  if not self._sceneEngaged then return end

  -- Stop every role's scene-cv branch first so its units stop
  -- processing before we tear down the GainBias they feed into.
  if self._sceneCVBranches then
    for _, entry in pairs(self._sceneCVBranches) do
      entry.branch:stop()
    end
  end

  app.AudioThread.removeTask(self._sceneTask)

  self._sceneTask:lock()
  self._sceneTask:clear()
  self._sceneTask:unlock()

  if self._sceneMorph then
    self._sceneMorph:clear()
  end

  -- Hard-restore every audio param to its user-edit base. With
  -- the modulated-display swap during engage, baseParam holds
  -- the user's authoritative value -- the encoder has been
  -- writing here, not to the audio param. The morpher's softSet
  -- has been driving the audio param (= base + offset); we now
  -- need to snap the audio param back to base before we swap
  -- the widget back to "audio param drives everything" via
  -- exitModulatedDisplay.
  self:_hardRestoreAudioToBase()

  -- Exit modulated display on every delta-able control: widgets
  -- snap back to single-param (audio) binding. After this point
  -- the user-edit view is indistinguishable from a chain that
  -- never had scene mode active.
  _walkAllUnits(self, function(unit)
    if not unit.controls then return end
    for _, control in pairs(unit.controls) do
      if control.exitModulatedDisplay then
        control:exitModulatedDisplay()
      end
    end
  end)

  if self.sceneView then
    for i = 1, self.sceneView:getSceneCount() do
      local scene = self.sceneView:getScene(i)
      if scene and scene.releaseParams then
        scene:releaseParams()
      end
    end
  end

  self._sceneEngaged = false
end

-- Rebuild items without disengaging. Called when the user cycles
-- A/B roles or adds/removes a scene.
--
-- Walks every delta-able control to make sure baseParam and the
-- modulated-display widget swap are correctly armed BEFORE the
-- morpher items reference them. Controls that engaged at the
-- start of scene mode are already correct (no-op); controls
-- added since (e.g. a freshly-inserted unit) get a base
-- snapshot from their live audio target and the modulated swap
-- now. Without this defensive walk, a unit added mid-session
-- would have baseParam at the default-zero value and the
-- morpher would softSet its audio to 0 every frame.
function Root:rebuildSceneMorph()
  if not self._sceneEngaged then return end
  self._sceneTask:lock()
  -- Catch any units added since engage / last rebuild.
  -- Already-modulated controls are no-op here; baseParam tracks
  -- the user's encoder edits and stays correct.
  self:_armAllControlsModulated()
  self._sceneMorph:clear()
  self:_buildSceneMorphItems()
  self._sceneTask:unlock()
  -- Bank may have grown / shrunk since last rebuild; refresh
  -- the arbiters' clip ranges so Bias values stay in-bounds.
  self:_syncSceneArbiterCounts()
end

-- Egress gestures from inside scene authoring. When the chain is
-- armed for scene editing, UP / shift+HOME / CANCEL all return to
-- the Performance overview (same destination as the HOLD panel
-- button bounce in ChannelGroup.setMode). When not in authoring,
-- the handlers return nothing so the default chain navigation runs.
--
-- Routes through the Channels module so the per-channel-group
-- context switch happens (chain:exitSceneAuthoring alone wouldn't
-- activate sceneHoldContext).
local function _leaveAuthoringIfArmed(self)
  if self.activeAuthoringScene == nil then return false end
  local Channels = require "Channels"
  Channels.leaveSceneAuthoring()
  return true
end

-- Egress mappings (revised after hardware bench 2026-06-01):
--   plain UP at Root  -> leave authoring (no sub-chain above to
--                        pop into, so UP would otherwise no-op;
--                        repurposing for "back out to Performance"
--                        matches user-edit semantics where UP at
--                        root leaves the edit view)
--   shift+UP from any -> leave authoring (escape hatch from any
--                        sub-chain depth; Patch/Branch don't see
--                        this because their unshifted UP pops
--                        them up first)
-- CANCEL is intentionally NOT mapped here: it is owned by the
-- focused control's readout::restore (the "revert this value to
-- where it was when I entered focus" gesture) and is absolutely
-- needed during authoring. Same logic for ZERO.
function Root:upReleased(shifted)
  if _leaveAuthoringIfArmed(self) then return true end
end

function Root:enterScopeView()
  local xpath = self:getXPathToSelection()
  self.scopeView:refresh()
  self.scopeView:select(xpath)
end

function Root:leaveScopeView()
  if self.scopeView:selectionChanged() then
    local xpath = self.scopeView:getXPath()
    if xpath then
      self:navigateToXPath(xpath)
    end
  end
end

function Root:releaseResources()
  self.pinView:releaseResources()
  if self.sceneView then
    self.sceneView:releaseResources()
  end
  self.scopeView:releaseResources()
  Chain.releaseResources(self)
end

return Root

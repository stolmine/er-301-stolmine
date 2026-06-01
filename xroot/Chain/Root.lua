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
  local t = Chain.serialize(self)
  t.pinView = self.pinView:serialize()
  -- Only serialize scene state if SceneView has actually been
  -- created (user enabled scene mode at some point). Lazy init
  -- means most users get nothing extra written to their presets.
  if self.sceneView then
    t.sceneView = self.sceneView:serialize()
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
  self._sceneTargetParams   = {}
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

  _walkAllUnits(self, function(unit)
    if not unit.controls then return end
    local unitKey = unit:getInstanceKey()
    self._sceneTargetParams[unitKey] = {}
    for ctrlId, control in pairs(unit.controls) do
      if control.enterSceneMode then
        local baseVal  = control:getSceneBaseValue()
        local deltaVal = scene:getDelta(unitKey, ctrlId) or baseVal
        local targetParam = app.Parameter(ctrlId .. "_scene", deltaVal)
        self._sceneTargetParams[unitKey][ctrlId] = targetParam
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
        local targetVal = control:getSceneTargetValue()
        local baseVal   = control:getSceneBaseValue()
        if math.abs(targetVal - baseVal) > 1e-6 then
          scene:setDelta(unitKey, ctrlId, targetVal)
        else
          scene:setDelta(unitKey, ctrlId, nil)
        end
        control:exitSceneMode()
      end
    end
  end)

  self.activeAuthoringScene = nil
  self.activeAuthoringIdx   = nil
  self._sceneTargetParams   = nil
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
  self._sceneMorph = morph

  local gb = app.GainBias()
  gb:setName(self.title .. ".SceneCV")
  self._sceneCVGainBias = gb

  -- Branch wrapping the GainBias input. Used by Performance view
  -- M1 dive so user can insert CV-source units (LFO, S&H, etc.).
  -- Output flows: branch units -> gb.In -> gb.Out -> morpher.mCV.
  self._sceneCVBranch = Branch {
    title = self.title,
    subTitle = "scene-cv",
    depth = self.depth + 1,
    channelCount = 1,
    leftDestination = gb:getInput("In"),
    leftOutObject = gb,
    leftOutletName = "Out",
    unit = self,  -- Branch uses this for getRootChain
  }

  -- Wire GainBias.Out into the morpher's CV inlet.
  app.AudioThread.connect(gb:getOutput("Out"), morph:getInput("CV"))

  -- Per-control base Parameter snapshots, refreshed every engage.
  -- Map: [unitKey][ctrlId] = app.Parameter holding the user-mode
  -- value at the moment scene mode was engaged.
  self._sceneBaseParams = {}

  -- Audio-rate task that processes the GainBias then the morpher
  -- (process order = insertion order). Add/remove from
  -- AudioThread on engage/disengage.
  self._sceneTask = app.ObjectList(self.title .. ".SceneTask")

  return self._sceneMorph
end

function Root:getSceneCVBranch()
  self:_getOrBuildSceneMorph()
  return self._sceneCVBranch
end

function Root:getSceneCVGainBias()
  self:_getOrBuildSceneMorph()
  return self._sceneCVGainBias
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

-- Walk every delta-able control and add a 3-Parameter morpher item
-- per (audio target, sceneA endpoint, sceneB endpoint). Endpoints
-- resolve to the scene's persistent Parameter when the scene has
-- a delta for that control, else the chain's base Parameter
-- (= "no delta" endpoint, stays at the user-mode value snapshot).
-- Crossfader role of kEndpointBase (0) means "this side is base"
-- so both endpoints become baseParam = zero movement on that side.
function Root:_buildSceneMorphItems()
  if self.sceneView == nil then return end
  local morph = self._sceneMorph
  if morph == nil then return end

  local aIdx = self.sceneView:getCrossfaderA()
  local bIdx = self.sceneView:getCrossfaderB()
  local sceneA = (aIdx and aIdx > 0) and self.sceneView:getScene(aIdx) or nil
  local sceneB = (bIdx and bIdx > 0) and self.sceneView:getScene(bIdx) or nil

  _walkAllUnits(self, function(unit)
    if not unit.controls then return end
    local unitKey = unit:getInstanceKey()
    for ctrlId, control in pairs(unit.controls) do
      if control.getSceneAudioParam then
        local audioParam = control:getSceneAudioParam()
        local baseParam  = self:_getOrCreateBaseParam(unitKey, ctrlId)
        local baseVal    = control:getSceneBaseValue()

        local aParam
        if sceneA and sceneA:hasDelta(unitKey, ctrlId) then
          aParam = sceneA:getOrCreateParam(unitKey, ctrlId, baseVal)
        else
          aParam = baseParam
        end

        local bParam
        if sceneB and sceneB:hasDelta(unitKey, ctrlId) then
          bParam = sceneB:getOrCreateParam(unitKey, ctrlId, baseVal)
        else
          bParam = baseParam
        end

        morph:add(audioParam, aParam, bParam)
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

  -- Refresh base snapshots. Capture each control's current
  -- target() now -- this is the "user just left user-edit"
  -- baseline that "no delta" endpoints fall back to.
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

  self._sceneTask:lock()
  self._sceneTask:clear()
  self._sceneMorph:clear()
  self:_buildSceneMorphItems()
  self._sceneTask:add(self._sceneCVGainBias)
  self._sceneTask:add(self._sceneMorph)
  self._sceneTask:unlock()

  app.AudioThread.addTask(self._sceneTask, 0)
  self._sceneEngaged = true
end

-- Disengage. Tear down the audio-rate scheduling and drop the
-- live Parameters from each scene (the on-disk float deltas
-- survive). Base Parameters stay -- cheap, reused next engage.
function Root:disengageSceneMorph()
  if not self._sceneEngaged then return end

  app.AudioThread.removeTask(self._sceneTask)

  self._sceneTask:lock()
  self._sceneTask:clear()
  self._sceneTask:unlock()

  if self._sceneMorph then
    self._sceneMorph:clear()
  end

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
-- A/B roles or adds/removes a scene. Weight (mWeight) preserved.
function Root:rebuildSceneMorph()
  if not self._sceneEngaged then return end
  self._sceneTask:lock()
  self._sceneMorph:clear()
  self:_buildSceneMorphItems()
  self._sceneTask:unlock()
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

function Root:upReleased(shifted)
  if _leaveAuthoringIfArmed(self) then return true end
end

function Root:cancelReleased(shifted)
  if _leaveAuthoringIfArmed(self) then return true end
end

function Root:zeroReleased()
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

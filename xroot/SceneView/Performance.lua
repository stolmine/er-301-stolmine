-- Performance view for scene mode. SpottedStrip-based since `.25`:
-- the chain-edit + quicksave convention. SpottedStrip's C++ widget
-- (od/graphics/spotted/SpottedStrip.cpp) handles the camera pan
-- animation natively (0.20 lerp, 2 px snap), so we don't manage
-- scroll offsets by hand. Section auto-sizes to its controls; the
-- strip keeps the focused control in view.
--
-- Layout (left to right in one Section):
--   M1Control                          (CV / bias fader)
--   SceneSlotControl(sceneIdx) x N     (1 per scene, 1 <= N <= 16)
--   PlusControl                        (visible when N < 16)
--
-- Action targets exposed via Control:callUp (the SpottedStrip's
-- Window:* method dispatch):
--   addScene, deleteScene, renameScene, duplicateScene,
--   toggleEndpoint, enterAuthoring, diveSceneCV.
--
-- Phase-1 lifecycle: Channels.Group.enterScenePerformance() shows
-- the view; SceneView leavePerformanceView destroys it. Class
-- shape matches the old Window subclass (sceneView arg in init).

local app = app
local Class = require "Base.Class"
local SpottedStrip = require "SpottedStrip"
local Section = require "SpottedStrip.Section"
local Signal = require "Signal"

local M1Control            = require "SceneView.M1Control"
local SceneSelectorControl = require "SceneView.SceneSelectorControl"
local SceneSlotControl     = require "SceneView.SceneSlotControl"
local PlusControl          = require "SceneView.PlusControl"

local Performance = Class {}
Performance:include(SpottedStrip)

function Performance:init(sceneView)
  SpottedStrip.init(self)
  self:setClassName("SceneView.Performance")
  self.sceneView = sceneView
  self.chain     = sceneView.chain

  -- Live morpher Weight Parameter (post-CV crossfade weight in
  -- [-1, +1]) drives every SceneSlotControl's bias-fill indicator.
  -- Pulled once at init.
  self._weightParam = nil
  if self.chain and self.chain.getSceneMorph then
    local morph = self.chain:getSceneMorph()
    if morph then self._weightParam = morph:getParameter("Weight") end
  end

  -- Build the single Section. sectionNoBorder so the section
  -- itself doesn't draw a frame around the strip; each Control's
  -- TextPanel has its own border per the quicksave convention.
  self:disableSelection()
  self.section = Section(app.sectionNoBorder)
  self.section:addView("default")
  self:appendSection(self.section)

  -- M1 (morph) first.
  self.m1Control = M1Control(self.chain)
  self.section:addControl("default", self.m1Control)

  -- M2 (A) and M3 (B): v1.1 per-role scene selectors. Render
  -- the arbiter Bias as a scene-name fader; encoder + decimal
  -- keyboard write arbiter.Bias and (during 5.4) also mirror
  -- through SceneView:setCrossfaderA/B via syncSceneCrossfader
  -- so the v1.0 morpher path keeps audio in sync.
  self.selectorControls = {}
  for _, role in ipairs({"A", "B"}) do
    local sel = SceneSelectorControl(self.chain, role, sceneView)
    self.section:addControl("default", sel)
    self.selectorControls[role] = sel
  end

  -- One SceneSlotControl per existing scene.
  self.slotControls = {}
  for i = 1, sceneView:getSceneCount() do
    local scene = sceneView:getScene(i)
    local slot  = SceneSlotControl(i, scene, self._weightParam)
    self.section:addControl("default", slot)
    self.slotControls[i] = slot
  end

  -- PlusControl at the right edge if room remains.
  self.plusControl = PlusControl()
  if sceneView:getSceneCount() < sceneView:getMaxScenes() then
    self.section:addControl("default", self.plusControl)
    self._plusInSection = true
  else
    self._plusInSection = false
  end

  -- Build the view + select M1 by default.
  self.section:rebuildView("default")
  self:setSelection(self.section, "default",
                    self.m1Control:getSpotValue(1, "handle"))
  self:enableSelection()

  -- A/B chip + bias-fill role per slot.
  self:_refreshSlotRoles()

  -- Subscribe to each role's scene-CV branch contentChanged so
  -- the dive owners' mod button + scope outlet update when the
  -- user wires in or removes a CV source. Track each branch so
  -- :contentChanged(branch) can route the signal to the right
  -- control.
  self._sceneCVBranches = {}
  if self.chain and self.chain.getSceneCVBranch then
    for _, entry in ipairs({
      {role = "morph", control = self.m1Control},
      {role = "A",     control = self.selectorControls.A},
      {role = "B",     control = self.selectorControls.B},
    }) do
      local branch = self.chain:getSceneCVBranch(entry.role)
      if branch then
        self._sceneCVBranches[branch] = entry.control
        branch:subscribe("contentChanged", self)
        entry.control:contentChanged()
      end
    end
  end
end

------------------------------------------------------------
-- Signal callbacks

function Performance:contentChanged(branch)
  local control = self._sceneCVBranches and self._sceneCVBranches[branch]
  if control then control:contentChanged() end
end

------------------------------------------------------------
-- Shift state propagation

function Performance:shiftPressed()
  self.shiftHeld = true
  self.shiftUsed = false
  return true
end

-- Tap-shift toggles the currently-selected SceneSlotControl's
-- shifted sub-display state (per-control habitat-pattern A). M1
-- and Plus controls don't have a second mode, so the toggle is
-- only applied to slot controls.
function Performance:shiftReleased()
  if self.shiftHeld and not self.shiftUsed then
    local section, viewName, spotHandle = self:getSelection()
    if section then
      local view = section:getView(viewName)
      local spot = view and view:getSpotByHandle(spotHandle)
      local control = spot and spot:getControl()
      if control and control.setShifted then
        control:setShifted(not control.shifted)
      end
    end
  end
  self.shiftHeld = false
  return true
end

-- Any encoder touch during shift hold suppresses the tap-toggle
-- (Decision 1 B).
function Performance:encoder(change, shifted)
  if self.shiftHeld then self.shiftUsed = true end
  return SpottedStrip.encoder(self, change, shifted)
end

------------------------------------------------------------
-- Action targets invoked via Control:callUp.

function Performance:addScene()
  local scene, idx = self.sceneView:addScene()
  if scene == nil then return true end  -- max scenes reached
  self:_rebuildSceneMorph()
  self:_insertSlotControlForScene(idx, scene)
  -- Move selection to the just-created scene.
  local slot = self.slotControls[idx]
  if slot then
    self:setSelection(self.section, "default",
                      slot:getSpotValue(1, "handle"))
  end
  return true
end

function Performance:deleteScene(sceneIdx)
  local scene = self.sceneView:getScene(sceneIdx)
  if scene == nil then return true end
  local Settings = require "Settings"
  if Settings.get("confirmSceneDelete") == "no" then
    self:_doDeleteScene(sceneIdx)
    return true
  end
  local Verification = require "Verification"
  local dlg = Verification.Sub(
    string.format("Delete scene %d (%s)?", sceneIdx, scene:getName()),
    "")
  dlg:subscribe("done", function(ans)
    if ans then self:_doDeleteScene(sceneIdx) end
  end)
  dlg:show()
  return true
end

function Performance:renameScene(sceneIdx)
  local scene = self.sceneView:getScene(sceneIdx)
  if scene == nil then return true end
  local Keyboard = require "Keyboard"
  local kb = Keyboard("Rename scene", scene:getName(), true, "NamingStuff")
  kb:subscribe("done", function(text)
    if text and text ~= "" then
      scene:setName(text)
      local slot = self.slotControls[sceneIdx]
      if slot then slot:setScene(scene, slot.crossfaderRole) end
      -- If the renamed scene is currently A or B, the M2/M3
      -- fader label needs to repaint.
      self:_refreshSelectorLabels()
    end
  end)
  kb:show()
  return true
end

function Performance:duplicateScene(sceneIdx)
  local source = self.sceneView:getScene(sceneIdx)
  if source == nil then return true end
  if source._syncDeltasFromParams then source:_syncDeltasFromParams() end
  -- Name collision avoidance: source name + " N" with the lowest N
  -- starting at 2 that doesn't collide. Bails after 99.
  local srcName = source:getName() or "scene"
  local nameInUse = {}
  for i = 1, self.sceneView:getSceneCount() do
    local s = self.sceneView:getScene(i)
    if s then nameInUse[s:getName()] = true end
  end
  local newName = srcName
  if nameInUse[srcName] then
    for n = 2, 99 do
      local candidate = string.format("%s %d", srcName, n)
      if not nameInUse[candidate] then
        newName = candidate
        break
      end
    end
  end
  local newScene, newIdx = self.sceneView:addScene(newName)
  if newScene == nil then return true end
  for unitKey, perUnit in pairs(source.deltas) do
    for ctrlId, value in pairs(perUnit) do
      newScene:setDelta(unitKey, ctrlId, value)
    end
  end
  self:_rebuildSceneMorph()
  self:_insertSlotControlForScene(newIdx, newScene)
  local slot = self.slotControls[newIdx]
  if slot then
    self:setSelection(self.section, "default",
                      slot:getSpotValue(1, "handle"))
  end
  return true
end

function Performance:toggleEndpoint(sceneIdx, role)
  local a = self.sceneView:getCrossfaderA()
  local b = self.sceneView:getCrossfaderB()
  if role == "A" then
    if a == sceneIdx then
      self.sceneView:setCrossfaderA(0)
    else
      if b == sceneIdx then self.sceneView:setCrossfaderB(0) end
      self.sceneView:setCrossfaderA(sceneIdx)
    end
  else
    if b == sceneIdx then
      self.sceneView:setCrossfaderB(0)
    else
      if a == sceneIdx then self.sceneView:setCrossfaderA(0) end
      self.sceneView:setCrossfaderB(sceneIdx)
    end
  end
  self:_rebuildSceneMorph()
  self:_refreshSlotRoles()
  -- 5.4 mirror chip-tap writes into the arbiter Bias so M2/M3
  -- faders track. Dropped in 5.5 when the chip tap will write
  -- the arbiter directly and the SceneView crossfader becomes
  -- a computed read.
  self:_syncArbitersFromCrossfaders()
  return true
end

function Performance:enterAuthoring(sceneIdx)
  local Channels = require "Channels"
  Channels.enterSceneAuthoring(sceneIdx)
  return true
end

function Performance:diveSceneCV(role)
  if not (self.chain and self.chain.getSceneCVBranch) then return true end
  local branch = self.chain:getSceneCVBranch(role or "morph")
  if branch and branch.show then branch:show() end
  return true
end

-- 5.4 transitional dual-write path. SceneSelectorControl writes
-- arbiter.Bias for visual + state-machine tracking; this mirror
-- also updates the v1.0 SceneView crossfader so the morpher
-- (still kVee4) keeps audio in sync. 5.5 will remove this: the
-- morpher will consume arbiter.Out directly and the SceneView
-- crossfader becomes computed from round(arbiter.out).
function Performance:syncSceneCrossfader(role, idx)
  if role ~= "A" and role ~= "B" then return true end
  idx = math.max(0, math.min(idx or 0, self.sceneView:getMaxScenes()))
  if role == "A" then
    if self.sceneView:getCrossfaderA() ~= idx then
      self.sceneView:setCrossfaderA(idx)
      self:_rebuildSceneMorph()
      self:_refreshSlotRoles()
    end
  else
    if self.sceneView:getCrossfaderB() ~= idx then
      self.sceneView:setCrossfaderB(idx)
      self:_rebuildSceneMorph()
      self:_refreshSlotRoles()
    end
  end
  return true
end

------------------------------------------------------------
-- Helpers

function Performance:_rebuildSceneMorph()
  if self.chain and self.chain.rebuildSceneMorph then
    self.chain:rebuildSceneMorph()
  end
end

function Performance:_doDeleteScene(sceneIdx)
  self.sceneView:removeScene(sceneIdx)
  self:_rebuildSceneMorph()
  self:_removeSlotControlForScene(sceneIdx)
end

-- Reset every slot control's A/B chip + bias-fill side from the
-- SceneView's current crossfader assignments.
function Performance:_refreshSlotRoles()
  local a = self.sceneView:getCrossfaderA()
  local b = self.sceneView:getCrossfaderB()
  for i, slot in pairs(self.slotControls) do
    local role
    if a == i then role = "A"
    elseif b == i then role = "B" end
    slot:setScene(self.sceneView:getScene(i), role)
  end
  self:_refreshSelectorLabels()
end

-- Push the v1.0 SceneView crossfader integer into the arbiter
-- Bias for each role, so M2/M3 faders track the chip-tap path
-- during 5.4. With kIndex semantics the arbiter Bias is
-- normalized [0, 1], so divide the integer crossfader idx by N
-- to get the matching fractional position. Also refreshes the
-- selector scene-name labels.
function Performance:_syncArbitersFromCrossfaders()
  if not self.selectorControls then return end
  if not (self.chain and self.chain.getSceneArbiter) then return end
  local n = self.sceneView:getSceneCount()
  local values = {
    A = self.sceneView:getCrossfaderA(),
    B = self.sceneView:getCrossfaderB(),
  }
  for role, idx in pairs(values) do
    local arb = self.chain:getSceneArbiter(role)
    if arb then
      local bias = (n > 0) and (idx / n) or 0.0
      arb:hardSetBias(bias)
    end
  end
  self:_refreshSelectorLabels()
end

-- Refresh the ModeSelector-style scene-name label on each
-- SceneSelectorControl. Called after scene rename, scene
-- add/delete, and any arbiter Bias update.
function Performance:_refreshSelectorLabels()
  if not self.selectorControls then return end
  for _, sel in pairs(self.selectorControls) do
    if sel._updateLabel then sel:_updateLabel() end
  end
end

-- Insert a fresh SceneSlotControl at sceneIdx into the section's
-- view, just before the PlusControl. Section view rebuild
-- preserves selection via the disable / enable bracket.
function Performance:_insertSlotControlForScene(sceneIdx, scene)
  self:disableSelection()
  -- Take the plus control out of the view (if present) so we can
  -- re-append it after the new slot.
  local view = self.section:getView("default")
  if self._plusInSection then
    view:removeControl(self.plusControl)
    self.section:unregisterControl(self.plusControl)
    self._plusInSection = false
  end
  local slot = SceneSlotControl(sceneIdx, scene, self._weightParam)
  self.section:addControl("default", slot)
  self.slotControls[sceneIdx] = slot

  if self.sceneView:getSceneCount() < self.sceneView:getMaxScenes() then
    self.section:addControl("default", self.plusControl)
    self._plusInSection = true
  end
  self.section:rebuildView("default")
  -- Refresh roles since the new scene may push the existing A/B
  -- mapping around (it doesn't, but defensive).
  self:_refreshSlotRoles()
  self:enableSelection()
end

-- Remove the SceneSlotControl for sceneIdx, then re-index every
-- higher slot's sceneIdx down by one (since SceneView:removeScene
-- shifts indices). Rebuild view so the section reflects the new
-- order. Restores selection to the next-lower remaining slot if
-- we just deleted the focused one.
function Performance:_removeSlotControlForScene(sceneIdx)
  self:disableSelection()
  local view = self.section:getView("default")

  -- Unhook the doomed slot.
  local doomed = self.slotControls[sceneIdx]
  if doomed then
    view:removeControl(doomed)
    self.section:unregisterControl(doomed)
    self.slotControls[sceneIdx] = nil
  end

  -- Re-key higher slots down by one + tell each its new sceneIdx
  -- so callUp args carry the right value.
  local maxIdx = 0
  for i, slot in pairs(self.slotControls) do
    if i > maxIdx then maxIdx = i end
  end
  for i = sceneIdx + 1, maxIdx do
    local slot = self.slotControls[i]
    if slot then
      slot.sceneIdx = i - 1
      self.slotControls[i - 1] = slot
      self.slotControls[i] = nil
    end
  end

  -- "+" placeholder may have just become available again if we
  -- were at the cap; re-attach if so.
  if not self._plusInSection
     and self.sceneView:getSceneCount() < self.sceneView:getMaxScenes() then
    self.section:addControl("default", self.plusControl)
    self._plusInSection = true
  end

  self.section:rebuildView("default")
  self:_refreshSlotRoles()

  -- If the selection lost its control, fall back to the next-
  -- lower slot (or M1 if no slots remain).
  local section, viewName, spotHandle = self:getSelection()
  if section == nil then
    self:setSelection(self.section, "default",
                      self.m1Control:getSpotValue(1, "handle"))
  end
  self:enableSelection()
end

------------------------------------------------------------
-- Lifecycle gestures

function Performance:homeReleased()
  self:setSelection(self.section, "default",
                    self.m1Control:getSpotValue(1, "handle"))
  return true
end

function Performance:upReleased(shifted)
  -- Default behavior: SpottedStrip Window.upReleased closes the
  -- view. M1Control's focus state is handled inside M1Control's
  -- own upReleased via grabbed focus when the bias readout is
  -- focused; that intercepts before we get here.
  return false
end

return Performance

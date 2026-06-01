local app = app
local Class = require "Base.Class"
local Object = require "Base.Object"
local Context = require "Base.Context"
local RootChain = require "Chain.Root"

local names = {
  "OUT1",
  "OUT2",
  "OUT3",
  "OUT4"
}

local ChannelGroup = Class {}
ChannelGroup:include(Object)

function ChannelGroup:init(left, right)
  self:setClassName("Channels.Group")
  app.ChannelLEDs_steady(left - 1)
  local leftName = names[left]
  local title, channelCount
  local leftDestination = app.getExternalDestination(leftName)
  local rightDestination
  if right then
    local rightName = names[right]
    title = string.format("%s + %s", leftName, rightName)
    rightDestination = app.getExternalDestination(rightName)
    channelCount = 2
    app.ChannelLEDs_steady(right - 1)
  else
    title = leftName
    channelCount = 1
  end

  self:setInstanceName(title)
  local chain = RootChain {
    title = title,
    depth = 1,
    leftDestination = leftDestination,
    rightDestination = rightDestination,
    channelCount = channelCount
  }

  self.chain = chain
  self.editContext = Context(chain.title .. " edit", chain)
  self.scopeContext = Context(chain.title .. " scope", chain.scopeView)
  self.sequencerContext = Context(chain.title .. " sequencer", chain.sequencerView)
  self.holdContext = Context(chain.title .. " hold", chain.pinView)
  -- sceneHoldContext is built lazily on first scene-mode entry
  -- via _getSceneHoldContext(). This keeps SceneView + Performance
  -- view init completely off the boot path; chains never visited
  -- in scene mode pay zero cost.
  self.activeContext = self.editContext
  self.mode = "unknown"
  self.scopeSubView = "scope"   -- "scope" | "sequencer" (sub-views of scope mode)
  self.left = left
  self.right = right

  chain:start()
  chain:subscribe("contentChanged", self)
end

function ChannelGroup:contentChanged()
  if self.mode == "scope" then
    self.chain:enterScopeView()
  end
end

-- Lazy-build the scene-mode hold context on first entry. Keeps
-- Performance view init entirely off the boot path.
function ChannelGroup:_getSceneHoldContext()
  if self.sceneHoldContext == nil then
    local sceneView = self.chain:getSceneView()
    self.sceneHoldContext = Context(self.chain.title .. " scene",
                                     sceneView:getPerformanceView())
  end
  return self.sceneHoldContext
end

-- Dive from the Performance view into per-scene authoring. The
-- authoring view IS the chain's existing editContext (no separate
-- mirror window). chain:enterSceneAuthoring arms every delta-able
-- control by swapping its widget's control parameter to a
-- per-scene target param (visual: value + target marker like OG
-- hold-mode pinning). The user navigates / edits in the normal
-- edit view; encoder writes go to the per-scene targets.
function ChannelGroup:enterSceneAuthoring(sceneIdx)
  local sceneView = self.chain:getSceneView()
  if sceneView:getScene(sceneIdx) == nil then return end
  self.chain:enterSceneAuthoring(sceneView, sceneIdx)
  self:setActiveContext(self.editContext)
end

-- Return from authoring back to the Performance view. Captures
-- each armed control's target value into the scene's delta map
-- (only when differs from base) and restores the widgets.
function ChannelGroup:leaveSceneAuthoring()
  self.chain:exitSceneAuthoring()
  self:setActiveContext(self:_getSceneHoldContext())
end

function ChannelGroup:show()
  if not self.activeContext.visible then
    local Application = require "Application"
    Application.setVisibleContext(self.activeContext)
  end
end

function ChannelGroup:setActiveContext(context)
  local visible = self.activeContext.visible
  self.activeContext = context
  if visible then
    self:show()
  end
end

function ChannelGroup:setMode(mode)
  if mode == self.mode then
    -- Special case: pressing HOLD while inside scene authoring
    -- returns to the Performance view (a "back out one level"
    -- gesture). Without this the press is a no-op and the user
    -- has no panel-button way back from authoring.
    if mode == "hold" and self.chain.activeAuthoringScene then
      self:leaveSceneAuthoring()
    end
    return
  end
  if mode == "edit" then
    if self.mode == "scope" then
      self.chain:leaveScopeView()
    else
      self.chain:leaveHoldMode()
      if self.chain.sceneView then
        self.chain.sceneView:leavePerformanceView()
      end
      -- Safety: any mode change out of scene authoring captures
      -- pending deltas and restores widgets, so the user doesn't
      -- silently leave the chain controls armed.
      if self.chain.activeAuthoringScene then
        self.chain:exitSceneAuthoring()
      end
      -- The scene morpher is NOT disengaged when transitioning
      -- to edit mode. Once scene mode is engaged for the session,
      -- the morpher continues to drive audio in user-edit too --
      -- the user-edit widget swap (modulated display) routes
      -- their encoder edits to baseParam, the morpher reads
      -- base + scene to compute audio, so user-edit reflects
      -- the crossfader position without losing the user's base
      -- biases. Mode toggle is pure navigation.
      -- Disengage happens on chain destroy (or via an explicit
      -- sceneMode-off setting flip; not wired yet).
    end
    self:setActiveContext(self.editContext)
  elseif mode == "scope" then
    self.chain:enterScopeView()
    -- Honor current scope sub-view: scope (default) or sequencer.
    if self.scopeSubView == "sequencer" then
      self:setActiveContext(self.sequencerContext)
    else
      self:setActiveContext(self.scopeContext)
    end
  elseif mode == "hold" then
    -- Scene mode replaces hold mode entirely when the admin
    -- setting is on; otherwise legacy PinView hold mode runs.
    -- Checked on each entry so the setting flip is live.
    local Settings = require "Settings"
    if Settings.get("sceneMode") == "on" then
      self.chain:getSceneView():enterPerformanceView()
      -- Engage the crossfader morpher: walker arms per-control
      -- base snapshots and morpher items per current A/B
      -- assignments, schedules audio-rate processing.
      if self.chain.engageSceneMorph then
        self.chain:engageSceneMorph()
      end
      self:setActiveContext(self:_getSceneHoldContext())
    else
      self.chain:enterHoldMode()
      self:setActiveContext(self.holdContext)
    end
  end
  self.mode = mode
end

-- Toggle between the scope and sequencer sub-views inside scope mode.
-- Called from ScopeView and Sequencer.GridView on shift+ENTER.
-- No-op when not currently in scope mode (callers shouldn't reach here
-- otherwise, since both views only exist as children of scope contexts).
function ChannelGroup:toggleSequencerSubView()
  if self.mode ~= "scope" then
    return
  end
  if self.scopeSubView == "sequencer" then
    self.scopeSubView = "scope"
    self:setActiveContext(self.scopeContext)
  else
    self.scopeSubView = "sequencer"
    self:setActiveContext(self.sequencerContext)
  end
end

function ChannelGroup:mute()
  self.chain:mute()
  self.chain:setSubTitle("muted")
  app.ChannelLEDs_flash(self.left - 1)
  if self.right then
    app.ChannelLEDs_flash(self.right - 1)
  end
end

function ChannelGroup:unmute()
  self.chain:unmute()
  self.chain:clearSubTitle()
  app.ChannelLEDs_steady(self.left - 1)
  if self.right then
    app.ChannelLEDs_steady(self.right - 1)
  end
end

function ChannelGroup:toggleMute()
  local Overlay = require "Overlay"
  local chain = self.chain
  if chain:isMuted() then
    Overlay.flashMainMessage(chain.title .. ": Mute Off")
    self:unmute()
  else
    self:mute()
    Overlay.flashMainMessage(chain.title .. ": Mute On")
  end
end

function ChannelGroup:start()
  self.chain:start()
end

function ChannelGroup:stop()
  self.chain:stop()
end

function ChannelGroup:clear()
  self.chain:clear()
end

function ChannelGroup:destroy()
  self.chain:unsubscribe("contentChanged", self)
  self.chain:mute()
  self.chain:stop()
  -- Disengage the scene morpher (if engaged) so each delta-able
  -- control's modulated-display state is torn down and audio
  -- params are restored before the chain releases its resources.
  if self.chain.disengageSceneMorph then
    self.chain:disengageSceneMorph()
  end
  self.chain:releaseResources()
  self.editContext:destroy()
  self.scopeContext:destroy()
  self.sequencerContext:destroy()
  self.holdContext:destroy()
end

function ChannelGroup:serialize()
  local t = self.chain:serialize()
  -- Used only by Channels module
  t.isMuted = self.chain:isMuted()
  return t
end

function ChannelGroup:deserialize(t)
  self.chain:deserialize(t)
  self.chain.stopCount = 1
end

return ChannelGroup

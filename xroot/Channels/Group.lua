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
  -- Two hold-mode contexts: the legacy pinView path and the new
  -- scene Performance path. setMode("hold") picks between them
  -- via Settings.sceneMode. The scene context lazy-instantiates
  -- the Performance view on first request, so chains without
  -- scenes pay no UI cost when scene mode is off.
  self.holdContext = Context(chain.title .. " hold", chain.pinView)
  self.sceneHoldContext = Context(chain.title .. " scene",
                                   chain.sceneView:getPerformanceView())
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
    return
  end
  if mode == "edit" then
    if self.mode == "scope" then
      self.chain:leaveScopeView()
    else
      self.chain:leaveHoldMode()
      self.chain.sceneView:leavePerformanceView()
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
    -- Route to scene Performance view when scene mode is on;
    -- legacy pinView path otherwise. Setting checked each entry
    -- so the user can flip the preference live without rebooting.
    local Settings = require "Settings"
    if Settings.get("sceneMode") == "on" then
      self.chain.sceneView:enterPerformanceView()
      self:setActiveContext(self.sceneHoldContext)
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

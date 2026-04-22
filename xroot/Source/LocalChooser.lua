local app = app
local Env = require "Env"
local Class = require "Base.Class"
local Window = require "Base.Window"
local Encoder = require "Encoder"
local ply = app.SECTION_PLY

local function createNode(o, type)
  return {
    o = o,
    type = type
  }
end

local function lightChannel(i)
  app.ChannelLEDs_off(0)
  app.ChannelLEDs_off(1)
  app.ChannelLEDs_off(2)
  app.ChannelLEDs_off(3)
  if i then
    app.ChannelLEDs_on(i - 1)
  end
end

local LocalChooser = Class {}
LocalChooser:include(Window)

function LocalChooser:init(ring, chain, currentSource)
  Window.init(self)
  self:setClassName("Source.LocalChooser")
  self.ring = ring
  local Channels = require "Channels"
  self.channel = Channels.selected()
  chain = chain:getRootChain()
  self.chain = chain
  self.nodes = {}

  -- Layout matches vanilla: chain overview takes the leftmost 5 plies,
  -- miniscope the rightmost 1 ply. When a multi-out unit is focused, the
  -- [X/Y label] indicator is drawn on top of the scope's waveform (M6 cycles
  -- through sub-outs). Per docs/planning/redesign/07-multi-output-units.md.
  local overview = app.ChainOverview(0, 0, 256 - ply, 64)
  self.ptr = overview
  self:addMainGraphic(overview)
  self:setMainCursorController(overview)
  self.encoderState = Encoder.Fine
  overview:setDepthFirstNavigation(true)
  self.scope = app.MiniScope(256 - ply, 0, ply, 64)
  -- self.scope:setBorder(1)
  -- self.scope:setCornerRadius(3,3,3,3)
  self.scope:setOpaque(true)
  self.scope:showStatus(true)
  self:addMainGraphic(self.scope)

  -- Sub-out indicator: two small labels overlaid on the scope's ply when a
  -- multi-out unit is focused. Top: sub-out label. Bottom: X/Y position.
  -- No background — the labels read on top of the waveform.
  self.subOutLabel = app.Label("", 10)
  self.subOutLabel:setJustification(app.justifyCenter)
  self.subOutLabel:setCenter(256 - ply / 2, 40)
  self:addMainGraphic(self.subOutLabel)
  self.subOutLabel:hide()

  self.subOutXY = app.Label("", 10)
  self.subOutXY:setJustification(app.justifyCenter)
  self.subOutXY:setCenter(256 - ply / 2, 16)
  self:addMainGraphic(self.subOutXY)
  self.subOutXY:hide()

  -- Currently focused multi-out unit (nil if focused source isn't multi-out).
  self.focusedMultiOut = nil
  -- 1-based index of currently selected sub-out within the focused multi-out.
  self.currentSubOut = 1

  self:loadChainHelper(self.chain)
  overview:setEmptyString(self.chain.title .. ": No units.")
  overview:rebuild()
  if currentSource and currentSource.type == "local" then
    local id = self:findLocalSource(currentSource)
    if id then
      overview:select(id)
    end
  else
    local xpath = chain:getXPathToSelection()
    overview:select(xpath)
  end
  self:onSelectionChanged()
end

function LocalChooser:findLocalSource(src)
  local o = src.object
  for id, node in pairs(self.nodes) do
    if node.o == o then
      return id
    end
  end
end

function LocalChooser:getXPath()
  local xpath = app.XPath()
  self.ptr:fillXPath(xpath, self.ptr:selected())
  return xpath
end

function LocalChooser:loadUnitHelper(unit)
  -- Traverse each control in the scope or expanded view
  -- app.logInfo("%s:loadUnitHelper(%s)",self,unit)
  local view = unit:getView("scope") or unit:getView("expanded")
  if view == nil then
    return
  end
  local overview = self.ptr
  for i, control in ipairs(view.controls) do
    if control.getPatch then
      local patch = control:getPatch()
      if patch then
        local name = control:getInstanceName() or patch.name
        local id = overview:startPatch(name, i)
        self.nodes[id] = createNode(patch, "Patch")
        self:loadChainHelper(patch)
        overview:endPatch()
      end
    elseif control.getBranch then
      local branch = control:getBranch()
      if branch then
        local name = control:getInstanceName() or branch.name
        local id = overview:startBranch(name, i)
        self.nodes[id] = createNode(branch, "Branch")
        self:loadChainHelper(branch)
        overview:endBranch()
      end
    end
  end
end

function LocalChooser:loadChainHelper(chain)
  -- Depth-first traversal of chain and its descendants
  -- app.logInfo("%s:loadChainHelper(%s)",self,chain)
  local overview = self.ptr
  -- add sources if any
  if chain.getInputSource then
    local leftSource = chain:getInputSource(1)
    local rightSource = chain.channelCount > 1 and chain:getInputSource(2)
    if leftSource and rightSource then
      local name = leftSource:getDisplayName() .. "+" ..
                       rightSource:getDisplayName()
      local id = overview:addSource(name, 0)
      self.nodes[id] = createNode({
        leftSource,
        rightSource
      }, "StereoSource")
    elseif leftSource then
      local name = leftSource:getDisplayName()
      local id = overview:addSource(name, 0)
      self.nodes[id] = createNode(leftSource, "MonoSource")
    elseif rightSource then
      local name = rightSource:getDisplayName()
      local id = overview:addSource(name, 0)
      self.nodes[id] = createNode(rightSource, "MonoSource")
    end
  end
  -- add units if any
  for i = 1, chain:length() do
    local unit = chain:getUnit(i)
    local id = overview:startUnit(unit.mnemonic, unit.title, i)
    self.nodes[id] = createNode(unit, "Unit")
    self:loadUnitHelper(unit)
    overview:endUnit()
  end
end

local threshold = Env.EncoderThreshold.Default
function LocalChooser:encoder(change, shifted)
  if self.ptr:encoder(change, shifted, threshold) then
    self:onSelectionChanged()
  end
end

function LocalChooser:enterReleased()
  local id = self.ptr:selected()
  local node = self.nodes[id]
  if node then
    local Channels = require "Channels"
    local side = Channels.getSide()
    if node.type == "StereoSource" then
      self:choose(node.o[side])
    elseif node.type == "MonoSource" then
      self:choose(node.o)
    elseif self.focusedMultiOut and node.o == self.focusedMultiOut then
      -- Multi-out: source selection is the user's S3-chosen sub-out.
      -- Consumer-side L/R wiring is decided externally by the caller of
      -- :choose; user wires each sub-out separately for L and R if both are
      -- desired.
      self:choose(node.o:getOutputSource(self.currentSubOut))
    else
      self:choose(node.o:getOutputSource(side))
    end
  end
  return true
end

function LocalChooser:upReleased(shifted)
  if shifted then
    return true
  end
  if self.ptr:up() then
    self:onSelectionChanged()
  else
    self:cancelReleased(false)
  end
  return true
end

function LocalChooser:dialPressed(shifted)
  if shifted then
    return true
  end
  if self.encoderState == Encoder.Coarse then
    self.encoderState = Encoder.Fine
    self.ptr:setDepthFirstNavigation(true)
  else
    self.encoderState = Encoder.Coarse
    self.ptr:setDepthFirstNavigation(false)
  end
  Encoder.set(self.encoderState)
  return true
end

function LocalChooser:refresh()
  local xpath = self:getXPath()
  self.nodes = {}
  self.ptr:clear()
  self:loadChainHelper(self.chain)
  self.ptr:setEmptyString(self.chain.title .. ": No units.")
  self.ptr:rebuild()
  self.ptr:select(xpath)
  self:onSelectionChanged()
end

function LocalChooser:reseed(chain, channel)
  chain = chain:getRootChain()
  self.chain = chain
  self.channel = channel
  self.nodes = {}
  self.ptr:clear()
  self:loadChainHelper(chain)
  self.ptr:setEmptyString(chain.title .. ": No units.")
  self.ptr:rebuild()
  local xpath = chain:getXPathToSelection()
  self.ptr:select(xpath)
  self:onSelectionChanged()
end

function LocalChooser:selectReleased(i, shifted)
  if not shifted then
    local Channels = require "Channels"
    local newChain = Channels.getChain(i)
    if newChain then
      Channels.select(i)
      lightChannel(i)
      if newChain:getRootChain() ~= self.chain then
        self:reseed(newChain, i)
      else
        self.channel = i
        self:onSelectionChanged()
      end
      return true
    end
  end
  self:onSelectionChanged()
  return true
end

-- Returns the focused unit if it's multi-out (has subOutLabels with >1 entry),
-- else nil. Used to drive the [X/Y, label] indicator and S3 binding.
local function multiOutOf(node)
  if node and node.type == "Unit" then
    local unit = node.o
    if unit.subOutLabels and #unit.subOutLabels > 1 then
      return unit
    end
  end
  return nil
end

function LocalChooser:updateSubOutIndicator()
  local mo = self.focusedMultiOut
  if mo then
    local n = #mo.subOutLabels
    local i = self.currentSubOut
    self.subOutLabel:setText(mo.subOutLabels[i] or "")
    self.subOutXY:setText(string.format("%d/%d", i, n))
    self.subOutLabel:show()
    self.subOutXY:show()
  else
    self.subOutLabel:hide()
    self.subOutXY:hide()
  end
end

function LocalChooser:onSelectionChanged()
  local Channels = require "Channels"
  local side = Channels.getSide()
  local id = self.ptr:selected()
  local node = self.nodes[id]

  -- Detect focus on a multi-out unit. Reset sub-out index when focus moves
  -- to a different multi-out (semantic siblings shouldn't carry index across
  -- units of differing fan-out).
  local mo = multiOutOf(node)
  if mo ~= self.focusedMultiOut then
    self.focusedMultiOut = mo
    self.currentSubOut = 1
  end
  self:updateSubOutIndicator()

  if node then
    -- app.logInfo("%s",node)
    if node.type == "StereoSource" then
      self.scope:watchOutlet(node.o[side]:getOutlet())
    elseif node.type == "MonoSource" then
      self.scope:watchOutlet(node.o:getOutlet())
    elseif node.type == "Unit" then
      if mo then
        -- Multi-out focused: scope follows the currently selected sub-out
        -- so the user hears/sees what S3-cycling lands on.
        self.scope:watchOutlet(node.o:getOutput(self.currentSubOut))
      else
        self.scope:watchOutlet(node.o:getOutput(side))
      end
    elseif node.type == "Branch" then
      self.scope:watchOutlet(node.o:getOutput(side))
    elseif node.type == "Patch" then
      self.scope:watchOutlet(node.o:getMonitoringOutput(side))
    end
  end
end

function LocalChooser:mainReleased(i, shifted)
  if shifted then
    return true
  end
  if i == 6 then
    -- M6 sits under the scope ply. When a multi-out unit is focused, M6
    -- cycles through its sub-outs; the indicator overlay updates and the
    -- scope follows so the user auditions whichever sub-out enter would pick.
    if self.focusedMultiOut then
      local n = #self.focusedMultiOut.subOutLabels
      self.currentSubOut = (self.currentSubOut % n) + 1
      self:updateSubOutIndicator()
      local outlet = self.focusedMultiOut:getOutput(self.currentSubOut)
      if outlet then
        self.scope:watchOutlet(outlet)
      end
    end
    return true
  end
  self.ptr:selectColumn(i - 1, shifted)
  return true
end

function LocalChooser:onShow()
  if self.refreshNeeded then
    local Channels = require "Channels"
    local selectedChannel = Channels.selected()
    if selectedChannel and selectedChannel ~= self.channel then
      local newChain = Channels.getChain(selectedChannel)
      if newChain then
        self:reseed(newChain, selectedChannel)
      else
        self:refresh()
      end
    else
      self:refresh()
    end
    self.refreshNeeded = false
  end
  Encoder.set(self.encoderState)
  lightChannel(self.channel)
end

function LocalChooser:onHide()
  self.refreshNeeded = true
  Encoder.set(Encoder.Neutral)
  lightChannel(nil)
end

function LocalChooser:choose(src)
  return self.ring:choose(src)
end

function LocalChooser:homeReleased()
  return self.ring:homeReleased()
end

function LocalChooser:subReleased(i, shifted)
  return self.ring:subReleased(i, shifted)
end

function LocalChooser:cancelReleased(shifted)
  return self.ring:cancelReleased(shifted)
end

return LocalChooser

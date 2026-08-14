local Class = require "Base.Class"
local Branch = require "Chain.Branch"
local Persist = require "Persist"

local ControlBranch = Class {}
ControlBranch:include(Branch)

function ControlBranch:init(args)
  Branch.init(self, args)
  self:setInstanceName(args.id)
  self.id = args.id
  self.objects = args.objects or
                     app.logError("%s:init: objects are missing.", self)
  local task = app.ObjectList(args.id)
  for i, o in ipairs(args.objects) do
    task:add(o)
  end
  self.task = task
end

function ControlBranch:rename(name)
  self.id = name
  self:setTitle(self.title, name)
  self:setInstanceName(name)
end

function ControlBranch:onStart()
  Branch.onStart(self)
  -- Must add objects after branch so the objects are processed after the branch but before the parent chain.
  -- This is cleaner then registering the objects at depth-1.
  app.AudioThread.addTask(self.task, self.depth)
end

function ControlBranch:onStop()
  app.AudioThread.removeTask(self.task)
  Branch.onStop(self)
end

function ControlBranch:enable(soft)
  Branch.enable(self, soft)
  self.task:enable()
end

function ControlBranch:disable(soft)
  self.task:disable()
  Branch.disable(self, soft)
end

function ControlBranch:releaseResources()
  app.AudioThread.removeTask(self.task)
  self.task:clear()
  Branch.releaseResources(self)
end

function ControlBranch:isSerializationNeeded()
  return true
end

function ControlBranch:serialize()
  local t = Branch.serialize(self)
  t.id = self.control:getCustomizableValue("name")
  t.type = self.classType
  t.control = self.control:serialize()
  t.objects = Persist.serializeObjects(self.objects)
  -- [stol:promote-control-type-spec] `type` names the BRANCH, which is enough to
  -- rebuild the DSP object and not enough to rebuild the widget. A promoted
  -- subclass records its own class and the data its constructor needs, or it
  -- would come back from every load as a stock fader.
  local ControlClass = require "Unit.ControlClass"
  local name = ControlClass.nameOf(getmetatable(self.control))
  if name and not ControlClass.isStock(name) then
    t.controlClass = name
    t.controlArgs = ControlClass.dataArgs(self.control.defaults)
  end
  return t
end

-- [stol:promote-control-to-top-level] Control FIRST, objects SECOND.
--
-- These used to run the other way round, and it silently corrupted any control
-- whose customizations disturb its parameter. Pitch does: customize() rebuilds
-- the dial map and hands it to Readout::setMap, which rewrites the value. So a
-- customized Pitch control came back from every reload with a different offset
-- than it was saved with -- 0.5 saved, 0.3 restored -- because the value was
-- restored and then customize ran on top of it.
--
-- Reachable without promotion at all: Edit Controls -> Insert Pitch Control,
-- then edit its Tune Min / Tune Max. Promotion only made it easy to hit, by
-- copying the origin's customizations onto the macro.
--
-- This order is the right one on the merits regardless: customizations describe
-- how a control is DISPLAYED and parameters are the data, so when the two
-- disagree about a parameter the saved data has to win. Applying display first
-- and data second is what makes that true.
function ControlBranch:deserialize(t)
  if t.control then
    self.control:deserialize(t.control)
  end
  if t.objects then
    Persist.deserializeObjects(self.objects, nil, t.objects)
  end
  -- The value has just been restored underneath a widget that was built before
  -- it existed. A label derived from that value is now stale, and nothing else
  -- will notice.
  require("Unit.ControlClass").resyncDisplay(self.control)
  Branch.deserialize(self, t)
end

return ControlBranch

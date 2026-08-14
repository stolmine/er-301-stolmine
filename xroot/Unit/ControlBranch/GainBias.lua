local Class = require "Base.Class"
local ControlBranch = require "Unit.ControlBranch"
local GainBias = require "Unit.ViewControl.GainBias"

local GainBiasBranch = Class {
  classType = "GainBias",
  classDescription = "Gain/Bias",
  classPrefix = "gb"
}
GainBiasBranch:include(ControlBranch)

function GainBiasBranch:init(args)
  local id = args.id or app.logError("%s:init: id is missing.", self)
  local object = app.ParameterAdapter()
  args.leftDestination = object:getInput("In")
  args.leftOutObject = object
  args.leftOutletName = "Out"
  args.channelCount = 1
  args.objects = {
    object
  }
  ControlBranch.init(self, args)
  self:setClassName("Unit.ControlBranch.GainBias")

  -- [stol:promote-control-type-spec] Build the control as a SPECIFIC class when
  -- one is asked for, so a promoted subclass keeps its own widget instead of
  -- collapsing to a stock fader. args.controlArgs carries the class-specific
  -- data (a mode-name list and so on); the bindings below are forced afterwards
  -- because they belong to THIS branch, not to whatever control was cloned.
  --
  -- A failed construction falls back to stock rather than taking the unit down:
  -- a patch that loads reading as a plain fader is recoverable, one that does
  -- not load is not.
  local cargs = {}
  for k, v in pairs(args.controlArgs or {}) do
    cargs[k] = v
  end
  cargs.button = id
  cargs.description = cargs.description or args.description or
                          GainBiasBranch.classDescription
  cargs.branch = self
  cargs.gainbias = object
  cargs.range = object

  local Custom = args.controlClass
  if Custom then
    local ok, control = pcall(Custom, cargs)
    if ok and control then
      self.control = control
    else
      app.logInfo("%s: custom control class failed, using stock.", self)
    end
  end
  self.control = self.control or GainBias(cargs)

end

return GainBiasBranch

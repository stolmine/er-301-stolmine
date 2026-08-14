local Class = require "Base.Class"
local ControlBranch = require "Unit.ControlBranch"
local Pitch = require "Unit.ViewControl.Pitch"

local PitchBranch = Class {
  classType = "Pitch",
  classDescription = "Pitch",
  classPrefix = "tune"
}
PitchBranch:include(ControlBranch)

function PitchBranch:init(args)
  local id = args.id or app.logError("%s:init: id is missing.", self)
  local tune = app.ConstantOffset()
  tune:setName(id)
  local range = app.MinMax()
  range:setName(id)
  connect(tune, "Out", range, "In")
  args.leftDestination = tune:getInput("In")
  args.leftOutObject = tune
  args.leftOutletName = "Out"
  args.channelCount = 1
  args.objects = {
    tune,
    range
  }
  ControlBranch.init(self, args)
  self:setClassName("Unit.ControlBranch.Pitch")

  -- [stol:promote-control-type-spec] See Unit/ControlBranch/GainBias.lua for
  -- why the control class is a parameter and why a failure falls back to stock.
  local cargs = {}
  for k, v in pairs(args.controlArgs or {}) do
    cargs[k] = v
  end
  cargs.button = id
  cargs.description = cargs.description or args.description or
                          PitchBranch.classDescription
  cargs.branch = self
  cargs.offset = tune
  cargs.range = range

  local Custom = args.controlClass
  if Custom then
    local ok, control = pcall(Custom, cargs)
    if ok and control then
      self.control = control
    else
      app.logInfo("%s: custom control class failed, using stock.", self)
    end
  end
  self.control = self.control or Pitch(cargs)
end

return PitchBranch

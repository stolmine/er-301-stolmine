local app = app
local txo = require "txo"
local libtxo = require "txo.libtxo"
local Class = require "Base.Class"
local Unit = require "Unit"
local GainBias = require "Unit.ViewControl.GainBias"
local OptionControl = require "Unit.MenuControl.OptionControl"
local Encoder = require "Encoder"

local portMap = app.LinearDialMap(0, 3)
portMap:setSteps(1, 1, 1, 1)
portMap:setRounding(1)

local CV = Class {}
CV:include(Unit)

function CV:init(args)
  args.title = "TXo CV (i2c)"
  args.suppressTitleGeneration = true
  args.mnemonic = "TCV"
  Unit.init(self, args)
end

function CV:onLoadGraph(channelCount)
  local txoCV = self:addObject("txoCV",
                               libtxo.TXoCV(txo.dispatcher))

  connect(self, "In1", txoCV, "In")
  connect(txoCV, "Out", self, "Out1")
  if channelCount > 1 then
    connect(txoCV, "Out", self, "Out2")
  end

  local port = self:addObject("port", app.ParameterAdapter())
  tie(txoCV, "Port", port, "Out")
  self:addMonoBranch("port", port, "In", port, "Out")

  local gain = self:addObject("gain", app.ParameterAdapter())
  gain:hardSet("Bias", 1.0)
  tie(txoCV, "Gain", gain, "Out")
  self:addMonoBranch("gain", gain, "In", gain, "Out")
end

local menu = {
  "mode"
}

function CV:onShowMenu(objects, branches)
  local controls = {}

  controls.mode = OptionControl {
    description = "Mode",
    option = objects.txoCV:getOption("Mode"),
    choices = {
      "normal",
      "v/oct"
    }
  }

  return controls, menu
end

local views = {
  expanded = {
    "port",
    "gain"
  },
  collapsed = {}
}

function CV:onLoadViews(objects, branches)
  local controls = {}
  controls.port = GainBias {
    button = "port",
    description = "TXo Output",
    branch = branches.port,
    gainbias = objects.port,
    range = objects.port,
    biasMap = portMap,
    biasPrecision = 0,
    initialBias = 0
  }

  controls.gain = GainBias {
    button = "gain",
    description = "Gain",
    branch = branches.gain,
    gainbias = objects.gain,
    range = objects.gain,
    biasMap = Encoder.getMap("[0,2]"),
    biasPrecision = 2,
    initialBias = 1.0
  }

  return controls, views
end

return CV

local app = app
local txo = require "txo"
local libtxo = require "txo.libtxo"
local Class = require "Base.Class"
local Unit = require "Unit"
local GainBias = require "Unit.ViewControl.GainBias"
local Encoder = require "Encoder"

local portMap = app.LinearDialMap(0, 3)
portMap:setSteps(1, 1, 1, 1)
portMap:setRounding(1)

local TR = Class {}
TR:include(Unit)

function TR:init(args)
  args.title = "TXo TR (i2c)"
  args.suppressTitleGeneration = true
  args.mnemonic = "TTR"
  Unit.init(self, args)
end

function TR:onLoadGraph(channelCount)
  local txoTR = self:addObject("txoTR",
                               libtxo.TXoTR(txo.dispatcher))

  -- Unit input -> TXoTR (for I2C capture) and passthrough to output
  connect(self, "In1", txoTR, "In")
  connect(txoTR, "Out", self, "Out1")
  if channelCount > 1 then
    connect(txoTR, "Out", self, "Out2")
  end

  local port = self:addObject("port", app.ParameterAdapter())
  tie(txoTR, "Port", port, "Out")
  self:addMonoBranch("port", port, "In", port, "Out")

  local threshold = self:addObject("threshold", app.ParameterAdapter())
  tie(txoTR, "Threshold", threshold, "Out")
  self:addMonoBranch("threshold", threshold, "In", threshold, "Out")
end

local views = {
  expanded = {
    "port",
    "threshold"
  },
  collapsed = {}
}

function TR:onLoadViews(objects, branches)
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

  controls.threshold = GainBias {
    button = "thresh",
    description = "Gate Threshold",
    branch = branches.threshold,
    gainbias = objects.threshold,
    range = objects.threshold,
    biasMap = Encoder.getMap("[0,1]"),
    biasPrecision = 2,
    initialBias = 0.1
  }

  return controls, views
end

return TR

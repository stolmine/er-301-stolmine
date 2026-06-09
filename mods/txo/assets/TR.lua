local app = app
local txo = require "txo"
local libtxo = require "txo.libtxo"
local Class = require "Base.Class"
local Unit = require "Unit"
local GainBias = require "Unit.ViewControl.GainBias"
local Gate = require "Unit.ViewControl.Gate"
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

  -- Passthrough chain: In1 -> txoTR (I2C capture) -> vca -> Out.
  -- vca's Left input is a Comparator in TOGGLE mode acting as a
  -- sticky on/off gate. Comparator.Out goes high (1.0) or low (0.0)
  -- and stays there until the next S3 tap toggles it. Initial state
  -- = high so existing TXo units retain their pre-upgrade
  -- always-passthrough behaviour. CV-able via comparator's "In" if
  -- the user later patches modulation in.
  local vca = self:addObject("vca", app.Multiply())
  local passthrough = self:addObject("passthrough", app.Comparator())
  passthrough:setToggleMode()
  -- Pre-arm to state 1 (on) by simulating an initial rising edge.
  -- Without this the comparator boots in state 0 (off) and the unit
  -- defaults to silence -- a behaviour change on upgrade.
  passthrough:simulateRisingEdge()

  connect(self, "In1", txoTR, "In")
  connect(txoTR, "Out", vca, "Right")
  connect(passthrough, "Out", vca, "Left")
  connect(vca, "Out", self, "Out1")
  if channelCount > 1 then
    connect(vca, "Out", self, "Out2")
  end

  self:addMonoBranch("passthrough",
                     passthrough, "In", passthrough, "Out")

  local port = self:addObject("port", app.ParameterAdapter())
  tie(txoTR, "Port", port, "Out")
  self:addMonoBranch("port", port, "In", port, "Out")

  local threshold = self:addObject("threshold", app.ParameterAdapter())
  tie(txoTR, "Threshold", threshold, "Out")
  self:addMonoBranch("threshold", threshold, "In", threshold, "Out")
end

local views = {
  expanded = {
    "passthrough",
    "port",
    "threshold"
  },
  collapsed = {}
}

function TR:onLoadViews(objects, branches)
  local controls = {}
  controls.passthrough = Gate {
    button = "thru",
    description = "Passthrough",
    branch = branches.passthrough,
    comparator = objects.passthrough
  }
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

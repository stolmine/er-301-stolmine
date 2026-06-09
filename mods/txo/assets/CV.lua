local app = app
local txo = require "txo"
local libtxo = require "txo.libtxo"
local Class = require "Base.Class"
local Unit = require "Unit"
local GainBias = require "Unit.ViewControl.GainBias"
local Gate = require "Unit.ViewControl.Gate"
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

  -- Passthrough chain: In1 -> txoCV (I2C capture) -> vca -> Out.
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

  connect(self, "In1", txoCV, "In")
  connect(txoCV, "Out", vca, "Right")
  connect(passthrough, "Out", vca, "Left")
  connect(vca, "Out", self, "Out1")
  if channelCount > 1 then
    connect(vca, "Out", self, "Out2")
  end

  self:addMonoBranch("passthrough",
                     passthrough, "In", passthrough, "Out")

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
    "passthrough",
    "port",
    "gain"
  },
  collapsed = {}
}

function CV:onLoadViews(objects, branches)
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

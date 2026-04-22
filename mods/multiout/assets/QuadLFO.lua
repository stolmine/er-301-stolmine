local app = app
local libmultiout = require "multiout.libmultiout"
local Class = require "Base.Class"
local Unit = require "Unit"
local GainBias = require "Unit.ViewControl.GainBias"
local Gate = require "Unit.ViewControl.Gate"
local Encoder = require "Encoder"

local QuadLFO = Class {}
QuadLFO:include(Unit)

function QuadLFO:init(args)
  args.title = "Quad LFO"
  args.mnemonic = "QL"
  -- Force 4-channel construction. Sub-out 1 (0°) is the primary output;
  -- vanilla firmware exposes only outputs 1 and 2 via its stereo-only Lua
  -- wrapper, so vanilla users see this unit as a stereo LFO (Out1+Out2 wired
  -- to chain L+R). Stolmine firmware exposes all four sub-outs via the local
  -- picker's M6 cycle (driven by the args.subOutLabels metadata, which
  -- vanilla ignores as an unknown field).
  args.channelCount = 4
  args.subOutLabels = {"0deg", "90deg", "180deg", "270deg"}
  Unit.init(self, args)
end

function QuadLFO:onLoadGraph(channelCount)
  local lfo = self:addObject("lfo", libmultiout.QuadLFO())
  local f0 = self:addObject("f0", app.GainBias())
  local f0Range = self:addObject("f0Range", app.MinMax())
  local sync = self:addObject("sync", app.Comparator())
  sync:setTriggerMode()

  connect(f0, "Out", lfo, "Frequency")
  connect(f0, "Out", f0Range, "In")
  connect(sync, "Out", lfo, "Sync")

  connect(lfo, "Out1", self, "Out1")
  connect(lfo, "Out2", self, "Out2")
  connect(lfo, "Out3", self, "Out3")
  connect(lfo, "Out4", self, "Out4")

  self:addMonoBranch("rate", f0, "In", f0, "Out")
  self:addMonoBranch("sync", sync, "In", sync, "Out")
end

local views = {
  expanded = {"rate", "sync"},
  collapsed = {}
}

function QuadLFO:onLoadViews(objects, branches)
  local controls = {}

  controls.rate = GainBias {
    button = "rate",
    description = "Rate",
    branch = branches.rate,
    gainbias = objects.f0,
    range = objects.f0Range,
    biasMap = Encoder.getMap("oscFreq"),
    biasUnits = app.unitHertz,
    initialBias = 1.0,
    gainMap = Encoder.getMap("freqGain"),
    scaling = app.octaveScaling
  }

  controls.sync = Gate {
    button = "sync",
    description = "Sync",
    branch = branches.sync,
    comparator = objects.sync
  }

  return controls, views
end

return QuadLFO

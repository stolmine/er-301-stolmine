local Class = require "Base.Class"
local Library = require "Package.Library"
local Header = require "Package.Menu.Header"
local Choices = require "Package.Menu.Choices"
local Task = require "Package.Menu.Task"
local libtxo = require "txo.libtxo"

local TXo = Class {
  dispatcher = libtxo.TXoDispatcher()
}
TXo:include(Library)

function TXo:init(args)
  Library.init(self, args)
  self.enabled = false
  self.defaults["autoEnable"] = "no"
  self.defaults["address"] = "0x60"
  self.defaults["updateRate"] = "1000"
end

function TXo:enable()
  if not self.enabled then
    local address = self:getConfiguration("address")
    local rate = self:getConfiguration("updateRate")
    self.dispatcher:setUpdateRate(tonumber(rate))
    self.dispatcher:enable(tonumber(address))
    self.enabled = true
    app.logInfo("%s: i2c master enabled (address=%s, rate=%sHz).",
                self, address, rate)
  end
end

function TXo:disable()
  if self.enabled then
    self.dispatcher:disable()
    self.enabled = false
    app.logInfo("%s: i2c master disabled.", self)
  end
end

-- overrides

function TXo:onLoad()
  if self:getConfiguration("autoEnable") == "yes" then
    self:enable()
  end
end

function TXo:onUnload()
  self:disable()
end

function TXo:onShowMenu()
  local order = {
    "header",
    "manualEnable",
    "autoEnable",
    "address",
    "updateRate"
  }
  local controls = {}

  controls.header = Header {
    description = string.format("I2C master is %s.",
                                self.enabled and "enabled" or "disabled")
  }

  controls.autoEnable = Choices {
    description = "Auto Enable?",
    callback = function(choice)
      self:setConfiguration("autoEnable", choice)
      if choice == "yes" then
        self:enable()
      else
        self:disable()
      end
    end,
    choices = {
      "yes",
      "no"
    },
    current = self:getConfiguration("autoEnable")
  }

  controls.address = Choices {
    description = "TXo Address",
    callback = function(choice)
      self:setConfiguration("address", choice)
      if self.enabled then
        self:disable()
        self:enable()
      end
    end,
    choices = {
      "0x60",
      "0x61",
      "0x62",
      "0x63"
    },
    current = self:getConfiguration("address")
  }

  controls.updateRate = Choices {
    description = "Update Rate (Hz)",
    callback = function(choice)
      self:setConfiguration("updateRate", choice)
      if self.enabled then
        self.dispatcher:setUpdateRate(tonumber(choice))
      end
    end,
    choices = {
      "100",
      "250",
      "500",
      "1000",
      "2000"
    },
    current = self:getConfiguration("updateRate")
  }

  controls.manualEnable = Task {
    description = self.enabled and "Disable Now?" or "Enable Now?",
    task = function()
      if self.enabled then
        self:disable()
      else
        self:enable()
      end
    end
  }

  return controls, order, "TXo Library"
end

return TXo

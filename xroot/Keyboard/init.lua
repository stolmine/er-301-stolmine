local Settings = require "Settings"

local function create(msg, initial, extended, history)
  local method = Settings.get("textInputMethod")
  if method == "slot" then
    local Slot = require "Keyboard.Slot"
    return Slot(msg, initial, extended, history)
  else
    local Grid = require "Keyboard.Grid"
    return Grid(msg, initial, extended, history)
  end
end

return create

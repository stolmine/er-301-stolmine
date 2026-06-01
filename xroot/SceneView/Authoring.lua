-- Phase 3a authoring view stub. Dives in from the Performance
-- view's S3 with a specific scene index. For now just displays
-- "scene N authoring" placeholder text; the real chain-mirror with
-- per-control target+value widgets lands in phase 3b.
--
-- Navigation back to Performance:
--   * UP at the nav root          -> Channels.leaveSceneAuthoring()
--   * shift+HOME (zeroReleased)   -> same
--   * CANCEL                      -> same
-- All three converge so the user can escape from any familiar key.

local app = app
local Class = require "Base.Class"
local Window = require "Base.Window"

local Authoring = Class {}
Authoring:include(Window)

function Authoring:init(sceneView, sceneIdx)
  Window.init(self)
  self:setClassName("SceneView.Authoring")
  self.sceneView = sceneView
  self.sceneIdx  = sceneIdx
  self.scene     = sceneView:getScene(sceneIdx)

  -- Placeholder main display. Replaced in phase 3b with a clone
  -- of the chain's user-mode edit surface, controls wrapped in
  -- target+value widgets pointing at the scene's delta params.
  local title = app.Label(string.format(
    "scene %d: %s", sceneIdx, self.scene and self.scene:getName() or "?"), 12)
  title:setCenter(128, 40)
  self:addMainGraphic(title)

  local hint = app.Label("phase 3b: chain mirror + delta authoring", 10)
  hint:setCenter(128, 18)
  hint:setForegroundColor(app.GRAY7)
  self:addMainGraphic(hint)

  local back = app.Label("UP / shift+HOME to return to performance", 10)
  back:setPosition(2, app.GRID4_LINE4)
  back:setJustification(app.justifyLeft)
  back:setForegroundColor(app.GRAY7)
  self:addSubGraphic(back)
end

-- Returns true if context switch happened; caller's handler stops.
function Authoring:_back()
  local Channels = require "Channels"
  Channels.leaveSceneAuthoring()
  return true
end

function Authoring:upReleased(shifted)
  if shifted then return false end
  return self:_back()
end

function Authoring:zeroReleased()
  return self:_back()
end

function Authoring:cancelReleased(shifted)
  if shifted then return false end
  return self:_back()
end

return Authoring

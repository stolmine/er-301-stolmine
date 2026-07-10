-- [stol:infra-crash-diag-debug-mode-ui]
-- Admin viewer for past crash reports (front/crash.log). Two tiers:
--   * a top-level list of reports (one row per report, summarized by kind+time)
--   * a detail scroll of the selected report's full text
-- Reachable from AdminMode ("Crash Reports"). Reloads from crash.log on each
-- show so a freshly-injected/captured report appears without a reboot.

local ListWindow = require "ListWindow"
local Class = require "Base.Class"
local CrashReport = require "CrashReport"

--------------------------------------------------------------------------------
-- Detail: a scrollable list of one report's lines.
--------------------------------------------------------------------------------
local Detail = Class {}
Detail:include(ListWindow)

function Detail:init(title, lines)
  ListWindow.init(self, {
    title = title,
    columns = {{name = "line", width = 1, textSize = 10}}
  })
  self:setClassName("CrashReportDetail")
  self.lineColumn = self:getColumnByName("line")
  for _, l in ipairs(lines) do
    self.lineColumn:addItem(l)
  end
end

function Detail:onShow()
  self.lineColumn:scrollToTop()
end

--------------------------------------------------------------------------------
-- Viewer: the top-level report list.
--------------------------------------------------------------------------------
local Viewer = Class {}
Viewer:include(ListWindow)

function Viewer:init()
  ListWindow.init(self, {
    title = "Crash Reports",
    columns = {{name = "report", width = 1, textSize = 10}}
  })
  self:setClassName("CrashReportViewer")
  self.reportColumn = self:getColumnByName("report")
  self:setSubCommand(1, "View", self.viewSelected)
  self:setSubCommand(3, "Clear", self.clearAll)
  self:reload()
end

function Viewer:reload()
  self:clearRows()
  self.reports = CrashReport.parseReports()
  if #self.reports == 0 then
    self.reportColumn:addItem("No crash reports.")
    return
  end
  for i, r in ipairs(self.reports) do
    self.reportColumn:addItem(string.format("%d. %s", i, r.summary), i)
  end
end

function Viewer:onShow()
  self:reload()
end

function Viewer:viewSelected()
  -- getSelectedData() only returns the row's data payload right after a
  -- selection change; once the list settles it can read back nil, so fall back to
  -- the (always-valid) 0-based selected index.
  local idx = self.reportColumn:getSelectedData()
  if type(idx) ~= "number" then
    local sel = self.reportColumn:getSelectedIndex()
    idx = sel and (sel + 1) or nil
  end
  if type(idx) ~= "number" then
    return
  end
  local r = self.reports and self.reports[idx]
  if not r then
    return
  end
  local detail = Detail(string.format("Report %d", idx), r.lines)
  detail:show()
end

function Viewer:clearAll()
  local Verification = require "Verification"
  local dlg = Verification.Main("Delete all crash reports?", "This clears crash.log.")
  dlg:subscribe("done", function(ans)
    if ans then
      CrashReport.clearAll()
      self:reload()
    end
  end)
  dlg:show()
end

-- Return a singleton instance so AdminMode can use it as a `menu:add`
-- destination (mirrors LogHistory). onShow reloads, so the singleton stays fresh.
return Viewer()

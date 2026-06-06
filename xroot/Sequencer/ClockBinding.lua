-- Sequencer external-clock + reset source bindings.
--
-- Lua-side wiring layer between a Source.External picker (run by
-- the ClockView controls) and the ext-clock / ext-reset Comparator
-- inputs on SequencerTask. A user-picked Source.External outlet is
-- connected DIRECTLY to comparator:getInput("In") via
-- app.AudioThread.connect. No branches, no host chain.
--
-- Module state is the currently-bound source NAMES, used both by the
-- UI (to render the picker's "current selection") and by quicksave
-- persistence (phase 6.6) which records the picked names and
-- reconnects them on deserialize.

local app = app
local ClockBinding = {}

local seqTask = app.AudioThread.getSequencerTask()

-- Currently-bound source names. nil = no source bound; the comparator
-- input is unconnected (returns ZeroOutput per Inlet.cpp, i.e. no
-- edges, no behaviour change).
local clockSourceName = nil
local resetSourceName = nil

-- Internal helper: resolve `srcOrName` (Source object or name string
-- or nil) into a (source, name) pair. Returns (nil, nil) if no source
-- found. Logs but does NOT raise on a missing name string.
local function resolveSource(srcOrName)
  if srcOrName == nil then
    return nil, nil
  end
  if type(srcOrName) == "string" then
    local src = app.getExternalSource(srcOrName)
    if not src then
      app.logError("Sequencer.ClockBinding: unknown source name %q", srcOrName)
      return nil, nil
    end
    return src, srcOrName
  end
  -- Assume it's a Source.External object.
  if srcOrName.getOutlet and srcOrName.getDisplayName then
    return srcOrName, srcOrName:getDisplayName()
  end
  app.logError("Sequencer.ClockBinding: unrecognized source argument (type=%s)",
               type(srcOrName))
  return nil, nil
end

local function comparatorInput(comp)
  if not comp then return nil end
  return comp:getInput("In")
end

-- ---------------------------------------------------------------------------
-- Clock source binding
-- ---------------------------------------------------------------------------

function ClockBinding.setClockSource(srcOrName)
  if not seqTask then return end
  local inlet = comparatorInput(seqTask:getExtClockComparator())
  if not inlet then return end

  -- Always disconnect first; covers both "rebinding to a new source"
  -- and "clearing" cases without code duplication.
  app.AudioThread.disconnect(inlet)
  clockSourceName = nil

  local src, name = resolveSource(srcOrName)
  if src then
    app.AudioThread.connect(src:getOutlet(), inlet)
    clockSourceName = name
  end
end

function ClockBinding.clearClockSource()
  ClockBinding.setClockSource(nil)
end

function ClockBinding.getClockSourceName()
  return clockSourceName
end

function ClockBinding.getClockSource()
  if clockSourceName then
    return app.getExternalSource(clockSourceName)
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Reset source binding
-- ---------------------------------------------------------------------------

function ClockBinding.setResetSource(srcOrName)
  if not seqTask then return end
  local inlet = comparatorInput(seqTask:getExtResetComparator())
  if not inlet then return end

  app.AudioThread.disconnect(inlet)
  resetSourceName = nil

  local src, name = resolveSource(srcOrName)
  if src then
    app.AudioThread.connect(src:getOutlet(), inlet)
    resetSourceName = name
  end
end

function ClockBinding.clearResetSource()
  ClockBinding.setResetSource(nil)
end

function ClockBinding.getResetSourceName()
  return resetSourceName
end

function ClockBinding.getResetSource()
  if resetSourceName then
    return app.getExternalSource(resetSourceName)
  end
  return nil
end

return ClockBinding

-- Column-aware L1 cell value formatters. Shared by the L1 grid render
-- (xroot/Sequencer/GridView.lua) and the L2 cell editor's target
-- readout (xroot/Sequencer/CellEditor.lua) so both surfaces show the
-- exact same text for any given cell value.
--
-- All formatters pad to a 5-char field so the grid rows line up. The
-- modal readout strips that padding via Format.trim.

local Format = {}

local kNoteNames = { "C ", "C#", "D ", "D#", "E ", "F ", "F#", "G ", "G#", "A ", "A#", "B " }

-- CV1: 1V/oct note name. Rounds to nearest semitone for display.
function Format.fmtNote(volts)
  if volts ~= volts then return "  NaN" end
  local semi = math.floor(volts * 12 + 0.5)
  local oct  = math.floor(semi / 12)
  local n    = semi - oct * 12
  if n < 0 then n = n + 12 end
  return string.format("%-2s%3d", kNoteNames[n + 1], oct)
end

-- CV2: signed volts with one decimal.
function Format.fmtVolts(v)
  if v ~= v then return "  NaN" end
  return string.format("%5.1f", v)
end

-- Transpose: signed integer semitones, right-aligned 5-char field.
function Format.fmtTranspose(v)
  if v ~= v then return "  NaN" end
  return string.format("%+4d ", math.floor(v + 0.5))
end

-- Gate-len / step-len beats. Common musical fractions get clean names.
-- Engine treats values at or above kTieThreshold (3.999) as TIE.
function Format.fmtBeats(v)
  if v ~= v then return "  NaN" end
  if v >= 3.999 then return "TIE  " end
  if v < 0.005 then return " 0.00" end
  if math.abs(v - 0.0625) < 0.001 then return "1/16 " end
  if math.abs(v - 0.125)  < 0.001 then return "1/8  " end
  if math.abs(v - 0.25)   < 0.001 then return "1/4  " end
  if math.abs(v - 0.5)    < 0.001 then return "1/2  " end
  if math.abs(v - 1.0)    < 0.001 then return "1    " end
  if math.abs(v - 2.0)    < 0.001 then return "2    " end
  if math.abs(v - 4.0)    < 0.001 then return "4    " end
  return string.format("%5.2f", v)
end

-- Step-len: clock ticks per row. Engine stores beats (1.0 = quarter);
-- 4 PPQN means ticks = beats * 4.
function Format.fmtTicks(v)
  if v ~= v then return "  NaN" end
  return string.format("%5d", math.floor(v * 4 + 0.5))
end

-- Dispatch by column index (0..5 = A..F = cv1, cv2, g1L, g2L, stL, tr).
function Format.fmtCellByCol(col, v)
  if col == 0 then return Format.fmtNote(v) end
  if col == 1 then return Format.fmtVolts(v) end
  if col == 2 or col == 3 then return Format.fmtBeats(v) end
  if col == 4 then return Format.fmtTicks(v) end
  if col == 5 then return Format.fmtTranspose(v) end
  return string.format("%5.2f", v)
end

-- Strip leading/trailing spaces for label-style rendering (modal
-- readout, etc.). The grid wants the padding for column alignment;
-- standalone labels look cleaner without it.
function Format.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

return Format

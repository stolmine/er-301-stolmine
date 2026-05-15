-- ER-301 stolmine sequencer quicksave persistence.
--
-- Round-trips per-slot patch state (column lengths, markers, L1 cell
-- values, L2 predicate:action rules) through the firmware's existing
-- quicksave mechanism. Transient runtime state (playheads, RNG,
-- gate envelopes, tick scheduling) is intentionally not persisted --
-- it's reset to engine defaults on load via Slot::reset.
--
-- Called from xroot/Persist/QuickSavePreset.lua:
--   populate(): data.sequencer = Persist.serialize()
--   apply():    if data.sequencer then Persist.deserialize(data.sequencer) end
--
-- BPM lives in Settings (already round-trips via /rear/settings.lua);
-- it's slot-independent and unrelated to this module.

local app = app

local M = {}

-- Mirrors od/sequencer/Sequencer.h constants. If they ever bump on
-- the C++ side, update here too. Cheap to validate at runtime via
-- the bench roundtrip test.
local kNumSlots          = 4
local kNumColumns        = 6
local kMaxStepsPerColumn = 64

-- ---------------------------------------------------------------------------
-- Serialize
-- ---------------------------------------------------------------------------
function M.serialize()
  local seq = app.AudioThread.getSequencerTask()
  if not seq then return nil end

  local data = { slots = {} }
  for s = 0, kNumSlots - 1 do
    -- Capture per-slot running flag so the load path can optionally
    -- resume transport (gated by the
    -- quickSaveRestoresSequencerTransport Setting). Stored
    -- unconditionally so the format doesn't need to bump if the user
    -- later flips the Setting on.
    local slot = { running = seq:isSlotRunning(s), columns = {} }
    for c = 0, kNumColumns - 1 do
      local col = {
        length  = seq:columnLength(s, c),
        marker1 = seq:marker1(s, c),
        marker2 = seq:marker2(s, c),
        l1 = {},
        l2 = {},
      }

      -- L1: dense 64-cell array. Saving cells past `length` so that a
      -- later length-grow doesn't surprise the user with zeros.
      for r = 0, kMaxStepsPerColumn - 1 do
        col.l1[r + 1] = seq:l1Value(s, c, r)
      end

      -- L2: sparse map keyed by row index. Most cells are typically
      -- absent (`present` == false), so the table stays small.
      for r = 0, kMaxStepsPerColumn - 1 do
        if seq:l2Present(s, c, r) then
          col.l2[r] = {
            predOp      = seq:l2PredOp(s, c, r),
            predColA    = seq:l2PredColA(s, c, r),
            predColARow = seq:l2PredColARow(s, c, r),
            predVal     = seq:l2PredVal(s, c, r),
            actOp       = seq:l2ActOp(s, c, r),
            actTgt      = seq:l2ActTgt(s, c, r),
            actTgtRow   = seq:l2ActTgtRow(s, c, r),
            actVal      = seq:l2ActVal(s, c, r),
          }
        end
      end

      slot.columns[c + 1] = col
    end
    data.slots[s + 1] = slot
  end
  return data
end

-- ---------------------------------------------------------------------------
-- Deserialize
-- ---------------------------------------------------------------------------
function M.deserialize(data)
  local seq = app.AudioThread.getSequencerTask()
  if not (seq and data and data.slots) then return end

  -- Setting gates whether the saved running flag is honored on load.
  -- Default "no" preserves the locked decision that every quicksave
  -- load force-stops all slots. Read once outside the slot loop so
  -- the answer is consistent across slots even if Settings changes
  -- mid-load (unlikely, but defensive).
  --
  -- pcall: Settings.get crashes if invoked before Settings.init()
  -- has populated `variables` (e.g. the boot-time sequencer bench
  -- in xroot/sandbox runs before Application.init). When Settings
  -- isn't ready, fall back to the safe default "no" so the bench
  -- and other early callers exercise the legacy force-stop path.
  local Settings = require "Settings"
  local ok, val = pcall(Settings.get, "quickSaveRestoresSequencerTransport")
  local restoreTransport = ok and (val == "yes")

  for s = 0, kNumSlots - 1 do
    local slot = data.slots[s + 1]
    if slot and slot.columns then
      -- Stop the slot before mutating engine state so we're not
      -- racing the audio thread with half-loaded L1/L2 values.
      seq:stopSlot(s)

      for c = 0, kNumColumns - 1 do
        local col = slot.columns[c + 1]
        if col then
          -- Zero every cell + clear every L2 rule across the full 64
          -- range before applying the saved state. Otherwise leftover
          -- cells from a prior patch survive when the saved column
          -- has fewer non-zero / non-empty entries.
          for r = 0, kMaxStepsPerColumn - 1 do
            seq:setL1(s, c, r, 0.0)
            seq:clearL2(s, c, r)
          end

          -- Length first, then markers, then cell content. setMarkers
          -- auto-grows length, so setting length explicitly first
          -- guarantees the saved length is what sticks.
          seq:setColumnLength(s, c, col.length or 16)
          seq:setMarkers(s, c, col.marker1 or 0, col.marker2 or 15)

          if col.l1 then
            for r = 0, kMaxStepsPerColumn - 1 do
              local v = col.l1[r + 1]
              if v then seq:setL1(s, c, r, v) end
            end
          end

          if col.l2 then
            -- Sparse map: integer row keys, cell-table values.
            for r, cell in pairs(col.l2) do
              if type(r) == "number" and type(cell) == "table" then
                seq:setL2(s, c, r,
                          cell.predOp or 0,
                          cell.predColA or -1,
                          cell.predColARow or -1,
                          cell.predVal or 0.0,
                          cell.actOp or 0,
                          cell.actTgt or -1,
                          cell.actTgtRow or -1,
                          cell.actVal or 0.0)
              end
            end
          end
        end
      end

      -- Reset transient state (playhead -> loopMin, passCount=0,
      -- lastTickValue=NaN, lastL2FiredRow=-1, held*=0, etc.).
      seq:resetSlot(s)

      -- Restore transport last so the slot ticks against fully-loaded
      -- state. Only when the Setting is "yes" and the saved flag was
      -- true; default-no keeps the legacy force-stop behaviour. Older
      -- quicksaves missing the `running` field load as not-running
      -- (the seq:isSlotRunning getter wasn't called when they were
      -- saved, so the field is absent / nil).
      if restoreTransport and slot.running then
        seq:startSlot(s)
      end
    end
  end
end

return M

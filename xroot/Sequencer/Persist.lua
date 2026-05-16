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

-- Quicksave schema version. Bumped to 2 when the column layout
-- migrated from v0.1 (cv1 cv2 cv3 gtL gtA stL) to v2 (cv1 cv2 g1L
-- g2L stL tr). Older saves with no schemaVersion field are treated
-- as v1 and run through migrateV1ToV2 on load.
local kSchemaVersion     = 2

-- v0.1 column indices, used only by the v1 -> v2 migration.
local V1_COL_CV1      = 0
local V1_COL_CV2      = 1
local V1_COL_CV3      = 2  -- dropped in v2
local V1_COL_GATE_LEN = 3  -- -> v2 COL_GATE1_LEN (2)
local V1_COL_GATE_AMP = 4  -- -> v2 COL_GATE2_LEN (3), non-zero rows mapped to 0.25 beats
local V1_COL_STEP_LEN = 5  -- -> v2 COL_STEP_LEN (4)

-- v2 column indices (mirror Sequencer.h).
local V2_COL_CV1        = 0
local V2_COL_CV2        = 1
local V2_COL_GATE1_LEN  = 2
local V2_COL_GATE2_LEN  = 3
local V2_COL_STEP_LEN   = 4
local V2_COL_TRANSPOSE  = 5

-- Migrate a v1 quicksave data table to v2 shape, in place. Returns
-- the same table for chaining. Migration rules (per the v2 layout
-- plan in docs/planning/sequencer-implementation-plan.md):
--   col 0 (cv1), col 1 (cv2): unchanged.
--   col 2 (old cv3): DROPPED. L1 + L2 discarded. References to col 2
--     in L2 rules' colA/targetCol get neutered to -1 (host) with a log.
--   col 3 (old gtL) -> col 2 (g1L). Length, markers, L1, L2 verbatim.
--   col 4 (old gtA, gate-amp) -> col 3 (g2L). Non-zero amp values
--     rewritten as 0.25 (= 1 tick gate-len) so the row still fires;
--     zero amp stays zero. Length / markers transferred. The intent
--     "this row should produce a gate" is preserved.
--   col 5 (old stL) -> col 4 (stL). Verbatim transfer.
--   col 5 (new tr): not present in v1; zero-initialized to default
--     length 16, markers 0..15.
--   L2 rule colA / targetCol indices remap: 2 -> -1 (neutered cv3),
--     3 -> 2 (gtL -> g1L), 4 -> 3 (gtA -> g2L), 5 -> 4 (stL).
local function remapV1ColRef(idx, neutered)
  if idx == V1_COL_CV3 then
    -- cv3 references: rewrite to host-col (-1) since cv3 no longer
    -- exists. Count for log.
    neutered.cv3 = (neutered.cv3 or 0) + 1
    return -1
  elseif idx == V1_COL_GATE_LEN then return V2_COL_GATE1_LEN
  elseif idx == V1_COL_GATE_AMP then return V2_COL_GATE2_LEN
  elseif idx == V1_COL_STEP_LEN then return V2_COL_STEP_LEN
  end
  -- cv1 (0), cv2 (1), -1 (host) unchanged.
  return idx
end

local function migrateV1ToV2(data)
  if not (data and data.slots) then return data end
  local neutered = { cv3 = 0, ampToLen = 0 }
  for s = 1, kNumSlots do
    local slot = data.slots[s]
    if slot and slot.columns then
      local oldCols = slot.columns
      local newCols = {}
      -- cv1, cv2: index 1 and 2 in the Lua table (0-based 0 and 1).
      newCols[1] = oldCols[1]
      newCols[2] = oldCols[2]
      -- old gtL (Lua idx 4) -> new g1L (Lua idx 3)
      newCols[3] = oldCols[4]
      -- old gtA (Lua idx 5) -> new g2L (Lua idx 4): rewrite L1 values.
      local gtA = oldCols[5]
      if gtA then
        local g2L = {
          length  = gtA.length,
          marker1 = gtA.marker1,
          marker2 = gtA.marker2,
          l1 = {},
          l2 = {},
        }
        if gtA.l1 then
          for r = 1, kMaxStepsPerColumn do
            local v = gtA.l1[r] or 0
            -- Non-zero amp -> 0.25 beats (= 1 tick) so the row fires
            -- a short gate; zero amp -> zero (no fire).
            if v ~= 0 then
              g2L.l1[r] = 0.25
              neutered.ampToLen = neutered.ampToLen + 1
            else
              g2L.l1[r] = 0
            end
          end
        end
        -- L2 rules on gate-amp keep their structure; the col 4 index
        -- they may reference gets remapped below.
        if gtA.l2 then
          for r, cell in pairs(gtA.l2) do
            g2L.l2[r] = cell  -- shallow copy; remap pass below fixes col refs
          end
        end
        newCols[4] = g2L
      end
      -- old stL (Lua idx 6) -> new stL (Lua idx 5)
      newCols[5] = oldCols[6]
      -- new tr (Lua idx 6): zero-initialized.
      do
        local trL1 = {}
        for r = 1, kMaxStepsPerColumn do trL1[r] = 0 end
        newCols[6] = { length = 16, marker1 = 0, marker2 = 15,
                       l1 = trL1, l2 = {} }
      end

      -- Pass over every L2 cell in the new layout and remap colA /
      -- targetCol indices from v1 -> v2.
      for c = 1, kNumColumns do
        local col = newCols[c]
        if col and col.l2 then
          for r, cell in pairs(col.l2) do
            if type(cell) == "table" then
              if cell.predColA and cell.predColA >= 0 then
                cell.predColA = remapV1ColRef(cell.predColA, neutered)
              end
              if cell.actTgt and cell.actTgt >= 0 then
                cell.actTgt = remapV1ColRef(cell.actTgt, neutered)
              end
            end
          end
        end
      end

      slot.columns = newCols
    end
  end
  data.schemaVersion = kSchemaVersion
  if neutered.cv3 > 0 then
    app.logInfo("Sequencer.Persist: v1->v2 migration neutered %d cv3 L2 references", neutered.cv3)
  end
  if neutered.ampToLen > 0 then
    app.logInfo("Sequencer.Persist: v1->v2 migration mapped %d gate-amp rows to 0.25-beat g2L", neutered.ampToLen)
  end
  return data
end

-- ---------------------------------------------------------------------------
-- Serialize
-- ---------------------------------------------------------------------------
function M.serialize()
  local seq = app.AudioThread.getSequencerTask()
  if not seq then return nil end

  local data = { schemaVersion = kSchemaVersion, slots = {} }
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

  -- v1 saves have no schemaVersion field; run the migration in place so
  -- the rest of this function works against a v2-shaped table.
  local sv = data.schemaVersion or 1
  if sv < kSchemaVersion then
    app.logInfo("Sequencer.Persist: migrating v%d quicksave -> v%d", sv, kSchemaVersion)
    data = migrateV1ToV2(data)
  end

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

-- Exposed for bench coverage. Production callers go through
-- M.deserialize which invokes the migration automatically.
M._migrateV1ToV2  = migrateV1ToV2
M._schemaVersion  = kSchemaVersion

return M

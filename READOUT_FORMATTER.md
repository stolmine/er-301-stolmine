# Readout Display Formatter

## Status: Implemented

`app.Readout` now supports a name table for displaying mapped text instead of raw numeric values.

## API

```lua
readout:addName(str)    -- append a name to the table (enables name display)
readout:clearNames()    -- clear all names (reverts to numeric display)
```

When names are set, the readout rounds the display value to the nearest integer, uses it as an index into the name table, and displays the corresponding string. Out-of-range indices display "??".

The index comes from the converted display value (after unit conversion via the readout's `DialMap`), so if your parameter stores raw values 0, 1, 2, 3, 4 and the map is linear 1:1, the table entries correspond directly.

### Files Modified

- `od/graphics/controls/Readout.h` — added `addName()`, `clearNames()`, `mNameTable` vector, `mUseNameTable` flag
- `od/graphics/controls/Readout.cpp` — method implementations + name table check in `commitChanges()`

## How to Use (Lua)

```lua
local readout = app.Readout(0, 0, ply, 10)
readout:setParameter(param)
readout:setAttributes(app.unitNone, map)

-- Add names one at a time (SWIG-friendly)
for _, v in ipairs({"1", "2", "4", "8", "16"}) do
  readout:addName(v)
end
```

### Clearing the Name Table

```lua
readout:clearNames()  -- reverts to standard numeric display
```

## Vanilla Firmware Compatibility

This is a non-breaking, additive change. Habitat units can use a runtime feature check:

```lua
if readout.addName then
  for _, v in ipairs({"1", "2", "4", "8", "16"}) do
    readout:addName(v)
  end
end
```

On vanilla firmware, `addName` won't exist in the SWIG binding so it resolves to nil. The readout falls back to showing the raw numeric value — not ideal UX but functional.

## Migrating from the Label Overlay Workaround

The old pattern in habitat (RaindropControl.lua, TimeControl.lua):

```lua
-- OLD: hide readout, overlay label, manually sync on every event
self.stackReadout = makeReadout(args.stack, stackMap, 0, app.unitNone, -ply)
self.stackLabel = app.Label("1", 10)
-- ... manual updateStackLabel() on encoder, zero, restore
```

Replace with:

```lua
-- NEW: single readout with addName, no label overlay
self.stackReadout = makeReadout(args.stack, stackMap, 0, app.unitNone, col3)
if self.stackReadout.addName then
  for _, v in ipairs({"1", "2", "4", "8", "16"}) do
    self.stackReadout:addName(v)
  end
end
-- No manual sync needed — readout updates automatically
```

This restores the cursor highlight, removes the boilerplate, and works on both stolmine and vanilla firmware.

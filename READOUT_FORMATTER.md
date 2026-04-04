# Readout Display Formatter

## Status: Implemented

`app.Readout` now supports a name table for displaying mapped text instead of raw numeric values.

## What Changed

Added `setNameTable()` to `od::Readout`:

```cpp
void Readout::setNameTable(const std::vector<std::string> &names);
```

When set, the readout rounds the display value to the nearest integer, uses it as an index into the name table, and displays the corresponding string. Out-of-range indices display "??". Passing an empty vector disables the name table and reverts to numeric display.

### Files Modified

- `od/graphics/controls/Readout.h` — added `setNameTable()` method, `mNameTable` vector, `mUseNameTable` flag
- `od/graphics/controls/Readout.cpp` — method implementation + name table check in `commitChanges()`

### SWIG

No `.i` file changes needed. `od/app.i` already has the required directives:

```swig
%include <std_vector.i>
%include <std_string.i>
%template(StringVector) std::vector<std::string>;
```

This exposes `app.StringVector` in Lua. SWIG does not auto-convert raw Lua tables to `std::vector<std::string>`, so you must construct a `StringVector` explicitly.

## How to Use (Lua)

```lua
local readout = app.Readout(0, 0, ply, 10)
readout:setParameter(param)
readout:setAttributes(app.unitNone, map)

-- Build a StringVector and pass it to setNameTable
local names = app.StringVector()
names:push_back("1")
names:push_back("2")
names:push_back("4")
names:push_back("8")
names:push_back("16")
readout:setNameTable(names)
```

The name table is indexed from the converted display value (after unit conversion via the readout's `DialMap`), rounded to the nearest integer. So if your parameter stores raw values 0, 1, 2, 3, 4 and the map is linear 1:1, the table entries correspond directly.

### Clearing the Name Table

```lua
readout:setNameTable(app.StringVector())  -- reverts to standard numeric display
```

## Vanilla Firmware Compatibility

This is a non-breaking, additive change. Habitat units can use a runtime feature check:

```lua
if readout.setNameTable then
  local names = app.StringVector()
  for _, v in ipairs({"1", "2", "4", "8", "16"}) do names:push_back(v) end
  readout:setNameTable(names)
end
```

On vanilla firmware, `setNameTable` won't exist in the SWIG binding so it resolves to nil. The readout falls back to showing the raw numeric value — not ideal UX but functional. No off-screen readout or label overlay workaround needed on the vanilla path.

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
-- NEW: single readout with name table, no label overlay
self.stackReadout = makeReadout(args.stack, stackMap, 0, app.unitNone, col3)
if self.stackReadout.setNameTable then
  local names = app.StringVector()
  for _, v in ipairs({"1", "2", "4", "8", "16"}) do names:push_back(v) end
  self.stackReadout:setNameTable(names)
end
-- No manual sync needed — readout updates automatically
```

This restores the cursor highlight, removes the boilerplate, and works on both stolmine and vanilla firmware.

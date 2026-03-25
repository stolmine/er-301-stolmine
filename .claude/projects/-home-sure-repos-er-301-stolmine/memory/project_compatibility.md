---
name: compatibility_issue
description: Units/presets from stolmine firmware vs vanilla v0.7.0 are incompatible — txo library not present in vanilla, and vice versa
type: project
---

Units built on stolmine firmware (which adds `txo` mod as a bundled library) cannot load on vanilla v0.7.0 and vice versa.

**Why:** When units are serialized (quicksaves/presets), `loadInfo` includes `libraryName` and `moduleName`. The `txo` library doesn't exist in vanilla v0.7.0, so any quicksave referencing `txo.CV` or `txo.TR` units will fail to instantiate on vanilla. The factory does attempt a fallback search across all loaded libraries (Factory/init.lua:138-156), but TXo units simply don't exist in vanilla at all. Conversely, vanilla quicksaves should generally load on stolmine firmware since it's a superset (all core/teletype units exist), unless firmware version checks cause issues.

**How to apply:** Any compatibility work needs to address: (1) graceful degradation when loading a stolmine quicksave on vanilla — txo units should be skipped/stubbed rather than crashing, (2) ensuring vanilla quicksaves load cleanly on stolmine firmware, (3) the firmware version string (derived from git tags like `v0.7.0-txo.4`) differs from vanilla's `0.7.0-dev1`, which may affect version-gated logic in Persist or boot data.

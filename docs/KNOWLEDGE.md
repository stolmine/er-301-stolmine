# Stolmine Firmware Knowledge Base

Consolidated project knowledge for the ER-301 stolmine fork. This file is tracked in git so it travels with the repo across machines.

---

## User Profile

Hardware synth developer working on ER-301 eurorack firmware (stolmine fork). Deep knowledge of modular synthesis paradigms. Learning electronics/fabrication for eventual hardware port. No sudo access — ask user to handle anything requiring sudo.

## Build & Deploy

### Build commands
- Emulator: `make emu`
- Hardware: `make firmware ARCH=am335x` (clean rebuild: `make clean ARCH=am335x` first)
- No CI/CD — all builds are local via make

### Version tagging (CRITICAL)
- Version derived from git tags via `scripts/env.mk`: `git describe --match v*.*.*-* --tags --abbrev=0`
- **Never** create multiple version tags on the same commit — `git describe` picks alphabetically, not chronologically
- **Always** commit first, THEN tag. Verify with `git describe --match 'v*.*.*-*' --tags --abbrev=0` before building
- Must clean rebuild after tagging — version is baked into kernel.bin and install.lua
- **Before ANY am335x build, consult this section first.** This has wasted significant time repeatedly.

### Hardware deploy
1. SD card mounts at `/mnt` (device `/dev/sdd1`, vfat)
2. Copy firmware zip to **front card**: `sudo cp release/am335x/er-301-v<version>.zip /mnt/ER-301/firmware/`
3. NOT `~/.od/rear/` — that's for emulator only
4. Before installing, delete old packages to avoid version-match skip: `sudo rm /mnt/ER-301/packages/txo-*.pkg /mnt/ER-301/packages/teletype-*.pkg /mnt/ER-301/packages/core-*.pkg`
5. Boot the ER-301 — install screen appears

### Emulator deploy
- Copy .pkg files to `~/.od/rear/` for auto-install, or `~/.od/front/ER-301/packages/` for manual install

## ABI & Compatibility

### SWIG method dispatch is name-based
- SWIG method tables are `{name, function_ptr}` pairs — adding new methods doesn't shift existing lookups
- Safe to add non-virtual public methods to SWIG-exposed classes (Fader, Readout, etc.)
- But adding methods to a mod's class (e.g. teletype Dispatcher) changes the .so's SWIG table and CAN cause hangs on unit insertion — use free functions instead

### Vtable ABI
- Never insert virtual methods mid-class — append to end to preserve vtable layout
- `readPixel` was moved to end of FrameBuffer vtable for vanilla ABI compatibility

### Package compatibility
- Stolmine vs vanilla v0.7.0 presets/quicksaves are incompatible — txo library not present in vanilla
- .pkg files becoming directories on SD causes archive open failures
- SWIG `#ifndef` guards applied but did NOT fix bundled package version mismatch on HW

## Emulator Notes

### SDL2/HiDPI
- sdl2-compat on Arch breaks HiDPI; use `SDL_RenderSetLogicalSize` not `SDL_RenderSetScale`

## I2C System

### Architecture
- Single I2C2 peripheral shared between slave (teletype) and master (TXo)
- Slave address: 0x31 (configurable 0x31-0x33)
- TXo master address: 0x60 (configurable 0x60-0x67)
- Master/slave coexistence: master takes over CON register during TX, `restoreSlaveMode()` re-enables slave after

### F8R/16n Faderbank issue (OPEN)
- F8R worked on vanilla 0.6.x but NOT on stolmine firmware
- Crow works fine on stolmine
- F8R runs at 400kHz, Crow at ~100kHz — ER-301 slave configured for 100kHz
- F8R broadcasts to 0x60 (TXo), 0x31 (ER-301), 0x20 (Ansible) in rapid burst
- I2C interrupt clearing fix (restore `I2C_INT_ALL` when master not open) had no effect
- I2C slave diagnostic counters added (AAS/RRDY/ARDY/MSG/overrun/drop) — accessible from teletype package menu via `libteletype.I2cSlave_getDiag*()` free functions
- Root cause still under investigation

### TXo address choices
- `Package.Menu.Choices` widget only displays 5 items (M2-M6 buttons)
- TXo addresses trimmed to 4: 0x60, 0x62, 0x64, 0x66
- 0x64+ is outside F8R's broadcast range (0x60-0x63)

## Screensavers

### Current set
- snow, rain, forest, maze, perlin noise, voronoi, doom
- Pipes removed (boring, didn't cover screen edges)
- Maze has marching ants border animation

### Doom screensaver
- Vendors doomgeneric (GPL-2.0) in `libs/doomgeneric/`
- ZCajun-derived bot AI in `libs/doomgeneric/b_bot.c` (BSD-3)
- Bot writes directly to ticcmd_t via G_BuildTiccmd — no key event simulation
- 320x200 rendered to 102x64 viewport at correct aspect ratio with animated letterbox borders
- `G_DeferedInitNew()` on death to auto-restart (single-player death doesn't respawn via BT_USE)
- Null-patch guards in st_lib.c and v_video.c for shareware compatibility
- `DG_ScreenBuffer` memset before each tick to prevent frame ghosting
- Max 2 ticks per draw() call to prevent wipe transition spin-lock
- WAD path: `front/ER-301/doom/DOOM1.WAD`
- Not in screensaver cycle list (manual selection only)
- `mkdir` stubbed for bare-metal am335x build

### Encoder polling
- Encoder still captured during screensavers on HW despite LUT opt; likely UIThread polling issue

## Features Added

### Readout threshold labels
- `addThresholdLabel(float, string)` / `clearThresholdLabels()` on both Readout and Fader
- Maps float value ranges to descriptive text (e.g. 0.0="LP", 0.33="BP", 0.66="HP")
- Priority: name table > threshold labels > min/max text > numeric formatting

### Favorites system
- Shift-toggle edit mode in unit picker to tag/untag favorites
- Favorites displayed as own category above Recents
- In-place border toggle during edit (no list rebuild) — deferred save on mode exit
- Confirmation guard for clearing all favorites (toggleable in settings)

### Quicksave overwrite confirmation
- Confirmation dialog when saving over occupied slot (toggleable in settings)
- 48 quicksave slots (up from original)

### Slot machine text input
- Alternate keyboard: 6 SlidingList columns under M1-M6
- Hold button to focus column, encoder scrolls that column, release to insert
- Idle encoder scrolls all columns together
- Toggle between "grid" and "slot" in system settings under Interface
- History support included

### Package diagnostics
- Enhanced error reporting for .pkg archive and .so ELF load failures

## Platform Port (Future)

### Decision: RPi5 path, USB-C PD powered
- 7-phase staged bring-up plan (software only → display → audio → RT tuning → controls → custom PCB → CM5)
- Each phase self-contained with working result, learner-friendly progression
- ~8-15x net performance over AM335x at 96kHz with chain parallelism
- Linux RT_PREEMPT, not bare-metal (BCM2712 docs too closed)
- All movement goes through nav system — custom carrier/HAT required regardless

### v0.6.16 port
- Priority: port TXo mod to v0.6.16 stable firmware base
- v0.7 breaks compatibility with all third-party packages (lojik, strike, sloop, polygon, etc.)

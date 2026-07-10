# emu test fixtures — front/rear card roots

`tools/emu_test.py` assembles a hermetic sandbox per test by recursively copying
`front/` and `rear/` here into a fresh temp dir, then generates an `emu.config`
pointing the emulator at them (plus the repo `xroot/`). This is the
`emu-hermetic-sandbox` countermeasure from `planning/headless-emu-plan.md` §6
(threat 1: card-state bleed). Everything here is kept as small as possible; the
firmware's `xroot/Card/FileSystem.lua:init()` creates the rest of the directory
tree (`Path.createAll` over every root) on boot.

## Files

### `rear/settings.lua`
The persisted settings table, read at boot by `xroot/Settings/init.lua:5` from
`<rear>/settings.lua` via `Persist.readTable` (roethlin format — same as a real
device writes). Only keys that must differ from the code defaults in
`xroot/Settings/init.lua` are listed; every other setting falls back to its
default. Each key here neutralizes a determinacy or flow-blocking threat:

| key | value | why |
|---|---|---|
| `screenSaver` | `1 day` | Longest option (86400 s). There is no "off"; 1 day is far beyond any test/watchdog window, so the screensaver never fires (§6 threat 4). |
| `animation` | `disabled` | Freezes GUI tweens/easing so screens settle immediately — strengthens golden determinism (§6 threats 3, 7). |
| `restoreLastSlotAction` | `no` | Default is `prompt`, which pops a boot-time "restore last quicksave?" dialog (`xroot/Application.lua:475`) that would block a scripted boot. `no` boots straight to home. |
| `enableDevMode` | `false` | Keep the standard dispatcher; no dev-only surfaces. |
| `pickerStyle` | `dense` | Make the picker style explicit so `20-picker-open` is robust to any default drift. |
| `confirm*` | `no` / `false` | Disable the confirmation dialogs (delete/clear/overwrite/scene/etc.) so scripted destructive flows are not intercepted by a modal (§6 threat 4). |

To change a setting for a specific test, prefer a `lua Settings.set(...)` line in
that test over editing this shared fixture.

### `rear/firmware.cfg`
Audio config read by `od/config.c:Config_init` (tokens `SAMPLERATE` /
`FRAMELENGTH`). Optional — the firmware defaults to 48000/128 and only warns if
absent — but pinning it keeps every run identical and the log quiet.

### `front/ER-301/.gitkeep`
Placeholder so the front card's `ER-301/` dir survives in git (empty dirs are
dropped). No real front-card content is committed.

## Packages are NOT committed here

Core mods (`core-*.pkg`, `teletype-*.pkg`, …) are **build products**, not
fixtures, so they are deliberately absent. A test that needs units declares
`!packages core` (see `tests/emu/README.md`); the runner then copies the matching
`.pkg` into the sandbox's front package repository (`front/ER-301/packages/`,
which is where `xroot/Package/Manager.lua:51` scans) from, in order:
`$STOL_EMU_PKG_DIR`, `testing/linux-x86_64/mods/`,
`~/.od/front/ER-301/packages/`, `~/.od/rear/`.

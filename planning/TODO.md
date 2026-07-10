ER-301-STOLMINE TODO (generated — DO NOT EDIT)
=============================================

*Generated from `planning/ledger.toml` by `scripts/dev render`. Edit the
ledger, not this file. Status/verification are gate-enforced (`scripts/dev
check`): a `done` item must have a real test or its named artifact.*

**30 items** — 21 done, 8 todo, 1 blocked. *Rendered 2026-07-09.*

## Sequencer

| | id | item | verify |
|---|---|---|---|
| ✓ | `sequencer-external-clock` | Grid sequencer external clock + reset with per-slot stL honoring | manual *(attested)* · 2026-07-09 |
| ✓ | `sequencer-l1-cancel-revert` | Sequencer L1 CANCEL reverts a cell edit to its pre-edit value | manual *(attested)* · 2026-07-09 |
| ✓ | `sequencer-modal-sweep-hardening` | Sequencer modal-mutual-exclusion sweep: single encoder owner, no colliding modes | manual *(attested)* · 2026-07-09 |
| ✓ | `sequencer-terminal-edit-leds` | Sequencer terminal L1 cell edit + encoder coarse/fine LEDs | manual *(attested)* · 2026-07-09 |

## Scenes / hold-mode

| | id | item | verify |
|---|---|---|---|
| ✓ | `scenes-hold-mode` | Hold-mode scenes with CV-selectable A/B via SceneIndexArbiter | manual *(attested)* · 2026-07-09 |

## UI / interaction

| | id | item | verify |
|---|---|---|---|
| ✓ | `ui-dense-unit-picker` | Dense 2-column unit picker: type glyphs, alphabet ribbon, sort/filter, M-key gestures | screenshot: Admin > Settings > Units > Unit picker style: dense; capture the 2-column layout with type glyphs, alphabet jump ribbon, and section dividers; cycle M2 sort modes and M3 type filter *(attested)* · 2026-07-09 |
| ✓ | `ui-favorites-picker` | Favorites in the unit picker: shift-toggle edit mode, own category above Recents | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-master-output-scale` | Master output scale: percentage-based output level in admin settings | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-quicksave-overwrite-confirm` | Quicksave overwrite confirmation + 48 quicksave slots | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-readout-name-table` | Readout/Fader mapped display text via addName()/clearNames() | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-readout-threshold-labels` | Readout/Fader threshold labels map float ranges to descriptive text | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-screensaver-doom` | Doom screensaver: doomgeneric with autoplay bot, letterboxed to 102x64 | screenshot: select the Doom screensaver manually (not in the cycle list); confirm the bot plays, renders 320x200 letterboxed into a 102x64 viewport, and auto-restarts on death *(attested)* · 2026-07-09 |
| ✓ | `ui-screensavers` | Screensaver suite: snow, rain, forest, maze, perlin, voronoi + cycle mode | screenshot: let the device idle past the screensaver timeout; capture each of snow/rain/forest/maze/perlin/voronoi and confirm cycle mode rotates between them *(attested)* · 2026-07-09 |
| ✓ | `ui-slot-machine-text` | Slot-machine text input: 6 columns under M1-M6, hold-to-focus + encoder scroll | manual *(attested)* · 2026-07-09 |

## DSP units

| | id | item | verify |
|---|---|---|---|
| ✗ | `dsp-stereo-mix-quicksave-drop` | Stereo Mix output drops to silence after quicksave load | manual *(attested)* · 2026-07-09 |
| ✓ | `dsp-parallel-dsp` | Parallel DSP via BUILDOPT_PARALLEL_DSP WorkerPool | manual *(attested)* · 2026-07-09 |

## I2C / external control

| | id | item | verify |
|---|---|---|---|
| ✓ | `i2c-teletype-coexist` | Teletype slave RX coexists with TXo master TX on the shared I2C2 peripheral | manual *(attested)* · 2026-07-09 |
| ✓ | `i2c-txo-master` | TXo I2C master output: interrupt-driven CV/gate TX with gain + V/Oct mode | manual *(attested)* · 2026-07-09 |

## Emulator

| | id | item | verify |
|---|---|---|---|
|   | `emu-capture-deterministic` | Same UI state produces a byte-identical capture | screenshot: drive the emulator to a fixed UI state, settle, and capture twice; confirm the two PNGs are byte-identical (diff clean); document the settle convention for animated elements · 2026-07-09 |
|   | `emu-capture-fb` | Capture command dumps the framebuffers decoded to PNG | screenshot: send 'capture planning/captures/<name>.png'; confirm the main (256x64 4bpp) and sub (128x64 1bpp) DisplayBuffers are decoded pixel-exact to PNG, matching what emu/Window.cpp update() renders on screen · 2026-07-09 |
|   | `emu-cmd-buttons` | Button press/release commands with hold duration via Gpio_write | manual · 2026-07-09 |
|   | `emu-cmd-encoder` | Encoder turn command adjusts encoderValue | manual · 2026-07-09 |
|   | `emu-cmd-toggles` | Storage / mode toggle-switch commands | manual · 2026-07-09 |
|   | `emu-control-channel` | Line-oriented control channel read inside the emulator loop | manual · 2026-07-09 |
|   | `emu-headless-boot` | Emulator boots with --headless (no SDL window), firmware runs, clean exit | manual · 2026-07-09 |
|   | `emu-lua-eval` | Lua expression command routed to the app interpreter (phase 2) | manual · 2026-07-09 |
| ✓ | `emu-ui-pacer-fix` | Emulator UI loop pacer hits real 55 fps (matches hardware refresh) | manual *(attested)* · 2026-07-09 |

## Infrastructure

| | id | item | verify |
|---|---|---|---|
| ✓ | `infra-ledger-regime` | Ledger + BDG regime stood up (gate, render, hooks, blessed entrypoint) | manual *(attested)* · 2026-07-09 |
| ✓ | `infra-package-diagnostics` | Detailed package load diagnostics for .pkg archive + .so ELF failures | manual *(attested)* · 2026-07-09 |
| ✓ | `infra-swig-vanilla-compat` | SWIG pinned to 4.2.1 + runtime version bridge so vanilla community packages load | manual *(attested)* · 2026-07-09 |


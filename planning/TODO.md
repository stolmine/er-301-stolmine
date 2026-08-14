ER-301-STOLMINE TODO (generated — DO NOT EDIT)
=============================================

*Generated from `planning/ledger.toml` by `scripts/dev render`. Edit the
ledger, not this file. Status/verification are gate-enforced (`scripts/dev
check`): a `done` item must have a real test or its named artifact.*

**114 items** — 81 done, 31 todo, 2 archived. *Rendered 2026-08-13.*

## Sequencer

| | id | item | verify |
|---|---|---|---|
|   | `sequencer-enter-in-edit-toggle` | Admin toggle for ENTER-in-edit behavior (advance vs exit) | manual · 2026-07-09 |
|   | `sequencer-gate-len-zero-random` | Include 0 (no-gate / rest) in the gate-len random pool | manual · 2026-07-09 |
|   | `sequencer-shift-home-all-slots` | shift+HOME resets all 4 slot playheads (unified-transport scope) | manual · 2026-07-09 |
| ✓ | `sequencer-bpm-latch-exit` | Sequencer BPM latch releases on UP and on takeover hide (no sticky encoder routing) | manual *(attested)* · 2026-07-09 |
| ✓ | `sequencer-external-clock` | Grid sequencer external clock + reset with per-slot stL honoring | manual *(attested)* · 2026-07-09 |
| ✓ | `sequencer-l1-cancel-revert` | Sequencer L1 CANCEL reverts a cell edit to its pre-edit value | manual *(attested)* · 2026-07-09 |
| ✓ | `sequencer-modal-sweep-hardening` | Sequencer modal-mutual-exclusion sweep: single encoder owner, no colliding modes | manual *(attested)* · 2026-07-09 |
| ✓ | `sequencer-terminal-edit-leds` | Sequencer terminal L1 cell edit + encoder coarse/fine LEDs | manual *(attested)* · 2026-07-09 |

## Scenes / hold-mode

| | id | item | verify |
|---|---|---|---|
|   | `scenes-authoring-edit-guards` | Close remaining scene-authoring edit-leak guards (retroactive gain-unfocus + subchain source-picker) | manual · 2026-07-09 |
|   | `scenes-serialize-roundtrip-verify` | Bench-verify scene serialize/deserialize round-trip end-to-end | manual · 2026-07-09 |
| ✓ | `scenes-hold-mode` | Hold-mode scenes with CV-selectable A/B via SceneIndexArbiter | manual *(attested)* · 2026-07-09 |

## UI / interaction

| | id | item | verify |
|---|---|---|---|
|   | `control-bookmarks-chain-nav` | Bookmark top-level controls into a list for fast hopping through a chain | manual · 2026-07-19 |
|   | `cpu-metering-ui` | More visible / granular CPU metering in the UI | manual · 2026-07-14 |
|   | `crashdiag-ui-flightrecorder-seams` | On-device flight recorder captures UI seam events (P1b) | manual · 2026-07-12 |
|   | `mix-input-native-cv` | Native CV/modulation on the channel mix input slider (SHIFT gesture) | manual · 2026-07-13 |
|   | `ui-audio-editor-selection-ops` | Audio editor: selection-scoped destructive operations (idea) | manual · 2026-07-09 |
|   | `ui-chain-ref-invalidation-link-unlink` | Chain-reference invalidation on stereo link/unlink (LocalChooser / Source.Chooser) | manual · 2026-07-09 |
|   | `ui-core-keyword-type-revamp` | Core package keyword + type revamp: sampling glyph + keyword audit | manual · 2026-07-09 |
|   | `ui-dense-picker-residuals` | Dense picker residual sub-features: I/O-fan sort, admin hidden-units restore list, sub-display preview pane | manual · 2026-07-09 |
|   | `ui-encoder-capture-saturation` | Encoder capture under UI saturation: instrument then de-couple input from render | manual · 2026-07-09 |
|   | `ui-picker-partial-library-load` | Unit picker shows a partial unit list after a degraded card read at boot, with no recovery path | manual · 2026-08-05 |
|   | `ui-screensaver-polish` | Screensaver polish: forest full-screen coverage + rain splash particles | screenshot: run the forest screensaver and confirm full-screen coverage; run the rain screensaver and confirm splash particles on impact · 2026-07-09 |
| ✓ | `control-shift-subdisplay-indicator` | Detect controls with an extra SHIFT sub-display and surface a discoverability indicator | manual *(attested)* · 2026-08-12 |
| ✓ | `crashdiag-ui-arm-toggle` | Expose the crash-diagnostics arm toggle in the normal System Settings menu | manual *(attested)* · 2026-07-12 |
| ✓ | `infra-crash-diag-debug-mode-ui` | Debug-mode admin toggle + on-boot crash screen + past-report viewer | screenshot: with an injected report present, boot shows a 'crash captured' screen; the admin diagnostics viewer lists and displays past reports; captured as a tests/emu golden/trace *(attested)* · 2026-07-10 |
| ✓ | `promote-control-to-top-level` | Promote an inner control to its container's top-level control interface (one action) | manual *(attested)* · 2026-08-13 |
| ✓ | `promote-control-type-spec` | Class-level promotion spec so habitat GainBias subclasses can be promoted | manual *(attested)* · 2026-08-13 |
| ✓ | `ui-chain-replace-picker-favorites` | Chain-UI replace picker opens in normal browse, not favorites-tagging mode | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-dense-unit-picker` | Dense 2-column unit picker: type glyphs, alphabet ribbon, sort/filter, M-key gestures | screenshot: Admin > Settings > Units > Unit picker style: dense; capture the 2-column layout with type glyphs, alphabet jump ribbon, and section dividers; cycle M2 sort modes and M3 type filter *(attested)* · 2026-07-09 |
| ✓ | `ui-favorites-picker` | Favorites in the unit picker: shift-toggle edit mode, own category above Recents | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-master-output-scale` | Master output scale: percentage-based output level in admin settings | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-quicksave-overwrite-confirm` | Quicksave overwrite confirmation + 48 quicksave slots | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-readout-name-table` | Readout/Fader mapped display text via addName()/clearNames() | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-readout-threshold-labels` | Readout/Fader threshold labels map float ranges to descriptive text | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-screensaver-doom` | Doom screensaver: doomgeneric with autoplay bot, letterboxed to 102x64 | screenshot: select the Doom screensaver manually (not in the cycle list); confirm the bot plays, renders 320x200 letterboxed into a 102x64 viewport, and auto-restarts on death *(attested)* · 2026-07-09 |
| ✓ | `ui-screensavers` | Screensaver suite: snow, rain, forest, maze, perlin, voronoi + cycle mode | screenshot: let the device idle past the screensaver timeout; capture each of snow/rain/forest/maze/perlin/voronoi and confirm cycle mode rotates between them *(attested)* · 2026-07-09 |
| ✓ | `ui-settings-picker-scene-categories` | Settings menu splits Unit Picker + Scenes into their own categories | screenshot: open Admin > Settings > Interface; confirm a 'Unit Picker' category (pickerStyle, showFavorites, pickerSectionDividers, pickerDefaultSort, pickerPinFavorites, pickerPinRecents) and a 'Scenes' category (sceneMode), distinct from the catch-all 'Units' and from 'Sequencer' / 'QuickSaves' *(attested)* · 2026-07-09 |
| ✓ | `ui-slot-machine-text` | Slot-machine text input: 6 columns under M1-M6, hold-to-focus + encoder scroll | manual *(attested)* · 2026-07-09 |

## DSP units

| | id | item | verify |
|---|---|---|---|
|   | `dsp-multi-output-followups` | Multi-output framework follow-ups (preset rewriter, picker glyph, topology surfacing, LUT audit) | manual · 2026-07-09 |
|   | `dsp-stolmine-core-package` | Stolmine Core package: multi-output core units, default install with vanilla Core bundled | manual · 2026-07-09 |
|   | `onboard-sample-analysis-browsing` | Onboard sample-content analysis for browsing (waveform/transient/pitch/loudness) | manual · 2026-07-20 |
|   | `polyphony-poly-container` | Polyphony via a 'polyphonize' poly container (transparent voice cloning, MIDI-driven) | manual · 2026-07-15 |
|   | `sample-auto-classification` | Auto-classify samples (loop/one-shot, drum hits, instrument type) for browsing/tagging | manual · 2026-07-20 |
| ✓ | `dsp-multi-output-framework` | Multi-output unit framework: units expose sub-outs picked from LocalChooser, vanilla-safe | manual *(attested)* · 2026-07-09 |
| ✓ | `dsp-parallel-dsp` | Parallel DSP via BUILDOPT_PARALLEL_DSP WorkerPool | manual *(attested)* · 2026-07-09 |
| ⊘ | `dsp-stereo-mix-quicksave-drop` | Stereo Mix output drops to silence after quicksave load | manual *(attested)* · 2026-07-22 |

## I2C / external control

| | id | item | verify |
|---|---|---|---|
| ✓ | `i2c-teletype-coexist` | Teletype slave RX coexists with TXo master TX on the shared I2C2 peripheral | manual *(attested)* · 2026-07-09 |
| ✓ | `i2c-txo-master` | TXo I2C master output: interrupt-driven CV/gate TX with gain + V/Oct mode | manual *(attested)* · 2026-07-09 |
| ✓ | `i2c-txo-passthrough-toggle` | TXo TR/CV units expose a top-level passthrough toggle (I2C-pure send vs audio passthrough) | manual *(attested)* · 2026-07-09 |
| ⊘ | `i2c-sccv-insert-crash` | Crash when inserting sc.cv at the end of a chain (habitats + TXo + Teletype) | manual · 2026-07-22 |

## Emulator

| | id | item | verify |
|---|---|---|---|
| ✓ | `crashdiag-fix-emu-symbolication-base` | Emu symbolication base off by p_vaddr (M3) | manual *(attested)* · 2026-07-10 |
| ✓ | `emu-admin-golden-fragile` | 10-admin-nav pixel golden is env-fragile (font-dependent render across builds) | manual *(attested)* · 2026-07-10 |
| ✓ | `emu-capture-deterministic` | Same UI state produces a byte-identical capture | screenshot: drive the emulator to a fixed UI state, settle, and capture twice; confirm the two PNGs are byte-identical (diff clean); document the settle convention for animated elements *(attested)* · 2026-07-09 |
| ✓ | `emu-capture-fb` | Capture command dumps the framebuffers decoded to PNG | screenshot: send 'cap testing-assets/emu/<name>.png'; confirm the PNG matches the on-screen content of a known static screen (both displays composited) *(attested)* · 2026-07-09 |
| ✓ | `emu-cmd-buttons` | Button press/release commands with hold duration via Gpio_write | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-cmd-encoder` | Encoder turn command adjusts encoderValue | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-cmd-stable` | stable-frames primitive: resolve when N consecutive rendered frames are byte-identical | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-cmd-toggles` | Storage / mode toggle-switch commands | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-control-channel` | Line-oriented control channel read inside the emulator loop | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-harness-runner` | Automated test runner: discovers tests/emu/*.test, drives headless emu, diffs goldens, TAP output | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-headless-boot` | Emulator boots with --headless (no SDL window), firmware runs, clean exit | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-hermetic-sandbox` | Per-run sandbox: front/rear roots built from committed fixtures, no state bleed between runs | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-lua-eval` | Lua expression command routed to the app interpreter | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-seed-flag` | --seed N makes the emulator's RNG deterministic | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-trace-golden` | Golden trace comparison: test runs produce transition logs diffable against baselines and the UI map | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-ui-map` | Machine-readable UI map: contexts as nodes with Lua recognition predicates, gestures as edges | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-ui-pacer-fix` | Emulator UI loop pacer hits real 55 fps (matches hardware refresh) | manual *(attested)* · 2026-07-09 |
| ✓ | `emu-ui-trace-hooks` | UI-seam trace hooks emit frame-stamped structured transition events to the control channel | manual *(attested)* · 2026-07-09 |
| ✓ | `infra-crash-diag-emu-inject` | Emulator affordance to inject a synthetic crash report | manual *(attested)* · 2026-07-10 |
| ✓ | `ui-model-facility` | Deterministic UI model for agent-driven 301 operation (umbrella) | manual *(attested)* · 2026-07-10 |
| ✓ | `ui-model-introspect` | Runtime emu.uiState() — context/focus/controls/slots/affordances as structured data | manual *(attested)* · 2026-07-10 |
| ✓ | `ui-model-planner` | Goal -> gesture-sequence path planner, verified by driving the emu | manual *(attested)* · 2026-07-10 |
| ✓ | `ui-planner-cov-facility` | UI planning-domain coverage expansion — close the 8 uncovered operators + 3 fluent types (umbrella) | manual *(attested)* · 2026-07-11 |
| ✓ | `ui-planner-cov-focus` | Multi-unit focus goal + focused_class derived effect (cause C) | manual *(attested)* · 2026-07-11 |
| ✓ | `ui-planner-cov-modals` | Durable-modal operators cover the modal fluent type (cause D) | manual *(attested)* · 2026-07-11 |
| ✓ | `ui-planner-cov-starts` | Non-boot start states close the 5 return/indirect nav operators (cause A) | manual *(attested)* · 2026-07-11 |
| ✓ | `ui-planner-crawler` | Empirical UI crawler resolves dynamic operators + discovers preconditions (perfect oracle) | manual *(attested)* · 2026-07-10 |
| ✓ | `ui-planner-domain-facility` | UI planning domain — deterministic goal-routing over the 301 UI (umbrella) | manual *(attested)* · 2026-07-10 |
| ✓ | `ui-planner-goal-corpus` | Worked-example goal corpus (goal/plan/trace goldens) + coverage metric | manual *(attested)* · 2026-07-10 |
| ✓ | `ui-planner-state-schema` | Fluent state vocabulary + uiState->fluents projection | manual *(attested)* · 2026-07-10 |

## Documentation

| | id | item | verify |
|---|---|---|---|
|   | `docs-intro-video` | Produce a short intro video for the stolmine firmware | manual · 2026-07-09 |
| ✓ | `docs-porting-guide-301` | 301-ecosystem porting guide for the ledger + BDG regime | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-model-gesture-catalog` | Gesture vocabulary + M1-M6 slot-map operator reference (code-derived) | manual *(attested)* · 2026-07-10 |

## Infrastructure

| | id | item | verify |
|---|---|---|---|
|   | `crashdiag-fix-flush-error-handling` | Flush ignores FatFS write errors, then destroys the only copy (M4) | manual · 2026-07-10 |
|   | `crashdiag-fix-partial-register-capture` | Exc-hook captures only a subset of registers (sp=pc, psr/r1/r8-r11 = ffffffff) on am335x data abort | manual · 2026-07-11 |
|   | `crashdiag-flush-log-ring` | Flush the C-side log ring into the crash report (C2) | manual · 2026-07-12 |
|   | `crashdiag-heap-stats` | Heap pressure + allocation-failure in the crash report (P3, the heap analog of P0) | manual · 2026-07-13 |
|   | `crashdiag-insert-lifecycle-markers` | Flight recorder marks unit construct-complete / first-process (P1c) | manual · 2026-07-12 |
|   | `crashdiag-object-guard-event` | Guard/canary the audio Event object to catch heap corruption near the write (P2) | manual · 2026-07-12 |
|   | `crashdiag-resolve-lr` | Crash report resolves or explicitly flags lr against the module map (C1) | manual · 2026-07-12 |
|   | `crashdiag-ui-heartbeat` | Hang monitor covers the UI/main thread, not just audio (P1a) | manual · 2026-07-13 |
|   | `infra-v0616-port` | Port the TXo I2C master mod to the v0.6.16 stable firmware base | manual · 2026-07-09 |
| ✓ | `crashdiag-fix-flightrec-insert-order` | Flight recorder records unit insert AFTER the risky work, missing the #1 trigger (H3) | manual *(attested)* · 2026-07-10 |
| ✓ | `crashdiag-fix-fwversion-capture-time` | Firmware Version stamped at flush time, not capture time (M2) | manual *(attested)* · 2026-07-11 |
| ✓ | `crashdiag-fix-kernel-fallback-bound` | 'kernel + offset' fallback swallows unknown package addresses (M1) | manual *(attested)* · 2026-07-11 |
| ✓ | `crashdiag-fix-oneshot-guard` | Crash hook must be one-shot: a post-capture nested fault overwrites the real report (H2) | manual *(attested)* · 2026-07-11 |
| ✓ | `crashdiag-fix-package-symbolication` | Offline symbolication of package PCs is broken by design — the headline use case (H1) | manual *(attested)* · 2026-07-10 |
| ✓ | `crashdiag-hang-spin-pc` | Hang stack window catches scheduler/stale frames, not the spin PC, for a leaf livelock | manual *(attested)* · 2026-07-12 |
| ✓ | `crashdiag-review-nits` | Crash-diag review LOW/NIT cleanup batch | manual *(attested)* · 2026-07-10 |
| ✓ | `crashdiag-stack-highwater` | Crash report carries per-task + ISR stack high-water and canary (P0) | manual *(attested)* · 2026-07-12 |
| ✓ | `infra-crash-diag-exc-hook` | SYS/BIOS exception hook captures ExcContext + module map (hardware) | manual *(attested)* · 2026-07-11 |
| ✓ | `infra-crash-diag-flight-recorder` | Flight recorder: ring of recent crash-trigger events | manual *(attested)* · 2026-07-10 |
| ✓ | `infra-crash-diag-format` | Crash report schema v2 + offline symbolication tool | manual *(attested)* · 2026-07-10 |
| ✓ | `infra-crash-diag-hang-watchdog` | Audio-thread heartbeat + WDT catches hangs, not just traps (hardware, later) | manual *(attested)* · 2026-07-12 |
| ✓ | `infra-crash-diag-module-map` | Module map: enumerate kernel + loaded package text/data bases | manual *(attested)* · 2026-07-10 |
| ✓ | `infra-crash-diag-panic-buffer` | Warm-reboot-surviving panic buffer flushed to crash.log on next boot (hardware) | manual *(attested)* · 2026-07-11 |
| ✓ | `infra-crash-diagnostics-debug-mode` | Dev-enabled debug mode captures C-side crash diagnostics (umbrella) | manual *(attested)* · 2026-07-14 |
| ✓ | `infra-ledger-regime` | Ledger + BDG regime stood up (gate, render, hooks, blessed entrypoint) | manual *(attested)* · 2026-07-09 |
| ✓ | `infra-package-diagnostics` | Detailed package load diagnostics for .pkg archive + .so ELF failures | manual *(attested)* · 2026-07-09 |
| ✓ | `infra-swig-vanilla-compat` | SWIG pinned to 4.2.1 + runtime version bridge so vanilla community packages load | manual *(attested)* · 2026-07-09 |
| ✓ | `ui-model-manifest` | Static UI behavior manifest extracted from xroot (extract-and-diff BDG) | manual *(attested)* · 2026-07-10 |
| ✓ | `ui-planner-cov-views` | Concrete expand/collapse slot_control effects make them plannable (cause B) | manual *(attested)* · 2026-07-11 |
| ✓ | `ui-planner-operators` | Typed operator library (precondition->effect + gesture template), BDG-diffed | manual *(attested)* · 2026-07-10 |
| ✓ | `ui-planner-solver` | Classical planner: arbitrary fluent goal -> gesture sequence, verified by driving | manual *(attested)* · 2026-07-10 |


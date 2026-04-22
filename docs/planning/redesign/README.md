# ER-301 Redesign — Decision Export

Snapshot of current conclusions across each design endeavor for the standalone ER-301 redesign. Each file is self-contained — pass any individual file to a domain-specific agent without context loss.

## Index

| # | File | Status |
|---|------|--------|
| 00 | `00-overview-and-roadmap.md` | Project framing, principles, phase timeline |
| 01 | `01-compute-and-power.md` | Locked — CM4/CM5 forward-compat strategy |
| 02 | `02-i2c-architecture.md` | Locked — TXo-follower exposure open |
| 03 | `03-cv-gate-outputs.md` | Locked |
| 04 | `04-audio-and-usb.md` | Locked |
| 05 | `05-midi.md` | Locked (deliberately tight v1 scope) |
| 06 | `06-io-unit-model.md` | Locked |
| 07 | `07-multi-output-units.md` | Principles & UI grammar specified; implementation deferred |
| 08 | `08-mainboard-daughterboard.md` | Locked |
| 09 | `09-form-factor-and-panel.md` | Dimensions locked; layout pending scan/trace prep |
| 10 | `10-controller-section.md` | Fader spec locked; knob count/layout/prefix open |
| 11 | `11-bom-and-cost.md` | Working estimate, April 2026 |

## Open items at a glance

- **i2c:** expose onboard CV/gate as a TXo follower on the leader bus? (file 02)
- **Multi-output units:** discoverability indicator + sub-view motion control assignment (file 07)
- **Controller:** knob count (4 vs 8), knob layout (1×4 vs 2×4), source-unit prefix (`lc.*` vs `pc.*`), encoder-with-LED-ring decision (file 10)
- **Panel layout:** awaiting the scan/trace of the original 301 to establish the underlying grid (file 09)

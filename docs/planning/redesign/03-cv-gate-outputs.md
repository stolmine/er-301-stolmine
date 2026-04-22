# CV/Gate Outputs

**Status:** quantity, voltage swing, and architecture locked. i2c follower exposure open.

## Spec

- **8 channels** of CV/gate output, audio-rate capable.
- **±10V swing** (Eurorack-standard headroom).
- Architecture: 8-channel audio-capable DAC + op-amp output stage.
- Reference design: **TXo (TELEXo)**.
- Available in **both** desktop and Eurorack variants.

## Why TXo-derived

The TXo is the established benchmark for audio-rate CV/gate over i2c in the monome/llllllll ecosystem. Cloning its electrical characteristics gives:
- Known-good output stage topology
- Voltage and timing behavior that matches user expectations
- Familiar mental model for the target audience

## Integration with the unit model

These outputs are **destination units** in the existing 301 unit-oriented I/O model — they do not require a new abstraction or a routing page. See the I/O unit model file for detail.

## Open question

Whether to also present these 8 outputs as a TXo follower on the leader i2c bus, so external leaders (Teletype, etc.) can address them. See i2c architecture file for the pros/cons discussion.

## BOM note

Estimated cost for the 8-channel output stage: ~$26–32. See BOM file.

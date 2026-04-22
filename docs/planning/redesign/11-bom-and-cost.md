# BOM & Cost Baseline

**Status:** working estimate as of April 2026. Refine each Rev. Softest line items flagged.

## Component-level estimate

| Block | Estimate |
|-------|----------|
| Compute (CM4) | ~$90 |
| Audio conversion (codec + analog) | ~$61 |
| 8 CV/gate outputs | ~$26–32 |
| Controller section (faders + knobs + buttons + ADC) | ~$53–85 |
| Front UI (encoder, buttons, OLEDs, LEDs) | ~$51 |
| Connectors | ~$45 |
| Power (USB-PD + ±12V generation) | ~$16 |
| **Components total** | **~$350–440** |

## All-in cost

- **Prototype unit #1** (2 PCBs, assembly, enclosure): ~$700–1050
- **Per-unit at 100-unit beta run:** ~$380–450
- **Implied healthy retail:** $1200–1800

## Comparison

Original ER-301 MSRP: ~$900. The redesign sits above this at retail, justified by:
- Standalone operation (no case required)
- Built-in 8 CV/gate outputs (would otherwise require a TXo expander, ~$300)
- USB audio + MIDI built in
- Larger, premium controller surface

A buyer replacing a small case + ER-301 + TXo + a controller comes out ahead.

## Softest line items (highest cost uncertainty)

1. **Enclosure cost.** Tooling vs. machined-and-anodized vs. folded-sheet trade-offs not yet settled. This can swing per-unit cost ±$50–100.
2. **CV/gate output stage.** TXo-derived design needs to be cost-engineered for 8 channels — original TXo serves 4 at a different price-per-channel.
3. **Knob count.** 4 vs 8 full-size knobs is a $30+ swing per unit at premium quality tiers.

## Refinement plan

- Lock enclosure approach by end of Phase 0.
- Re-cost CV/gate output stage after Rev A bring-up.
- Make knob count call after paper-mockup ergonomics testing (see form factor file).

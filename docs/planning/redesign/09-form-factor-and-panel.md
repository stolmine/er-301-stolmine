# Form Factor & Panel Design

**Status:** dimensions and front-panel decisions locked. Detailed panel layout pending the scan/trace prep task.

## Reference dimensions (original ER-301)

- **Width:** 30HP (~152mm)
- **Height:** 3U panel (~128.5mm), ~110–115mm usable between rails

## Desktop variant target

- **Total width:** ~250–300mm (Octatrack / MPC One class, pedalboard-friendly).
- The desktop panel can extend well beyond 30HP to accommodate the added controller section.

## Eurorack variant target

- 30HP-compatible footprint preserved where possible.
- The 12HP fader band (4 × 60mm ALPS faders at 16n standard pitch) fits within 3U.

## Front-panel decision: keep Eurorack I/O populated on desktop

The desktop variant **keeps the front 3.5mm Eurorack jacks populated** rather than depopulating them.

**Reasoning:**
- The shared mainboard commits the jack footprints and routing anyway — depopulating only saves ~$25 per unit but adds variant-specific assembly complexity.
- Partial-rack users are a key early-adopter cohort; they need the jacks.
- Visual jack density reads as **capability** to desktop buyers (cf. Octatrack, Syntakt, OP-1 Field), not as alienation. Jacks are shorthand for "this patches external gear" — supports the hybrid-rig positioning rather than undermining it.
- The front face is the face. It's worth not compromising.

## Aesthetic principle

Preserve the original 301 design language:
- Tight grid discipline
- Functional grouping with visible separation
- Minimal typography
- Restrained color (gray panel, accents in blue / red)
- Jack organization by signal type

The new controller section must observe the **same underlying grid** as the original (likely 1HP × 5mm vertical) so it reads as native rather than bolted-on. Controller section sizing and spacing on HP boundaries; buttons visually consistent with existing 301 button style.

## Near-term prep task — scan and trace the original 301

Before any panel layout work, establish the underlying grid by reverse-engineering the original module:

1. **600 DPI flatbed scan** of the panel for visual reference.
2. **Calipers on the physical module** for grid measurements. **Calipers win on disagreement** — the scan is for visual reference, the calipers are for ground truth.
3. Capture:
   - Panel outline
   - All cutouts with coordinates
   - Grid as construction lines
   - Component depths
4. **Tools:** Inkscape for the initial trace. Migrate to KiCad / mechanical CAD for hardware work.
5. **Print 1:1 paper mockups** for ergonomics testing before any PCB commit.

This trace is the foundation for both variants' panel layout and is a hard prerequisite for Phase 3 hardware design.

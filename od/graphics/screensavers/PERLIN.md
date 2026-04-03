# Perlin Noise Screensaver

## Noise Engine

Reused from er-301-habitat's `RaindropGraphic.h` (petrichor unit). Standard 2D perlin noise with permutation table, wrapped in FBM for multi-octave detail.

- `noise(x, y)` — single octave with gradient hashing and quintic fade
- `fbm(x, y, octaves)` — fractional brownian motion, freq doubles / amp halves per octave

## Field Evaluation

128x32 grid evaluated per frame, 2x upscaled to both displays.

**Domain warping:** single-octave noise offsets the field lookup coordinates, creating organic morphing. Warp strength modulates via sine. Two offset lookups (at different seeds) produce independent x/y distortion.

**Drift:** field scrolls in a slowly rotating direction via `sin/cos` on the time variable rather than a fixed linear scroll.

**Scale modulation:** base noise scale oscillates gently for a breathing zoom effect.

## Rendering

### Fill Mode
Noise value (0–255) maps directly to grayscale brightness (BLACK–WHITE). Straightforward terrain heightmap visualization.

### Contour Mode
Marching squares at 6 evenly spaced thresholds (36, 72, 108, 144, 180, 216). Higher elevation contours are drawn brighter (GRAY3–GRAY13). Edge crossings are interpolated for smooth lines.

### Absorption Transition

The two modes are not crossfaded — they are interpolated per-cell using the warp field as a transition mask.

1. **Warp magnitude** is stored per grid cell — how much domain warping distorted that region
2. A **sine oscillator** (~40s cycle) sweeps a threshold up and down
3. Cells whose warp magnitude exceeds the threshold **absorb** — their fill brightness drains to black while contour lines brighten
4. High-warp cells absorb first on the way up and release last on the way down, creating an organic wavefront
5. Per-cell `mAbsorption` ramps smoothly at warp-proportional speed — no hard cuts

Fill brightness = `base × (1 − absorption)`
Contour brightness = `base × absorption`

The absorption wavefront is the interpolation.

## Sub Display (128×64)

Mirrors the absorption cycle using the sub display's binary pixel constraint:

- **Fill regions:** stipple density via permutation table hash as a spatial threshold. Higher noise = denser stipple. Density scales down by `(1 − absorption)`.
- **Absorbed regions:** low-res contour lines using step-4 marching squares (effectively 32×8 cells), 4 threshold levels. Contours appear as soon as absorption begins.

## Registration

- C++ factory: `UIThread::setScreenSaver()` in `od/UIThread.cpp`
- Cycle list: `cycleList[]` in `od/UIThread.cpp`
- Lua settings: `screenSaverGraphics.choices` in `xroot/Settings/init.lua`

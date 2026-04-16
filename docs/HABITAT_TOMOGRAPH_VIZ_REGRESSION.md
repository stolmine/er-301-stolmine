# Habitat Tomograph overview viz regression (2026-04-13)

> **RESOLVED 2026-04-16 — root cause: `sinf`/`cosf` from a package `.so` miscompute on am335x.**
> A perfect circle drawn from `cosf(a)*r, sinf(a)*r` came out with a distended bottom lobe
> and extra line-like artifacts. Replacing the runtime calls with precomputed
> `static const float kLutCos[72]`/`kLutSin[72]` (at `a = 2*pi*i/N - pi/2`) rendered the
> expected geometry. Firmware-side `sinf`/`cosf` (e.g. ScaleQuantizer's PitchCircle in
> `app.bin`) are unaffected — the bug is specific to the package → firmware call
> boundary. SWIG version, habitat source, dev host, vtable layout, and primitives were
> all ruled out during diagnosis. Fix reference: `FilterResponseGraphic.h` at top of
> file (`kLutCos`/`kLutSin`/`lutCos`/`lutSin`). Root cause (package→libm symbol
> resolution drift, or FPU ABI mismatch on dlopen'd `.so`) not pinned down; the LUT
> workaround is robust regardless. Apply the same pattern to any future package-side
> circular/rotational graphic. See stolmine memory `project_package_trig_bug.md` and
> habitat memory `feedback_package_trig_lut.md` for the standing guidance.

---


Tracking a hardware-only visual regression in the Tomograph / Filterbank unit
shipped in the habitat `spreadsheet` package (unit module `Filterbank`,
display name `Tomograph`). Filed here because the habitat code is unchanged
from v2.0.0 (released 2026-04-09) to current, so the suspect surface is the
firmware side.

## Habitat code state

- `er-301-habitat/mods/spreadsheet/FilterResponseGraphic.h` is **byte-identical**
  to v2.0.0 (`git diff v2.0.0..HEAD --` shows zero lines of change across
  Filterbank.cpp, Filterbank.h, FilterResponseGraphic.h, BandListGraphic.h).
- The radial "ferrofluid ring" viz uses a bumpy-perimeter polyline, a gradient
  radial fill, per-band spoke lines, and a selected-band dot. All via
  `fb.line`, `fb.circle`, `fb.fillCircle`, `fb.pixel`.
- Graphic dimensions: 86 wide x 64 tall (2 x SECTION_PLY). Constructed from
  Lua as `libstolmine.FilterResponseGraphic(0, 0, width, 64)`.

## Symptoms on hardware

Reported on firmware `v0.7.0-stolmine.9.0.0` (current release) and persists on
`8.6.3` (earlier tested). Emulator does NOT reproduce.

Across progressive diagnostic builds user observed, roughly in sequence as
the user manipulates params:

1. **Default (2 bands at 62 Hz + 988 Hz, rotate=0)**: polyline is the correct
   horizontal figure-8 (spokes at 3 and 9 o'clock) BUT an extra polyline
   segment extends straight down from the figure.
2. **With no input audio**: bottom lobe of the lemniscate appears "distended"
   relative to the top even though my math trace says top and bottom should
   be perfectly symmetric (both at baseR=10 px).
3. **With more bands and rotate=-1 or -7**: one or two band-spoke lines
   appear "pinned" (don't move when rotate changes) and indicators bunch
   near the bottom. Earlier builds (before bbox clamp) had one spoke
   extending all the way off-graphic to the left edge of the screen at
   rotate=-7.

## What I ruled out (all in habitat-side code)

- **NaN/inf propagation through currentFreq / logf / int-cast** -- added
  explicit `isfinite`-style guards, no change in behavior.
- **Draw endpoints escaping graphic bbox** -- added per-call clamps on every
  px/py/edgeX/edgeY. Prevented the off-graphic extension but not the
  intra-graphic artifacts.
- **Stack corruption from large locals on the GUI thread** -- moved
  `float rawBumps[72] / sampleR[72] / int px[72] / py[72] / float values[16] /
  freqLog[16] / bandAngles[16] / bandBump[16]` to heap member variables (same
  treatment applied successfully to HelicasePhaseGraphic). No change.
- **Double rotation** between DSP `distributeFrequencies` rotate shift and
  graphic `rotateOffset` -- removing the graphic offset changed character
  in a way the user didn't want; restored.
- **Band frequency collision** (two bands at same freq producing a merged
  lobe) -- user confirmed distinct frequencies via the band list.

## Math trace (confirms expected, not what hardware shows)

For the 2-band case, 62 Hz + 988 Hz, rotate=0, all gains=1, zero energy:

```
freqLog    = {ln(62),  ln(988)}    = {4.127, 6.896}
logLo      = 4.127                 logHi = 6.896
logRange   = 2.769                 avgSpacing = 2.769 (bandCount-1 = 1)
After pad: logLo = 2.742, logRange = 5.538

bandAngles[0] = 2π·(4.127-2.742)/5.538 - π/2 = 2π·0.25 - π/2 = 0       (3 o'clock)
bandAngles[1] = 2π·(6.896-2.742)/5.538 - π/2 = 2π·0.75 - π/2 = π       (9 o'clock)

bandBump[i] = 19 px for both (values=0.3, maxVal=0.3, bumpRange=19)

Gaussian sum with sigma=0.2 rad:
  At step 18 (right):  rawBump = 19·e^0 + 19·e^(-π²·12.5) ≈ 19
  At step 0 (top):     rawBump ≈ 19·e^(-(π/2)²·12.5) ·2 ≈ 0
  At step 36 (bottom): same as top ≈ 0
  maxBump = 19, bumpScale = 1

sampleR at band centers   = baseR + 19·1 = 29 (full maxR)
sampleR at top and bottom = baseR + 0    = 10 (baseR)
```

Polyline traces 72 points around a lens/figure-8 with horizontal axis. Top
(step 0) and bottom (step 36) both land on `(cx, cy ± 10)` -- exactly
symmetric.

## Likely suspects, firmware side

Drawing primitives used by this graphic, in order of how many calls per
frame and how ARM-sensitive they feel:

1. **`od::FrameBuffer::line(color, x0, y0, x1, y1)`** -- called in the
   closed-polyline loop (72 times per frame), in the gradient fill (up to
   16 per gradient step), and for band spokes. Any Bresenham / clipping
   change here would affect all three paths.
2. **`od::FrameBuffer::fillCircle(color, x, y, r)`** -- called for the
   selected-band dot.
3. **`od::FrameBuffer::circle(color, x, y, r)`** -- called once for the
   reference outline.

Questions worth chasing in the firmware:

- Has anything in `od/graphics/primitives/*` (Bresenham line, rasterizer,
  clipping) changed between the firmware paired with habitat v2.0.0 and the
  current release?
- Does `fb.line` clip to graphic bbox or to framebuffer bbox on this code
  path? The symptom before the habitat-side bbox clamps was "line extending
  all the way to left edge of the virtual space" -- suggesting framebuffer-
  wide clipping, which is inconsistent with how the Scope's MiniScope
  seems to handle bounds.
- Has the parent-child graphic compositor (how `mWorldLeft`, `mWorldBottom`
  get populated from parent layout) changed? The overview control wraps the
  `FilterResponseGraphic` in an `app.Graphic(0,0,width,64)`, relying on
  parent positioning.
- Are there ARM-specific rasterizer tweaks (e.g., subpixel handling, anti-
  aliasing, gamma) that might render the same coordinates differently on
  am335x?
- Has `fb.circle` changed behavior where the circle is drawn outside the
  graphic's logical bbox but inside the physical framebuffer?

## What's strange

- The "distended bottom lobe" is visible even with no audio input -- so it
  isn't driven by band energy or a live DSP value that differs between emu
  and hardware. Just the static geometry.
- The "extra straight-down polyline segment" has no obvious source in the
  habitat-side draw code. All 72 polyline segments connect adjacent
  perimeter samples; the closing wrap connects `px[71] -> px[0]` which are
  both near the TOP of the figure, not the bottom.

## Reproduction

1. Boot hardware with current firmware and the rebuilt habitat
   `spreadsheet-2.1.0.pkg` (which is the v2.0.0 graphic code).
2. Insert Tomograph in a mono chain.
3. Set band count to 2, scale to chromatic (default), rotate to 0, no audio
   input.
4. Navigate to the overview ply.
5. Observe the extra vertical line / distended bottom lobe.

Emu does not reproduce.

## Next steps (firmware side, if pursued)

- Capture a framebuffer dump or screenshot during the stuck state.
- Bisect firmware commits between the v2.0.0 release timestamp
  (2026-04-09) and current release, focusing on changes in
  `od/graphics/*` primitives.
- Add a sanity log statement inside `fb.line` / `fb.fillCircle` to dump
  the actual endpoints being received on hardware for this graphic, and
  compare to the expected endpoints we compute analytically.
- Consider whether any shared framebuffer bit is being stomped by an
  adjacent graphic render earlier in the frame.

Filed by: habitat v2.1.0 release prep investigation, session 2026-04-13.

## 2026-04-12 follow-up: firmware-side timeline audit

Cross-referenced habitat commits touching Filterbank/Tomograph against
firmware history in the suspect surface (FrameBuffer, primitives,
compositor).

### Timeline

| Date       | Event                                                                                  |
|------------|----------------------------------------------------------------------------------------|
| 2026-04-02 | habitat `1fa085a` — rename Filterbank → Tomograph                                      |
| 2026-04-04 | habitat `9d32b42` — split stolmine into spreadsheet + biome (last habitat Tomograph touch) |
| 2026-04-04 | **firmware `00f2992` — Move `readPixel` to end of FrameBuffer vtable for vanilla ABI compat** |
| 2026-04-05 | firmware tag `v0.7.0-txo.8.6.3` (earliest firmware tested in this report)              |
| 2026-04-09 | firmware tag `v0.7.0-stolmine.9.0.0` (current)                                         |
| 2026-04-09 | habitat tag `v2.0.0`                                                                   |
| 2026-04-12 | habitat tag `v2.1.0`                                                                   |

### What has changed in the suspect surface since the last Tomograph habitat touch

- `od/graphics/FrameBuffer.h`: exactly **one** commit in history — `00f2992`,
  the vtable reorder. No other changes.
- `od/graphics/primitives/*`: zero commits since repo first commit.
- Parent/child compositor, `mWorldLeft`/`mWorldBottom` plumbing: zero recent
  touches.

The only firmware-side change in the entire suspect surface since the habitat
Tomograph code was last edited is the vtable reorder.

### Why this is the strongest lead

`00f2992`'s own commit message:

> readPixel was inserted between pixel() and clear(), shifting every
> subsequent vtable slot by one. Packages compiled against vanilla headers
> called the wrong methods, **causing garbled graphics on TXo firmware**.

"Garbled graphics" from a one-slot vtable shift is an exact phenotype match
for "extra polyline segment, distended lobe, pinned spokes" — `line` would
resolve to `hline`/`vline`, `circle` would resolve to `fillCircle`, etc.
Drawing code asks for a line between two points, the firmware runs a
different primitive with the same argument shape. Emu doesn't reproduce
because the emu build links the package against the same headers it runs
against, so vtable slots stay aligned even if mis-ordered.

### Why both tested firmwares being post-fix doesn't rule this out

The fix corrects the **firmware's** vtable layout. It does nothing for a
`.pkg` whose vtable offsets were baked in at compile time against a
different `FrameBuffer.h`. If the installed `spreadsheet-2.1.0.pkg` was
built against vanilla headers or a pre-`00f2992` stolmine SDK, it carries
the old slot assignments and mismatches the running firmware regardless of
which post-fix firmware is booted.

`er-301-habitat/scripts/env.mk` sets `SDKPATH ?= er-301`, and
`er-301-habitat/er-301/` is currently at stolmine `develop` tip (post-fix),
so a fresh local build of the package should align. The question is what
was on the SD card at the time of the report.

### Pre-bisect check (cheaper than the bisect suggested above)

Before bisecting firmware commits:

1. `cd er-301-habitat && make spreadsheet-clean && make spreadsheet ARCH=am335x`
2. Reinstall the freshly built `spreadsheet-2.1.0.pkg` on the SD card
   (overwriting whatever is there).
3. Reboot hardware, reproduce per the steps above.

If the artifact disappears, the installed package was built against stale
or vanilla headers and the fix is "always rebuild spreadsheet against
current stolmine SDK after any `od/graphics/FrameBuffer.h` change."

If the artifact persists after a verified-fresh build against current
`er-301-habitat/er-301/`, the vtable hypothesis is eliminated and the
firmware bisect becomes the next move — but note that the bisect window
will be small: only `00f2992` touches the suspect surface in the relevant
timeframe, so a "bisect" is really a single-commit test of
`HEAD` vs `00f2992^`.


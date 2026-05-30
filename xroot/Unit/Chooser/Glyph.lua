-- Keyword-to-glyph dispatch for the unit picker (both classic and
-- dense views). Reads loadInfo.keywords (comma-separated string),
-- takes the first keyword, normalizes to lowercase, and looks up
-- the class glyph.
--
-- Mapping derived from an audit of the installed package universe
-- on 2026-05-30 (12 packages, ~220 keyword uses). See
-- docs/planning/unit-picker-overhaul.md for the rationale.

local Glyph = {}

Glyph.SOURCE   = "~"
Glyph.EFFECT   = ">"
Glyph.MODULATE = "$"
Glyph.TIMING   = "*"
Glyph.UTILITY  = "."
Glyph.UNKNOWN  = "?"

-- Ordered cycle for the M3 type filter. UNKNOWN is intentionally
-- last so users don't waste cycles on it.
Glyph.cycleOrder = {
  Glyph.SOURCE, Glyph.EFFECT, Glyph.MODULATE,
  Glyph.TIMING, Glyph.UTILITY, Glyph.UNKNOWN,
}

-- Human-readable class name for a given glyph. Used by section
-- dividers in 'type' sort mode so users learn which glyph means
-- what without having to memorize the legend separately.
local kClassLabel = {
  [Glyph.SOURCE]   = "source",
  [Glyph.EFFECT]   = "effect",
  [Glyph.MODULATE] = "modulate",
  [Glyph.TIMING]   = "timing",
  [Glyph.UTILITY]  = "utility",
  [Glyph.UNKNOWN]  = "unknown",
}

function Glyph.labelFor(glyph)
  return kClassLabel[glyph] or "unknown"
end

-- Category dispatch (higher-priority signal than keywords). Core
-- units use functional categories ("Oscillators", "Filtering",
-- etc.) that map cleanly to the glyph taxonomy. Third-party
-- packages mostly use vendor-name categories ("Biome", "MI",
-- "Peaks", ...) that carry no type info -- those don't appear in
-- this table and fall through to keyword dispatch.
--
-- Empty / mixed-bag categories ("Essentials", "Experimental")
-- intentionally NOT mapped here so they fall through to per-unit
-- keyword dispatch -- a mixed category shouldn't force every unit
-- in it to the same glyph.
local kCategoryToGlyph = {
  ["Oscillators"]                = Glyph.SOURCE,
  ["Noise"]                      = Glyph.SOURCE,
  ["Sample Playback"]            = Glyph.SOURCE,
  ["Granular Playback"]          = Glyph.SOURCE,
  ["Filtering"]                  = Glyph.EFFECT,
  ["Delays and Reverb"]          = Glyph.EFFECT,
  ["Effect"]                     = Glyph.EFFECT,
  ["Envelopes"]                  = Glyph.MODULATE,
  ["Modulation"]                 = Glyph.MODULATE,
  ["Mapping and Control"]        = Glyph.MODULATE,
  ["Timing"]                     = Glyph.TIMING,
  ["Sequencer"]                  = Glyph.TIMING,
  ["Sequencers"]                 = Glyph.TIMING,
  ["Measurement"]                = Glyph.UTILITY,
  ["Measurement and Conversion"] = Glyph.UTILITY,
  ["Containers"]                 = Glyph.UTILITY,
  ["Recording and Looping"]      = Glyph.UTILITY,
}

-- Keyword (lowercased) -> class glyph. Every keyword seen in any
-- installed package's toc.lua gets a home; anything unlisted falls
-- through to UNKNOWN.
local kKeywordToGlyph = {
  -- Source class
  source       = Glyph.SOURCE,
  generator    = Glyph.SOURCE,
  oscillator   = Glyph.SOURCE,
  noise        = Glyph.SOURCE,
  drum         = Glyph.SOURCE,
  drums        = Glyph.SOURCE,
  percussion   = Glyph.SOURCE,
  kick         = Glyph.SOURCE,
  snare        = Glyph.SOURCE,
  cymbal       = Glyph.SOURCE,
  ["808"]      = Glyph.SOURCE,
  synth        = Glyph.SOURCE,
  synthesis    = Glyph.SOURCE,
  synthesizer  = Glyph.SOURCE,
  voice        = Glyph.SOURCE,
  string       = Glyph.SOURCE,
  bow          = Glyph.SOURCE,
  blow         = Glyph.SOURCE,
  chime        = Glyph.SOURCE,
  gong         = Glyph.SOURCE,
  exciter      = Glyph.SOURCE,
  bytebeat     = Glyph.SOURCE,
  pulse        = Glyph.SOURCE,
  tone         = Glyph.SOURCE,
  particle     = Glyph.SOURCE,
  dust         = Glyph.SOURCE,
  crackle      = Glyph.SOURCE,

  -- Effect class
  effect       = Glyph.EFFECT,
  filter       = Glyph.EFFECT,
  delay        = Glyph.EFFECT,
  reverb       = Glyph.EFFECT,
  echo         = Glyph.EFFECT,
  hall         = Glyph.EFFECT,
  plate        = Glyph.EFFECT,
  shimmer      = Glyph.EFFECT,
  diffusion    = Glyph.EFFECT,
  distortion   = Glyph.EFFECT,
  saturation   = Glyph.EFFECT,
  waveshaper   = Glyph.EFFECT,
  waveshape    = Glyph.EFFECT,
  shaper       = Glyph.EFFECT,
  fold         = Glyph.EFFECT,
  comb         = Glyph.EFFECT,
  compressor   = Glyph.EFFECT,
  dynamics     = Glyph.EFFECT,
  eq           = Glyph.EFFECT,
  bandpass     = Glyph.EFFECT,
  lp           = Glyph.EFFECT,
  hp           = Glyph.EFFECT,
  ["ring mod"] = Glyph.EFFECT,
  glitch       = Glyph.EFFECT,
  stutter      = Glyph.EFFECT,
  reverse      = Glyph.EFFECT,
  freeze       = Glyph.EFFECT,
  resonator    = Glyph.EFFECT,
  resonant     = Glyph.EFFECT,
  spectral     = Glyph.EFFECT,
  spectrum     = Glyph.EFFECT,
  multiband    = Glyph.EFFECT,
  multitap     = Glyph.EFFECT,
  morph        = Glyph.EFFECT,
  texture      = Glyph.EFFECT,
  formant      = Glyph.EFFECT,
  granular     = Glyph.EFFECT,
  sampling     = Glyph.EFFECT,
  fir          = Glyph.EFFECT,
  fft          = Glyph.EFFECT,
  convolution  = Glyph.EFFECT,
  sidechain    = Glyph.EFFECT,
  crossover    = Glyph.EFFECT,
  pitch        = Glyph.EFFECT,
  wavetable    = Glyph.EFFECT,
  fm           = Glyph.EFFECT,
  scan         = Glyph.EFFECT,
  varishape    = Glyph.EFFECT,
  warp         = Glyph.EFFECT,
  warps        = Glyph.EFFECT,
  feedback     = Glyph.EFFECT,
  tilt         = Glyph.EFFECT,
  zplane       = Glyph.EFFECT,
  ice          = Glyph.EFFECT,

  -- Modulate class
  modulate          = Glyph.MODULATE,
  modulation        = Glyph.MODULATE,
  cv                = Glyph.MODULATE,
  lfo               = Glyph.MODULATE,
  envelope          = Glyph.MODULATE,
  envelopes         = Glyph.MODULATE,
  random            = Glyph.MODULATE,
  slope             = Glyph.MODULATE,
  slew              = Glyph.MODULATE,
  ["function"]      = Glyph.MODULATE,
  ["sample and hold"] = Glyph.MODULATE,
  offset            = Glyph.MODULATE,
  follower          = Glyph.MODULATE,
  curve             = Glyph.MODULATE,
  chaos             = Glyph.MODULATE,
  probability       = Glyph.MODULATE,
  gendy             = Glyph.MODULATE,
  flakes            = Glyph.MODULATE,
  petrichor         = Glyph.MODULATE,
  tomograph         = Glyph.MODULATE,
  geometry          = Glyph.MODULATE,
  procedural        = Glyph.MODULATE,
  neural            = Glyph.MODULATE,
  network           = Glyph.MODULATE,
  seed              = Glyph.MODULATE,
  parfait           = Glyph.MODULATE,
  station_x         = Glyph.MODULATE,

  -- Timing class
  timing       = Glyph.TIMING,
  trigger      = Glyph.TIMING,
  gate         = Glyph.TIMING,
  clock        = Glyph.TIMING,
  sequencer    = Glyph.TIMING,
  rhythm       = Glyph.TIMING,
  ratchet      = Glyph.TIMING,
  euclidean    = Glyph.TIMING,
  step         = Glyph.TIMING,
  sync         = Glyph.TIMING,
  transport    = Glyph.TIMING,
  breakbeat    = Glyph.TIMING,
  dj           = Glyph.TIMING,

  -- Utility class
  utility      = Glyph.UTILITY,
  container    = Glyph.UTILITY,
  multi        = Glyph.UTILITY,
  multiout     = Glyph.UTILITY,
  mixer        = Glyph.UTILITY,
  mixing       = Glyph.UTILITY,
  crossfade    = Glyph.UTILITY,
  fade         = Glyph.UTILITY,
  measure      = Glyph.UTILITY,
  measurement  = Glyph.UTILITY,
  monitor      = Glyph.UTILITY,
  scope        = Glyph.UTILITY,
  analyzer     = Glyph.UTILITY,
  detector     = Glyph.UTILITY,
  i2c          = Glyph.UTILITY,
  txo          = Glyph.UTILITY,
  teletype     = Glyph.UTILITY,
  output       = Glyph.UTILITY,
  input        = Glyph.UTILITY,
  router       = Glyph.UTILITY,
  quantizer    = Glyph.UTILITY,
  map          = Glyph.UTILITY,
  mapper       = Glyph.UTILITY,
  matrix       = Glyph.UTILITY,
  learn        = Glyph.UTILITY,
  latch        = Glyph.UTILITY,
  recorder     = Glyph.UTILITY,
  looper       = Glyph.UTILITY,
  bank         = Glyph.UTILITY,
  slicer       = Glyph.UTILITY,
  spreadsheet  = Glyph.UTILITY,
}

-- Primary entry point: return the glyph for a loadInfo. Cascading
-- dispatch:
--   1. category lookup (high-confidence signal for core units;
--      most third-party vendor-name categories miss and fall
--      through to step 2)
--   2. first keyword in the comma-separated keywords field
--   3. UNKNOWN
-- Robust to nil / empty / whitespace / case.
function Glyph.forLoadInfo(loadInfo)
  if loadInfo == nil then return Glyph.UNKNOWN end
  -- Step 1: category dispatch.
  local cat = loadInfo.category
  if cat and kCategoryToGlyph[cat] then
    return kCategoryToGlyph[cat]
  end
  -- Step 2: first-keyword dispatch.
  local kws = loadInfo.keywords
  if kws == nil or kws == "" then return Glyph.UNKNOWN end
  local first = kws:match("^%s*([^,]-)%s*,") or kws:match("^%s*(.-)%s*$")
  if first == nil or first == "" then return Glyph.UNKNOWN end
  return kKeywordToGlyph[first:lower()] or Glyph.UNKNOWN
end

-- Test predicate for the M3 overlap-aware type filter: returns true
-- if any keyword in loadInfo's keyword list maps to the given glyph.
-- Used so a unit tagged "effect, container" appears in BOTH the
-- effect (>) filter and the utility (.) filter.
function Glyph.loadInfoMatchesGlyph(loadInfo, glyph)
  if loadInfo == nil then return glyph == Glyph.UNKNOWN end
  local kws = loadInfo.keywords
  if kws == nil or kws == "" then return glyph == Glyph.UNKNOWN end
  for kw in kws:gmatch("([^,]+)") do
    local clean = kw:match("^%s*(.-)%s*$"):lower()
    if kKeywordToGlyph[clean] == glyph then return true end
  end
  return false
end

return Glyph

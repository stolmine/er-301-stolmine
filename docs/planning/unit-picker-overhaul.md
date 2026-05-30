# Unit Picker overhaul — implementation plan

**Status:** scope locked 2026-05-30 on `develop`. Companion to the
TODO entry `Unit Picker Readability + Editability`; this doc is the
working plan for the complete overhaul. Where this doc and the TODO
entry disagree, this doc supersedes (the TODO entry is a sketch,
this is the build spec).

**Goal in one sentence:** replace the current Mondrian
rectangle-per-unit picker with a 2-column Tufte-style dense list +
alphabet ribbon + keyword-driven facet filter, selectable from the
admin menu so the classic view coexists indefinitely.

**Non-goals:** fuzzy text search (gated on the `Slot Machine Text
Input` TODO entry), drag-reorder within categories, picker rewrite
for the vanilla v0.7.x firmware (this is stolmine-only).

---

## Coexistence model

Both views ship together. Admin setting `picker.style` chooses:

- `classic` — current `MondrianMenu` + `Default.lua` picker. Default
  for existing users so upgrade is invisible.
- `dense` — the new view in this plan. Default for fresh installs.

Both views read the same `loadInfo` schema, the same `favorites.lua`,
and the same new `hidden.lua`. Switching styles is live (next picker
open uses the new style). No migration needed.

---

## Layout spec (grounded in sequencer constants)

Display: main 256 × 64 px, sub 128 × 64 px. Y runs bottom-up.

### Font + spacing budget (cribbed from `xroot/Sequencer/GridView.lua`)

The sequencer proved the following on-hardware constraints; we reuse
them verbatim where possible:

| Element | Value | Source |
|---|---|---|
| Cell font | 9 px | `kFontMain = 9` |
| Sub-display font | 10 px | `kFontSub = 10` |
| Row pitch | 9 px (font + 1 px margin) | `kRowHeight = 9` |
| Visible cell rows | 6 below a header | `kVisibleRows = 6` |
| Column pitch | 42 px (`app.SECTION_PLY`) for 6-col layouts | `kColPly` |
| Brightness scale | dim=2, normal=6, focus=9, playhead=11, both=15 | `kBright*` |
| Cursor easing | 0.4 lerp, 0.5 px snap | `kCursorEase` |
| Encoder threshold | 3 (Default) | `Env.EncoderThreshold.Default` |
| Custom shapes | `app.Drawing` + `app.DrawingInstructions` | sequencer L2 fire / selection / dirty drawings |

At font 9 the average glyph is ~5 px wide. The 256 px main display
holds ~50 chars, the 128 px sub ~25 chars.

### Main display zones (top to bottom)

```
y=55..63   alphabet ribbon (1 row, 9 px tall, full width 256 px)
y=46..54   blank gutter (1 px) + first unit row top edge
y= 9..45   five unit rows at 9 px pitch (2 cols, left + right)
y= 0.. 8   M-key chip footer (1 row, 9 px tall)
```

5 unit rows × 2 columns = **10 visible units per screen** (vs ~5 in
the current Mondrian view).

Column layout (at font 9, 5 px/char average):
- Left column: x = 4..124 (~120 px, 24 chars usable)
- Mid divider: x = 125..127 (3 px, 1 px vertical hairline at x=126)
- Right column: x = 128..248 (~120 px, 24 chars usable)
- Right gutter: x = 249..255 (cursor pip)

Per unit row content (24 chars budget):
```
| ~ unit-name-here ::::: |
  ^ type glyph (1ch)
    ^^^^^^^^^^^^^^ name (~17ch usable after glyph + space + pad)
                   ^^^^^ recency sparkline (5ch, right-aligned)
```

### Sub display layout

```
y=54..63   focused unit title + library (font 10, 1 row)
y=45..53   I/O fan + CPU class (font 10)
y= 9..44   keyword stack: up to 4 lines at font 9 (4 px gap)
y= 0.. 8   S1-S3 chip labels
```

The keyword stack replaces the recency-counter line from the
earlier sketch. Each keyword renders on its own line so a unit
tagged `source, pitch, modulate` reads as a tidy three-line stack,
not a comma-truncated blob. Units with no keywords show a single
"(untagged)" line. Recency info moves into the sparkline on the
main display, where it's always visible during scanning rather
than only on the focused unit.

### Main display ASCII mock (5 rows × 2 cols + ribbon + footer)

```
+-----------------------------------------------------+ y=63
|◊ A B C D E F G H I J K L M[N]O P Q R S T U V W X Y Z #|  ribbon
+-----------------------------------------------------+
|    ~ sine          ::: |   $ env-ar        :...     |  row 1
|  *[> filter]       ::. | [$ env-adsr]     :::..     |  row 2 (cursor)
|    > vca           ::. |   . slew          ....     |  row 3
|    > compressor    :.  |   ? rand         :::::     |  row 4
|    > distortion    ::: |   . sample-hold   ...      |  row 5
+-----------------------------------------------------+
| [pickL]  [sort]  [type]  [pickR]  [hide]  [fav]     |  footer
+-----------------------------------------------------+ y=0
   ^M1     ^M2     ^M3     ^M4      ^M5     ^M6
```

`◊` = the "null" (no-filter) ribbon position; `[N]` = current
ribbon selection bracketed; `#` = numerics/specials position. Ribbon
does NOT wrap (see Ribbon spec below).

---

## Type-glyph mapping (derived from real keywords)

Keyword audit across `mods/` (72 tagged units total):

| Keyword | Count | Glyph |
|---|---|---|
| source | 24 | `~` |
| effect | 24 | `>` |
| modulate | 13 | `$` |
| sampling | 12 | (modifier, see below) |
| pitch | 11 | (modifier) |
| timing | 10 | `*` |
| filter | 8 | `>` (effect-class) |
| delay | 7 | `>` (effect-class) |
| container | 5 | `.` |
| measure | 4 | `.` |
| i2c | 4 | `.` |
| noise | 3 | `~` (source-class) |
| (empty) | 3 | `?` |
| txo, teletype, output, mixing | 2 each | `.` |
| multi, lfo, debug | 1 each | `$`, `$`, `?` |

**6 glyphs in the cycle** (M3 type-filter):

| Glyph | Class | Primary keyword match |
|---|---|---|
| `~` | source | source, noise |
| `>` | effect | effect, filter, delay |
| `$` | modulate | modulate, lfo |
| `*` | timing | timing |
| `.` | utility | container, measure, mixing, output, i2c, txo, teletype |
| `?` | unknown | (empty keyword), debug |

**Row glyph: first keyword wins.** The leading character on each
row uses the first keyword in `loadInfo.keywords` (comma-separated
string). One glyph per unit, no ambiguity in the row render.

**M3 type filter: overlap-aware.** When M3 cycles to e.g. `>`
effect, the visible list is every unit whose **keyword list
contains** `effect` (or any keyword that maps to `>`: effect,
filter, delay), regardless of position in the keyword string. A
unit tagged `effect, container` therefore shows up under both the
`>` filter and the `.` utility filter. The same unit appears in
multiple buckets; that is the trade-off vs missing a unit because
its author put the "wrong" keyword first.

Per-unit glyph still reflects the primary keyword even when listed
under a non-primary filter. So an `effect, container` unit shows
its `>` glyph in both views, never re-glyphed as `.` when the
utility filter is active.

Sub-class filtering (e.g., "only filters, not all effects") isn't
in M3 — that would be a 10+ position cycle. The sub-class filter
lives in **Sort mode 5 (keyword group)** instead, which lets the
user sort by primary keyword so all filters cluster together
visually.

---

## Sort modes

M2 cycles the sort key. Each mode rebuilds the displayed list, and
keeps the current cursor on the same unit if it's still visible
(else snaps to the first unit). Section dividers reappear when the
sort mode is `package` or `keyword`.

| # | Mode | Order | Section dividers? |
|---|---|---|---|
| 1 | recents | most-recently-used first, then alpha | no |
| 2 | alpha | A-Z by `title` | no (ribbon does the work) |
| 3 | type | by leading glyph (`~ > $ * . ?`), then alpha | yes (glyph rows) |
| 4 | package | by `loadInfo.libraryName`, then alpha | yes (library rows) |
| 5 | keyword | by primary keyword (`source`, `effect`, ...), then alpha | yes (keyword rows) |
| 6 | favorites-first | favorited first, then recents secondary | no |
| 7 | I/O fan | `inCount + outCount` desc, then alpha | no |

Mode #4 (`package`) is the classic browsing experience preserved
verbatim — same `addCategory(libraryName)` section headers that the
current Mondrian view shows. This is the migration safety net: any
user who can't get used to the new flat layout can M2-cycle to
`package` and get the familiar tree-style browse back.

Section dividers render as a faint hairline + 8-char label at font
9, taking one row of vertical space. They are non-selectable (skip
on encoder).

The cycle order is configurable from admin (some users will skip
modes they don't use), so M2 walks only the enabled modes.

---

## Alphabet ribbon

Ribbon contents, left to right:

```
[◊] A B C D E F G H I J K L M N O P Q R S T U V W X Y Z [#]
```

28 positions total: `◊` (null / no-filter), 26 letters, `#`
(numerics + special chars).

**Behaviour:**
- Bare encoder = scroll the unit list (row cursor moves).
- Shift + encoder = move ribbon selection one step. **No wrap.**
  Holding shift + cranking right walks all the way to `#` and
  stops; holding left walks to `◊` and stops. This is the user's
  "blast to extreme" gesture.
- HOME = snap ribbon to `◊` (instant reset to unfiltered).
- shift + HOME = snap ribbon to `#` (instant jump to specials).

**When ribbon is on a letter:** unit list filters to units whose
`title` starts with that letter, case-insensitive. Sort mode still
applies within the filtered set.

**When ribbon is on `◊`:** no filter, all units visible (the default
state after first open).

**When ribbon is on `#`:** units whose title starts with a digit
(`0-9`) or special char (`_`, `-`, `+`, `.`). Catches the `2x4mix`
and `_` named units that don't fit anywhere alphabetic.

**Visual states:**
- Bright (15): the current selection (bracketed `[N]`).
- Normal (9): letters with at least one matching unit at the
  current sort + type filter.
- Dim (3): letters with no matches (skip on shift+encoder).

The skip-empty-letters behaviour means shift+encoder land only on
useful positions; the user never has to click through 8 empty
letters to get from F to N.

---

## M-key + S-key gesture map

### Main display (M1-M6)

| Key | Bare | Shift+ |
|---|---|---|
| M1 | pick left-col cell (insert) | toggle favorite on left cell |
| M2 | cycle sort mode | reverse-cycle sort mode |
| M3 | cycle type-filter glyph | reverse-cycle type-filter |
| M4 | pick right-col cell (insert) | toggle favorite on right cell |
| M5 | toggle hidden-units visibility | hide focused cell (in edit mode) |
| M6 | toggle hidden-edit mode | clear all hidden |

ENTER acts as M1 (left pick) for one-handed continuity. UP acts as
CANCEL (close picker without inserting).

### Sub display (S1-S3)

| Key | Bare | Shift+ |
|---|---|---|
| S1 | peek (brief audition, if supported by unit type) | — |
| S2 | toggle expanded info pane (show full keyword list + args) | — |
| S3 | cycle "what to show": keywords / I/O / args / library | — |

### Encoder

| Gesture | Effect |
|---|---|
| Bare | move row cursor up/down |
| Shift | move ribbon selection (no wrap, skip empty letters) |
| HOME | snap ribbon to `◊` |
| Shift+HOME | snap ribbon to `#` |

### Hidden-edit mode (M6 toggles into it)

When hidden-edit mode is active, the picker border changes color
(orange-ish, GRAY10) and the footer chip row swaps to:

```
| [hide L] [hide R] [show all] [done] [—] [—] |
```

Tap M1 hides the left cell, M2 hides the right cell, M3 unhides
all, M4 exits edit mode. Hidden state writes to `hidden.lua`.

---

## Admin menu spec

New admin section "Unit Picker" with:

1. **Style:** `Classic` / `Dense` (radio).
2. **Default sort:** dropdown of the 7 modes (which mode the picker
   opens in on each launch).
3. **Sort cycle order:** checkbox list of the 7 sort modes in user-
   chosen order. Defaults: `recents, alpha, type, package,
   keyword, favorites-first`. I/O fan off by default.
4. **Type-filter cycle order:** checkbox list of the 6 glyphs in
   user-chosen order. Default: all 6 in `~ > $ * . ?` order.
5. **Show sparklines:** on / off. Off = cleaner rows for users who
   don't care about recency.
6. **Show ribbon empty-letter dim:** on / off. Off = all letters
   render at normal brightness regardless of match count (saves
   the per-letter filter-count pass on slow boots).
7. **Hidden units:** scrolling list of currently-hidden units with
   per-row restore button + bulk "restore all" footer.
8. **Picker preview pane:** on / off. On = sub display shows
   focused-unit info (default). Off = sub display shows the
   classic help text.

Settings persist to `~/.od/rear/picker_prefs.lua`. Schema:

```lua
return {
  style                  = "dense",
  defaultSort            = "recents",
  sortCycleOrder         = { "recents", "alpha", "type", "package", "keyword", "favorites-first" },
  typeFilterCycleOrder   = { "~", ">", "$", "*", ".", "?" },
  showSparklines         = true,
  showRibbonDim          = true,
  showPreviewPane        = true,
}
```

---

## Persistence files

| File | Purpose | Format |
|---|---|---|
| `~/.od/rear/favorites.lua` | existing favorites table | unchanged |
| `~/.od/rear/picker_prefs.lua` | new, per-user picker settings | see above |
| `~/.od/rear/hidden.lua` | new, hidden unit titles | `{ titles = { "title1", "title2", ... } }` |

Hidden uses `title` rather than `id` to survive package version
bumps. If a hidden unit's title changes between releases, the user
sees it again (acceptable; favorites work the same way).

---

## File-by-file implementation

### New files

- `xroot/Unit/Chooser/Dense.lua` — the new picker class. Modeled
  on `Default.lua` but renders directly via `app.Graphic` +
  `app.Label` + `app.DrawingInstructions` instead of through
  `MondrianMenu` / `MondrianList`. Implements all 7 sort modes,
  type-filter cycle, ribbon nav, hidden-edit mode.
- `xroot/Unit/Chooser/Ribbon.lua` — alphabet ribbon widget.
  Composes `app.Label` for each position; tracks selected index;
  emits a `selectionChanged` signal consumed by `Dense.lua`.
- `xroot/Unit/Chooser/Sparkline.lua` — 5-char recency sparkline
  formatter. Reads a per-unit timestamp array from a
  `recencyHistory.lua` file, computes the 5-period density string.
- `xroot/Unit/Chooser/Glyph.lua` — keyword-to-glyph dispatch.
  One table lookup with fallback to `?`.
- `xroot/Persist/PickerPrefs.lua` — load/save picker_prefs.lua.
  Mirrors `xroot/Sequencer/Persist.lua` shape.
- `xroot/Persist/Hidden.lua` — load/save hidden.lua.
- `docs/admin-picker-settings.md` — admin-side user docs for the
  new picker preferences.

### Modified files

- `xroot/Unit/Chooser/init.lua` — choose between `Default` (classic)
  and `Dense` based on `picker.style`. Keep the same outer Chooser
  API so callers don't change.
- `xroot/Unit/Chooser/Default.lua` — add type glyphs + recency
  intensity as "cheap wins" so the classic view also benefits.
  Optional sparkline behind the same `showSparklines` admin flag.
- `xroot/Admin/Settings.lua` — add the "Unit Picker" section.
- `xroot/Persist/QuickSavePreset.lua` — persist a "last picker
  ribbon position" in quicksave so power-cycle restores cursor.
  Optional; defer if scope creeps.

### Engine-side: no changes

The picker is pure Lua. No `od/` or `firmware/` work.

---

## Phased delivery

The plan ships in three phases. Each phase is independently
testable + revertable; later phases don't require earlier phases to
be on `develop`.

### Phase 1 — Cheap wins inside Mondrian (1-2 days)

Goal: improve scannability of the classic view without changing
layout. Lets us A/B against phase 2.

- [ ] Add `Glyph.lua` + wire into `Default.lua` so every unit
      shows its type glyph as a leading character.
- [ ] Add `Sparkline.lua` + `recencyHistory.lua` (rolling
      timestamps per unit-title).
- [ ] Wire recency-intensity (full-white vs gray border) into
      Mondrian box render.
- [ ] Bench: open picker, scan for `sc.cv`, time it. Compare
      to pre-change baseline.

Ship as a single commit on `develop`.

### Phase 2 — Dense view behind admin toggle (3-5 days)

Goal: the new view is reachable but not default.

- [ ] `Persist/PickerPrefs.lua` + `Persist/Hidden.lua`.
- [ ] `Admin/Settings.lua` add "Unit Picker" section with the
      `style` toggle (only — defer the rest of the admin spec to
      phase 3 polish).
- [ ] `Ribbon.lua` widget + `Dense.lua` skeleton with sort mode
      1 (recents) + type-filter cycle + ribbon nav + M1/M4 pick.
- [ ] All 7 sort modes implemented + cycle gesture.
- [ ] Section dividers for `type`, `package`, `keyword` modes.
- [ ] Bench: same `sc.cv` scan task on dense view; compare to
      phase 1 numbers. Test with `recents` sort, `package` sort
      (classic muscle memory), and `keyword` sort.

Ship as 4-6 small commits on `develop` (admin scaffolding,
ribbon widget, dense skeleton, sort modes, section dividers, polish).

### Phase 3 — Polish + admin completion (2-3 days)

Goal: the new view is fit to become default for fresh installs.

- [ ] Hidden-edit mode + `Hidden.lua` persistence.
- [ ] Sub-display preview pane (focused unit info).
- [ ] Full admin spec: sort cycle order, type filter cycle order,
      sparkline toggle, ribbon dim toggle, preview pane toggle,
      hidden units list.
- [ ] Quicksave persistence for last ribbon position (deferred
      item from above).
- [ ] Bench: full scan tasks on all 7 sort modes, verify ribbon
      no-wrap + extreme-snap gestures, verify hidden persists.
- [ ] Flip `picker.style` default to `dense` for fresh installs;
      keep `classic` for existing users with no `picker_prefs.lua`.

Ship as 3-4 commits on `develop`.

---

## Locked decisions (resolved 2026-05-30)

1. **Cursor model: row-cursor.** Both cells of the focused row are
   live; M1 picks left, M4 picks right.

2. **Recency history: 32-event ring buffer per unit.** Bucketed
   into 5 sparkline positions (last hour / day / week / month /
   older).

3. **Empty-letter dim: lazy compute, cache, invalidate on cue.**
   Per-letter match counts are computed once and cached on:
   picker open, sort-mode change (M2), type-filter change (M3),
   and after a hide / unhide. NOT on every encoder tick or every
   refresh. Ribbon-position change (shift+encoder) reads the cache.
   This bounds the cost to O(units) per user action rather than
   O(units) per frame. `showRibbonDim` admin flag defaults ON
   everywhere now that cost is gated.

4. **Keyword conflicts: overlap allowed.** A unit with
   `effect, container` shows up in BOTH the `>` effect filter
   AND the `.` utility filter. Type-filter (M3) selects units
   whose keyword list **contains** the filter keyword, not just
   units whose primary keyword equals it. The leading **glyph**
   on each row still uses the first keyword (one glyph per unit,
   no ambiguity in the row render), but the same unit can appear
   under multiple M3 buckets. Trade-off: the same unit visible in
   multiple filter views (muddier), in exchange for never missing
   a unit because the author put the "wrong" keyword first.

5. **Section dividers: 1 px hairline + 8-char label at intensity
   6, non-selectable.** Used in `type`, `package`, `keyword` sort
   modes.

6. **Sub-display keywords: vertical stack, up to 4 lines.** No
   truncation. Layout for the sub display is restructured to give
   keywords their own multi-line zone (see updated Sub display
   layout above). If a unit has more than 4 keywords, only the
   first 4 render and the rest are silently dropped (none of the
   current units have more than 4).

## Out of scope for v1

- **Slot Machine Text Input integration.** A future direct text-
  search would slot in as an M-key (probably displacing favorite
  or hidden). Revisit when the Slot Machine Text Input TODO entry
  ships.
- **Drag-reorder within a category.** No good gesture exists for
  it on the encoder + M-keys.
- **Per-package picker pref overrides** (e.g., "always sort by
  alpha when in `lojik` package"). Possible later if users ask.

---

## Test plan

Manual scan tasks (timed, before/after, with 200+ unit inventory):

1. **Familiar unit:** find `sc.cv` from a fresh open (classic vs
   phase 1 vs phase 2 dense+recents vs phase 2 dense+package).
2. **By type:** "find me any envelope" (cold; classic vs dense +
   type-filter on `$`).
3. **By name letter:** "find me anything starting with V" (classic
   vs dense + ribbon `V`).
4. **By library:** "find me a `lojik` unit" (classic vs dense +
   sort=`package`).
5. **By keyword:** "find me anything tagged `pitch`" (classic
   N/A vs dense + sort=`keyword` scrolled to pitch block).

Target: dense view should match or beat classic on tasks 1-4 within
1 week of test-drive, and unambiguously beat it on task 5 (which
classic literally can't do).

Edge cases:
- Empty inventory (no packages loaded). Dense must not crash.
- All units hidden. Picker shows "all units hidden, M3 to restore"
  message instead of an empty list.
- Picker open during package install (units appearing mid-session).
  Refresh on `packagesChanged` signal.
- Switching style admin setting while picker is closed (next open
  uses new style). While picker is open: no live swap, takes effect
  on next open.

---

## Bench checklist (for each phase)

Mirror the sequencer's bench discipline: a checklist of N tests,
run end-to-end on hardware, pass before commit. Phase 1 = 6 tests.
Phase 2 = 12 tests. Phase 3 = 18 tests. Tracked in
`docs/planning/unit-picker-bench.md` (created at start of phase 1).

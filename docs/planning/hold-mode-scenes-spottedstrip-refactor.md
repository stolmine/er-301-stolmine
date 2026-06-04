# Hold-mode scenes: Performance → SpottedStrip refactor plan

## Goal

Match the quicksave page's animation and ply-border conventions
exactly. The "ape exactly" requirement effectively requires
replacing Performance's `Window` base + manual slot positioning
with `SpottedStrip` + per-Control architecture, because the
animation is the C++ `mOriginState` viewport pan that's only
reachable via that container.

## Current state (Performance as Window)

- `Performance` inherits `Base.Window`.
- Main display:
  - `cvFader` (full-height `app.Fader`) at col 1.
  - Five `SlotControl` Lua objects (col 2-6), each owning a
    `TextPanel` + A/B chip Label + `SceneSlotIndicator`.
  - `plusGlyph` (Drawing with `Drawings.Control.Plus`) at floating
    "+" column.
  - `navCaret` ▼ above the cursor column.
  - `cursorBox` 1px outline around col 1 when M1 sub readout focused.
- Sub display:
  - `m1SubGroup` (gain readout + bias readout + scope + branch dive
    + plus drawing instructions). Shown when cursor on M1.
  - `slotSubGroup` (status label + S1/S2/S3 SubButton labels).
    Shown when cursor on a slot.
- Input:
  - `mainReleased(i, shifted)` dispatches per-column.
  - `subReleased(i, shifted)` dispatches per-column.
  - `encoder(change, shifted)` either drives focused M1 readout or
    moves the cursor between cols 1-6 (with scroll-offset bump at
    edges).
- State:
  - `cursorCol` 1-6, `m1FocusedReadout` (gain or bias).
  - `scrollOffset` integer, `scrollFrac` float for animation.
  - `shiftModeByCol[2..6]` per-column shift toggle.

## Target state (Performance as SpottedStrip)

- `Performance` inherits `SpottedStrip`.
- One `Section`. Controls in order:
  1. `M1Control` — full-fader CV / bias widget. Spot at center,
     width = ply.
  2. `SceneSlotControl(sceneIdx)` × N — one per scene (1 ≤ N ≤ 16).
     Spot at center, width = ply.
  3. `PlusControl` — empty-slot affordance. Spot at center,
     width = ply. Visible only when sceneCount < kMaxScenes.
- `SpottedStrip`'s C++ widget handles cursor + camera pan (the
  exact animation we want).
- Each Control owns its `subGraphic` (the sub-display widget tree)
  and grabs `subReleased` focus on cursor enter.
- Ply borders: every Control's controlGraphic uses
  `setBorder(1) + setBorderColor(app.GRAY3)` at construction,
  toggling to `app.WHITE` in `onCursorEnter` (back to `GRAY3` in
  `onCursorLeave`). Matches quicksave Slot pattern.

## Migration map

### Files to add
- `xroot/SceneView/M1Control.lua`
- `xroot/SceneView/PlusControl.lua`
- `xroot/SceneView/SceneSlotControl.lua` (rewrite of `SlotControl.lua`)

### Files to modify
- `xroot/SceneView/Performance.lua` (~50% rewrite)
- `xroot/SceneView/SlotControl.lua` → delete (functionality moves to
  `SceneSlotControl.lua`)
- Possibly `xroot/Channels/init.lua` (the show/hide entry points to
  Performance) — only if class shape needs adjusting.

### Files unchanged
- `xroot/SceneView/Scene.lua`
- `xroot/SceneView/init.lua` (the SceneView model)
- `xroot/Chain/Root.lua` (scene-CV branch, arm helper, authoring
  entry/exit)
- `od/objects/control/ParamSetMorph.cpp/h`
- `od/graphics/controls/SceneSlotIndicator.cpp/h`
- `xroot/Drawings.lua` (the Plus glyph)
- `xroot/Settings/init.lua` + `Settings/Interface.lua`
- `xroot/Unit/ViewControl/*` (per-control state machine,
  enterModulatedDisplay / enterSceneMode / etc.)

### Feature mapping

| Behavior                              | Now                                    | After                                                                             |
|---------------------------------------|----------------------------------------|-----------------------------------------------------------------------------------|
| Slot scroll                           | `scrollOffset` + `scrollFrac` lerp     | SpottedStrip C++ `mOriginState` pan                                               |
| Cursor visualization                  | `navCaret` ▼ + `cursorBox`             | TextPanel border GRAY3 → WHITE per Control's enter/leave                          |
| M-key dispatch                        | `mainReleased(i, shifted)` switch      | SpottedStrip → spotPressed/Released per Control                                   |
| S-key dispatch                        | `subReleased(i, shifted)` switch       | Each Control's own `subReleased(i, shifted)` while focused                        |
| Sub display swap                      | `_refreshSub` show/hide groups         | `addSubGraphic` / `removeSubGraphic` in onCursorEnter/Leave                       |
| M1 auto-focus bias on click           | Inline `if i == 1 then …` cycle        | `M1Control:spotPressed`                                                           |
| Scene add ("+" tap)                   | `mainReleased` `i == plusCol` branch   | `PlusControl:spotReleased`                                                        |
| Scene delete (shift+M)                | `mainReleased` `if shifted` branch     | `SceneSlotControl:spotReleased(_, shifted=true)`                                  |
| Shift toggle for asgn / rename        | `shiftModeByCol[col]` boolean array    | `self.shifted` field on each `SceneSlotControl`                                   |
| Scroll right at col 6                 | Manual scroll bump                     | SpottedStrip's encoder advances cursor to next Control; section auto-pans         |
| Floating "+" position                 | Computed in `_refresh`                 | PlusControl's position is wherever the section put it (right after last slot)     |
| Bias-fill indicator                   | One per fixed col 2-6                  | One per SceneSlotControl (1 per scene)                                            |
| Live morpher weight wiring            | All five slots get same Parameter      | Each SceneSlotControl gets it on construction                                     |
| Auth dive (`S3` on slot)              | `subReleased` `i == 3` branch          | `SceneSlotControl:subReleased(3, false)`                                          |
| A/B toggle (`S1` / `S2` on slot)      | `subReleased` `i == 1/2` branch        | `SceneSlotControl:subReleased(1/2, false)`                                        |
| Duplicate / rename (S1 / S2 shifted)  | `subReleased` shifted branch           | `SceneSlotControl:subReleased(_, shifted=true)`                                   |
| M1 sub display (gain/bias/scope)      | `m1SubGroup` constructed in Performance| `M1Control:init` builds it                                                        |
| M1 readout focus state                | `self.m1FocusedReadout`                | `M1Control:_setFocusedReadout`                                                    |
| Scene-CV dive                         | `_diveSceneCV`                         | `M1Control:subReleased(1, false)` calls `callUp("diveSceneCV")`                   |
| Authoring entry                       | `_enterAuthoring(sceneIdx)`            | `Performance:enterAuthoring(sceneIdx)` invoked via `callUp` from SceneSlotControl |

### State migration

| Now                              | After                                                |
|----------------------------------|------------------------------------------------------|
| `self.cursorCol`                 | SpottedStrip's selected spot handle                  |
| `self.scrollOffset`/`scrollFrac` | (removed; SpottedStrip handles)                      |
| `self.shiftModeByCol`            | Per-Control `self.shifted` (each SceneSlotControl)   |
| `self.m1FocusedReadout`          | M1Control's own state                                |
| `self.slots[2..6]`               | `self.slots[1..N]` indexed by sceneIdx, dynamic size |
| `self.plusGlyph`                 | `self.plusControl` (a SpottedControl)                |

## Implementation order

1. **Scaffolding commit**: this plan document, no code changes.
2. **M1Control**: stand up the new control wrapping the existing
   cvFader + sub display. Wire callUp routes for scene-CV dive
   and (eventually) the morpher Weight Parameter.
3. **SceneSlotControl**: per-scene Control. Owns TextPanel + chip
   + indicator (controlGraphic) and slot status panel + S-button
   labels (subGraphic). Implements spotReleased + subReleased.
4. **PlusControl**: simple Control with the plus glyph.
5. **Performance rewrite**: inherit SpottedStrip; build the single
   Section; add the controls; expose `callUp` targets (
   `addScene`, `deleteScene`, `renameScene`, `duplicateScene`,
   `toggleEndpoint`, `enterAuthoring`, `diveSceneCV`,
   `setM1FocusedReadout`); wire `contentChanged` Signal,
   `_rebuildSceneMorph`, etc.
6. **Bench verify** on emu, then am335x.

Each step in its own commit so we can bisect / revert mid-stream.

## Test checklist

Done = visual + functional parity with `.24` plus the additional
ply-border + native-animation upgrades.

- [ ] Open Performance; M1 fader visible at col 1, scenes 1-N at
      col 2 onward, "+" placeholder at the end.
- [ ] Encoder right: cursor advances through scenes; once past col
      6 the camera pans smoothly (mOriginState lerp at 0.20, 2 px
      snap), matching quicksave.
- [ ] Encoder left: cursor retreats; camera pans back.
- [ ] Tap M-key on a visible scene: cursor jumps there.
- [ ] Tap M1: bias readout focused, ▶ caret on main + sub.
      Second tap unfocuses. Third tap re-focuses bias. (.21 cycle.)
- [ ] Tap "+" placeholder: creates scene, cursor moves to it,
      strip pans if needed.
- [ ] Shift+S2: rename keyboard opens.
- [ ] Shift+S3: delete dialog (gated on `confirmSceneDelete`
      setting).
- [ ] Shift+S1: duplicates scene; new scene appears at end.
- [ ] S3 on slot: enters scene authoring; UP returns.
- [ ] S1/S2 on slot: toggle A/B endpoint; chip + bias-fill
      indicator update.
- [ ] Bias-fill indicator tracks morpher Weight Parameter live as
      M1 fader moves.
- [ ] Save quickset, reload: scenes round-trip; A/B assignment
      restored; cursor lands somewhere sensible.

## Revert plan

If the refactor proves problematic on bench:

1. Revert the SpottedStrip rewrite commits (the Performance + new
   control class commits). Keep this plan document as a record.
2. Bench should drop back to `.24` (working but animation looks
   "worse than aimed for") + the per-control logic changes
   already shipped (`.17-.23`).
3. Add ply borders to the current `SlotControl.lua` as the
   smaller alternative win.
4. Park the SpottedStrip refactor as a documented open question
   in `hold-mode-scenes-todos.md`.

We lose nothing tracked elsewhere by reverting; all the
per-control / per-scene logic changes are independent of the
container.

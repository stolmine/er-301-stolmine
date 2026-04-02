# TODO

## Favorites System in Unit Picker
Shift toggles favorites editing mode while browsing units by category. Sub-display shows three controls:
- **S1: Tag/untag** — toggle the currently highlighted unit as a favorite
- **S2: Clear all** — clear all favorites, guarded behind a confirmation dialog (with confirmation guard toggle in system settings confirmations section)
- **S3: Sort** — cycle favorites display order: recents, alphabetical, category

Favorites appear as their own category in the unit picker, below Recents and above Essentials. System settings toggle to show/hide the favorites category entirely.

Favorites persist across sessions (serialize alongside Recents in quicksave data).

## v0.6.16 Port
Port TXo I2C master mod to v0.6.16 stable firmware base. v0.7 breaks compatibility with all third-party packages (lojik, strike, sloop, polygon, etc.).

## Screensaver Cycle Mode
Add a "Cycle" option to the screensaver selector. When idle timer triggers, pick a different screensaver each time — random (excluding current/last) or sequential through the list.

## Screensaver Polish
- Forest screensaver: full-screen coverage
- Rain screensaver: splash particles

## Intro Video
Produce a short video introducing stolmine firmware. See [video.md](video.md) for script outline.

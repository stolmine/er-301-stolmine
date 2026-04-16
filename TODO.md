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

## Screensaver Polish
- Forest screensaver: full-screen coverage
- Rain screensaver: splash particles

## Slot Machine Text Input
Alternate text entry method using the 6 main buttons as column selectors:
- Display 6 character columns on screen, each aligned under M1-M6
- **Hold** a button to focus its column — encoder scrolls through symbols in that column
- **Release** to enter the selected character at the cursor position
- Cursor advances automatically after entry
- Sub-display unchanged from existing keyboard: S1 bksp, S2 cursor, S3 space
- Symbol set per column: A-Z, a-z, 0-9, common punctuation (-, _, ., /)

Advantages over single-cursor keyboard: up to 6 characters visible and selectable at once, no lateral cursor movement needed for sequential entry, encoder travel per character is minimal since columns can show contextual/frequent symbols.

## Intro Video
Produce a short video introducing stolmine firmware. See [video.md](video.md) for script outline.

## Chain-Reference Invalidation on Stereo Link/Unlink (pre-v9.1.0)
Stereo link/unlink in user mode destroys and recreates chain objects, but only
`UserMode` subscribes to `channelsModified`. `LocalChooser` (and its wrapper
`Source/Chooser`) hold chain references that can dangle across a link/unlink.
Main channel view + `OUTX: No units` readout are fine — those rebuild via
`Channels.show()`. Fix: apply the stock `Signal.weakRegister` pattern
(as in `Source/Chooser.lua:41`, `GlobalChains/Interface.lua:315-317`, etc.) to
`LocalChooser` and `Source/Chooser`, with reseed-or-dismiss semantics.
See [docs/planning/chain_invalidation_on_link_unlink.md](docs/planning/chain_invalidation_on_link_unlink.md).

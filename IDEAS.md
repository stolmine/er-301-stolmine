## Clicks in Shared Buffers
The basic idea will be to push a copy of the un-dubbed audio that is about to be overdubbed into a ring buffer. Then whenever a play-head approaches the record-head, fade into the un-dubbed material that was saved on the ring buffer instead. So by the time the play-head reaches the record-head’s position the mix will be 100% of the un-dubbed material in the ring buffer and 0% of the looper buffer (which has the click in it). If the play-head is going in reverse you would fade out instead.

## End of Slice Triggers
Shared buffers could be extended to include a shared playhead, or, at least awareness of a given playhead so that a unit's output could be a function of another sample player's state.


ENHANCE: Add a file browser.
ENHANCE: Add a log viewer.

ENHANCE: Bypass toggle via trigger
ENHANCE: A unit that when triggered causes its parent chain to load a given preset.

ENHANCE: Replace direct calls to neon intrinsics with xsimd calls (https://github.com/JohanMabille/xsimd).
ENHANCE: Sample preview volume adjustment.

NEW UNIT: Sequencer > I've already made the object.  Place behind a system setting: "I promise not to complain about the audio-only outputs."
CONFUSING: Custom Units > The replace command appears to have no effect.

ENHANCE: Shared circular buffer.
ENHANCE: Sample Pool > Save all "unsaved" buffers.

ENHANCE: Teletype Slew > add constant time mode

ENHANCE: Settings > Automatically purge unused samples after certain actions: clear chain, delete unit, etc.

ENHANCE: Add volume control for sample previewing.
ENHANCE: Allow multiselect across folders.

ENHANCE: System Setting > Default F0 for oscillators and filters.
or
ENHANCE: Ability to save default preset for any unit.  This default preset will be automatically applied when you insert a unit from the unit selection screen.

ENHANCE: Control Editor > copy/paste controls

ENHANCE: Saving files, naming things > Option to generate a unique name for the user.

## I2C Master Output Ideas

1. **TXo output for ER-301 CV/gate** — finished. Interrupt-driven master TX with simultaneous slave RX for teletype/crow compatibility.

2. **ER-301 CV/gate for other devices** — simple architecturally (I2C infra is device-agnostic), challenging in terms of UI.
   - For the Disting EX, for instance:
     - Unit takes trigger input from the left, or user toggles for continuous updates — separate units?
     - Pushing voices would be trigger-from-left which samples CV inputs to other controls
     - V/Oct, Plaits model, etc.
     - Cumbersome because the Disting has dozens of algorithms, all requiring somewhat unique control surfaces
     - Better left to the likes of Teletype

3. **The 301 is better suited to simple CV mod outputs, gate/trig patterns** — not a general-purpose I2C controller. Focus on what it does well: signal processing feeding into CV/gate outputs.

4. **The 301 has few interesting sequencers itself** — potential area for expansion with sequencer units that output via I2C.

5. **Fixed-function devices like Just Friends might be decent targets** — JF has a small, well-defined command set (6 voices, run mode, etc.) — a manageable UI surface compared to something like Disting.

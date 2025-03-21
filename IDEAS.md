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


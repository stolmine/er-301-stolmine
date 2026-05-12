#pragma once

#include <od/sequencer/Sequencer.h>

namespace od { namespace sequencer {

// Apply `a` to slot state. `hostCol` is the column the rule lives in,
// used for self-relative actions (ACTION_JUMP_SELF and the implicit
// "this column" for targetCol == -1).
//
// May queue deferred jumps onto Column::pendingJump (applied at the
// next tick boundary, not immediately).
//
// Real-time safe. Called from Slot::processFrame after evaluate() returns true.
void apply(Slot& slot, const Action& a, int hostCol);

}}  // namespace od::sequencer

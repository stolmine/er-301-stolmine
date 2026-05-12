#pragma once

#include <od/sequencer/Sequencer.h>

namespace od { namespace sequencer {

// Evaluate `p` in the context of slot `slot`, hosted on column `hostCol`.
// Returns true when the predicate fires for the current playhead state.
//
// Pure function: does not mutate slot state. (Mutation happens in
// ActionApply::apply if evaluate() returns true.)
//
// Real-time safe. Called from Slot::processFrame.
bool evaluate(const Slot& slot, const Predicate& p, int hostCol);

}}  // namespace od::sequencer

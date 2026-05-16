#pragma once

#include <od/sequencer/Sequencer.h>

namespace od { namespace sequencer {

// Evaluate `p` in the context of slot `slot`, hosted on column `hostCol`.
// Returns true when the predicate fires for the current playhead state.
//
// Mutates slot.rng for stochastic predicates (PRED_PROBABILITY). All
// other predicates are pure reads of slot state. (Substantive mutation
// happens in ActionApply::apply when evaluate() returns true.)
//
// Real-time safe. Called from Slot::processFrame.
bool evaluate(Slot& slot, const Predicate& p, int hostCol);

}}  // namespace od::sequencer

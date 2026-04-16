# Chain-Reference Invalidation on Stereo Link/Unlink

## Context
Stereo link/unlink destroys and recreates `ChannelGroup`/chain objects:
`c2g[i]:destroy()` followed by `c2g[i] = ChannelGroup(...)` in every link and
unlink branch of `update()` (`xroot/Channels/init.lua:32-105`). Any view that
captured a chain reference from `Channels.getChain(i)` before the change is
pointing at a destroyed C++ object.

`Signal.emit("channelsModified")` fires after every such change
(`xroot/Channels/init.lua:130, 139, 378, 420`). The stock mechanism for views
to react is `Signal.weakRegister(event, self)` plus a same-named method on the
class; the dispatcher routes via `f[s](f, ...)` (`xroot/Signal.lua:37`). Weak
keys mean the registration dies with the window — no explicit teardown.

The only current subscriber to `channelsModified` is `UserMode`
(`xroot/UserMode.lua:115`), using the strong `Signal.register` with explicit
`Signal.remove` on mode leave — appropriate for a long-lived Mode. Every
other chain-ref holder lacks a subscription.

## Observed Symptoms
- **Main channel view (`OUTX: No units`, scope, etc.)** — refreshes correctly
  on link/unlink in user mode, because `UserMode.refresh()` →
  `Channels.show()` rebuilds every `ScopeView` including its `setEmptyString`
  (`xroot/Chain/ScopeView.lua:22`).
- **`LocalChooser` (local input picker, FileRecorder and InputControl paths)**
  — does not subscribe. The existing
  `onShow`/`refreshNeeded` guard
  (`xroot/Source/LocalChooser.lua:273-297`) only reseeds when
  `Channels.selected()` has *changed*. If the user stays on the same channel
  and that channel's chain was destroyed/rebuilt underneath (common — link
  happens from the main view, same channel still selected), re-entry falls
  into `else: self:refresh()` (line 285) and paints against a dangling
  `self.chain`. Nodes cached in `self.nodes` by
  `loadChainHelper(self.chain)` (line 50) are likewise stale.

## Broader Exposure
Files matching `getChain|self\.chain\b` (19 total). Triaged:

| File | Risk | Notes |
|---|---|---|
| `xroot/Source/LocalChooser.lua` | **Confirmed bug** | See above. |
| `xroot/Source/Chooser.lua` | Likely — inherits via wrapped `LocalChooser` | `self.chain` at line 13; already uses `weakRegister` for `onGlobalChainCountChanged` (line 41), so the pattern fits. |
| `xroot/Chain/ScopeView.lua` | Covered indirectly | Rebuilt by `Channels.show()` on every `channelsModified` via `UserMode.refresh`. Verify, don't re-subscribe. |
| `xroot/Source/GlobalChooser.lua` | Unaffected | Bound to global chains, not main-out channel chains. Verify. |
| `xroot/Chain/MarkMenu.lua`, `xroot/Unit/Chooser/init.lua`, `xroot/PinView/init.lua`, `xroot/FileRecorder/ChannelControl.lua`, `xroot/Persist/QuickSavePreset.lua`, `xroot/GlobalChains/Interface.lua`, `xroot/Card/FileChooser.lua`, `xroot/Card/Player.lua` | Mostly short-lived or global-chain bound | Spot-check: any that can remain visible across a link/unlink needs the same treatment. |
| `xroot/Channels/init.lua`, `xroot/Channels/Group.lua`, `xroot/Unit/init.lua`, `xroot/FileRecorder/init.lua`, `xroot/Tests/*` | Ownership-side or tests | No action. |

## Approach — Stock Convention

For each view that holds a `self.chain` which is a main-out channel chain AND
can plausibly outlive a link/unlink, add in `init()`:

```lua
Signal.weakRegister("channelsModified", self)
```

and a matching handler on the class:

```lua
function View:channelsModified()
  local Channels = require "Channels"
  local newChain = Channels.getChain(self.channel)
  if newChain == nil then
    self:hide()
  elseif newChain ~= self.chain then
    self:reseed(newChain, self.channel)
  end
end
```

This mirrors the weak-registered pattern already used in
`Source/Chooser.lua:41`, `Source/GlobalChooser.lua:92-94`,
`GlobalChains/Interface.lua:315-317`, `Sample/Pool/Interface.lua:129-133`,
`Card/FileChooser.lua:175-176`. No new primitives; just apply the existing
idiom to the missing signal.

Notes on the handler shape:
- Same-channel chain-rebuild is the common case (link that merges two
  mono, or unlink that splits a stereo) — reseed is the right response.
- Channel-absorbed-into-stereo (e.g., the chain we were bound to no longer
  exists for our channel index) — dismiss. User reopens from the updated
  main view.
- `LocalChooser` already has a working `reseed(chain, channel)` method
  (`xroot/Source/LocalChooser.lua:210-222`) used by `onShow`. No new method
  needed.
- `reseed` must fully rebuild `self.nodes` (it does — calls `loadChainHelper`
  at line 214) or the cached node table stays stale.

## Scope

**In — targeted fix for v9.1.0:**
1. `LocalChooser` — subscribe, re-resolve chain, reseed-or-dismiss. Primary
   bug.
2. `Source/Chooser.lua` — subscribe symmetrically. If its child
   `LocalChooser` dismisses itself, the wrapping Chooser must handle that
   cleanly (Locals tab label/count).

**Verify only — no code change expected:**
3. `Chain/ScopeView.lua` — confirm `Channels.show()` in `UserMode.refresh`
   tears down and rebuilds ScopeViews (not just repaints) so stale refs can't
   survive. Testing path: link in user mode, inspect scope on the affected
   channels.
4. `Source/GlobalChooser.lua` — confirm its `self.chain` is a global chain,
   not a main-out chain.

**Out of scope — follow-up, not a v9.1.0 blocker:**
- Global audit of all 19 chain-ref holders with a formal lifecycle contract
  doc.
- Factoring a `ChainBoundWindow` mixin or helper for the subscribe + reseed
  pattern.
- Any change to `ChannelGroup::destroy()` lifecycle itself (e.g.
  generation counters on chains, soft-delete semantics).

## Critical Files
- `xroot/Channels/init.lua:32-105` — destructive `update()`.
- `xroot/Channels/init.lua:130, 139, 378, 420` — `channelsModified`
  emission sites (link, unlink, deserializeLegacy, deserialize).
- `xroot/UserMode.lua:115` — only current subscriber (strong, Mode-scoped).
- `xroot/Source/LocalChooser.lua:28-63` (init), `199-222` (refresh /
  reseed), `273-297` (onShow / onHide).
- `xroot/Source/Chooser.lua:9-79` (init, existing weak-register pattern),
  `142-144` (Locals gate).
- `xroot/Signal.lua:16-20, 37` — weakRegister + dispatcher.
- `xroot/Chain/ScopeView.lua:22` — the "OUTX: No units" empty string.

## Open Questions
1. **Dismiss or reseed onto the merged chain?** If LocalChooser was bound to
   chain 2 and the user links OUT1+OUT2, chain 2 no longer exists as its own
   root — it's now half of the stereo group rooted at chain 1. Dismiss is
   safer and matches the existing hardware convention that structural
   changes bounce the user back to the main view. Reseed onto the stereo
   root would be more convenient but risks showing units that weren't
   visible under the previous (mono) root. **Default: dismiss unless
   testing shows dismissal is disruptive.**
2. **Preset restore.** `Signal.emit("channelsModified")` also fires from
   `deserialize`/`deserializeLegacy` (lines 378, 420). Any subscribed view
   active at load time must handle the signal gracefully. Locals picker is
   almost never visible during load, but the handler's nil-safe path covers
   this.
3. **AdminMode coverage.** AdminMode does not subscribe to
   `channelsModified`. Verify whether AdminMode-scoped views display
   per-channel chain state; if so, apply the same pattern.

## Testing Plan
- Emulator only until hardware rebuild. All steps in user mode unless noted.
- Open FileRecorder → source picker → Locals tab on OUT2; back out; in main
  view, SELECT1+SELECT2 to link OUT1+OUT2; reopen source picker → Locals.
  Expected: picker reflects the new stereo chain or dismisses cleanly.
  Current bug: stale / potential crash.
- Same sequence with unlink (start stereo, split).
- Repeat across all adjacent pairs (1-2, 2-3, 3-4).
- Preset load while Locals picker is on screen (edge case, unlikely but
  possible via remote script or multi-step navigation).
- Regression sweep: confirm `OUTX: No units` still repaints on
  link/unlink.

## Status
Backlog — pre-v9.1.0. Not yet started.

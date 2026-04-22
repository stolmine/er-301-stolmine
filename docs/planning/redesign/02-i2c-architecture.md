# i2c Architecture

**Status:** dual-bus topology locked. Open question on whether to expose onboard CV/gate as TXo follower on leader bus.

## Topology

**Two dedicated i2c buses:**

1. **Leader OUT bus** — device acts as leader, drives followers (TXo, TXi, JF, etc.).
2. **Follower IN bus** — device acts as follower, accepts commands from external leaders (Teletype, Crow as user choice).

Each bus has its own pull-ups and ESD protection. **Clean role separation, no arbitration.**

Both buses are exposed on the rear panel as 3.5mm TRS jacks (monome ecosystem convention).

## Why two buses

This is a direct lesson from the existing Eurorack i2c ecosystem (Teletype, Crow, Just Friends, TXo, ER-301). Splitting leader and follower roles onto separate buses eliminates:
- Bus contention between multiple potential leaders
- Pull-up conflicts when devices with different pull-up strategies share a bus
- Arbitration complexity that doesn't need to exist if roles are statically known

**Principle: clean ownership beats arbitration.**

## Crow integration — explicitly out of scope for v1

Crow can sit on the leader-out bus or follower-in bus as a user choice (it's just another i2c device), but the redesigned 301 will **not**:
- Embed a USB-to-i2c bridge
- Embed a Lua runtime
- Otherwise duplicate Crow's functionality

Reason: scope containment. Crow exists; users who want it can add it.

## Open question

**Should the onboard 8 CV/gate outputs also be exposed as a TXo follower on the leader-out bus?**

This would let other monome-ecosystem devices (Teletype scripts, etc.) address the redesigned 301's CV/gate outputs as if they were a TXo. Pros: ecosystem fit, zero new mental model for monome users. Cons: complexity, role weirdness (the device is leader on that bus but also presents a follower target on it).

Not yet decided.

## Ecosystem context

Devices the redesigned 301 is designed to interoperate cleanly with:
- Teletype (leader)
- Crow (leader or follower depending on user setup)
- Just Friends / W/ (followers)
- TXo / TXi (followers)
- monome / llllllll community conventions

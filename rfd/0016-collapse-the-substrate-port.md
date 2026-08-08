# RFD 0016 — Collapse the substrate port

## Status

Accepted, implemented. Supersedes [RFD 0001](0001-substrate-port.md) and amends
the testing section of [RFD 0015](0015-tooling-constraints.md).

## Problem

Applying the YAGNI-as-timing rule from the manuals' RFD 0071, with the limits
set as:

- structure is justified when **a consumer exists today**, not when one is
  planned
- an interface needs **three** consumers (classic rule of three)
- the rule is a **mandate**: audit and strip existing structure now

The substrate port had two implementations, `Adapters.Quadlet` and
`Adapters.Fake`. Two is not three. The Fly.io adapter that would have been the
third was deleted earlier, when the deployment target narrowed to quadlets.

An audit also found port callbacks with no production caller at all:
`node_write_file`, `node_restart`, `node_stop`, and `apply`. The first two had
been added to solve problems that the static-addressing design in
[RFD 0002](0002-allocate-addresses.md) subsequently removed. They were needed
when written and became dead when the design improved, which is the ordinary
way structure goes stale.

## Decision

Delete the port. `RivetFabric.Bootstrap` calls `RivetFabric.Quadlet` directly.

Removed:

| File | Lines |
|---|---|
| `lib/rivet_fabric/ports/substrate.ex` | 64 |
| `lib/rivet_fabric/adapters/fake.ex` | 137 |
| `test/bootstrap_test.exs` | 126 |

`adapters/quadlet.ex` moved to `quadlet.ex` and is a plain module. The four dead
callbacks survive as internal functions of it, since `node_destroy` still calls
`node_stop` and `apply` internally. `Cluster.fdb_config/1` was deleted outright,
having had no caller in either `lib/` or `test/`.

## Consequences

**This forfeits testing of the bootstrap sequence.** The seven tests that went
with the Fake covered exactly the failures that were expensive to find:

- three fresh nodes forming three separate one-node clusters
- the bootstrap attempting to reload config by signalling PID 1
- node addresses surviving a restart
- `configure` running only after the nodes agree

Those behaviours are now verifiable only by creating real containers. The suite
that remains, 21 tests, covers the pure domain logic in
`RivetFabric.Domain.Cluster` and `Spec`, which is genuine coverage but does not
touch ordering.

The concern was raised before the change and the decision reaffirmed, so this is
recorded as a known cost rather than an oversight. The trade is a smaller
surface now against slower diagnosis if the ordering regresses.

**What is cheaper.** One fewer indirection between the sequence and podman, 327
fewer lines, and no risk of the Fake drifting from the real adapter, which
[RFD 0015](0015-tooling-constraints.md) had flagged as the maintenance cost of
keeping it.

## If this is revisited

The reversal condition is a second production substrate. If one appears, the
port comes back and the Fake with it; the shape is recorded in
[RFD 0001](0001-substrate-port.md), which is kept for that reason rather than
deleted.

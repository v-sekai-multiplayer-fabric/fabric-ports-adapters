# RFD 0001 — A substrate port for cluster bootstrap

## Status

**Superseded by [RFD 0016](0016-collapse-the-substrate-port.md).** The port was
removed when the rule-of-three limit was applied and only two implementations
existed.

Kept because it records the shape to restore if a second production substrate
appears. What follows describes the design as it was.

## Problem

Bringing up a FoundationDB-backed Rivet cluster is a sequence with real
ordering constraints, and those constraints are the valuable, hard-won part.
If that sequence is written directly against podman, it can only be exercised
by creating containers, which makes each iteration slow and each failure
expensive to reproduce.

The failures documented in [RFD 0002](0002-allocate-addresses.md) are all
ordering failures. They were found by running a real cluster, and every one of
them would have been found faster in a unit test.

## Decision

Express what the bootstrap needs from the world as an Elixir behaviour,
`RivetFabric.Ports.Substrate`, in terms of **nodes** rather than containers.

A node is one running instance with a stable name, a fixed address its peers
can reach, and optional persistent storage. The port covers: create a node,
list nodes, exec in a node, write a file into a node, restart, stop, destroy,
and commit pending declarative state.

Two adapters implement it:

| Adapter | Backed by | Purpose |
|---|---|---|
| `Adapters.Quadlet` | podman + systemd quadlets | the real substrate |
| `Adapters.Fake` | in memory | tests, no containers needed |

`RivetFabric.Bootstrap` is written against the port and contains no podman
specifics. `RivetFabric.Domain.Cluster` is pure and has no I/O at all.

## Consequences

The ordering bugs are reproducible in tests that run in milliseconds. The suite
runs in well under a second with no podman present, and the fake adapter
deliberately models the split-cluster trap so a regression in the sequence fails
a test rather than a deployment.

`node_write_file` exists in the port only because of the engine constraint in
[RFD 0003](0003-engine-configuration.md): the topology cannot be supplied
through environment variables, so it has to be written as a file.

The cost is one indirection between the sequence and podman. That is cheap, and
it is what makes the sequence testable.

## Alternatives considered

**Write directly against podman.** Simpler to read, but the only way to test the
ordering is to create containers, which is exactly the loop that made these bugs
expensive to find.

**Keep a second adapter for a cloud substrate.** An earlier revision carried a
Fly.io adapter. It was removed: maintaining an unexercised second adapter meant
carrying code that was transcribed from working commands but never run as
written. Worth noting that the substrate difference was load-bearing rather than
incidental, since Fly machines keep their address across restarts and podman
does not.

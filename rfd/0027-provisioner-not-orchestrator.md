# RFD 0027 — fabric-quickstart provisions the substrate, Pegboard orchestrates actors

## Status

Accepted. Records a boundary that was unstated until a hand-wired local runner
exposed the confusion.

## Problem

Standing up a glb-to-scene demo locally, the godot zone was wired to the engine
by hand: a docker network, a `curl` to `/runner-configs`, and a hand-written
engine topology. It half worked and then failed with the zone unable to connect
back to the engine, which is the exact defect [RFD 0003](0003-engine-configuration.md)
already documents.

The wrong lesson to draw is "fabric-quickstart needs a local orchestration
mode". The right question is narrower: what is fabric-quickstart for, and where
does it stop.

## Decision

**fabric-quickstart is a substrate provisioner. It does not orchestrate actors.**

The two are different shapes of work.

**Provisioning runs once and exits.** It creates the things the engine cannot
create for itself because they must exist before the engine does:

- FoundationDB coordinators at static addresses, because a coordinator is
  addressed by IP and a restart reassigns it. See
  [RFD 0002](0002-allocate-addresses.md).
- The engine topology, because `public_url` has to name an address the runners
  can reach, and it cannot be set from the environment. See
  [RFD 0003](0003-engine-configuration.md).
- Runner registration, so the engine knows a runner exists.

Then it gets out of the way. `fdb-up`, `engine-up`, `register-runner`,
`destroy`: each is a one-shot verb, and the name says so. It is a quickstart.

**Orchestration runs continuously.** Actor lifecycle, single-writer exclusivity,
scheduling, restart on failure, draining on upgrade. This is Pegboard, inside
the engine, and it is the entire reason Rivet exists. A provisioner that took
this on would be orchestrating the thing that orchestrates.

The repository already forbids the moves such a layer would need: no engine-side
transaction ownership, no separate same-actor concurrency fence, do not break
the actor abstraction. Those rules exist precisely so nothing grows a second
orchestrator beside Pegboard.

### The test for where something belongs

If it is a one-shot setup step that Pegboard cannot perform because it must
happen before the engine is running, it is provisioning and it belongs here. If
it is a continuous reconciliation of actor state, it is Pegboard's and it does
not.

Running the godot zone is the second kind. The engine cold-starts the container
and calls `/api/rivet/start`; that is orchestration, and it already works. What
fabric-quickstart owns is registering the runner config, not running the actor.

## The growth path, deferred

fabric-quickstart already provisions two substrates, systemd quadlets on
localhost and Fly. Growing it to provision a real multi-host cluster is
continuous with that, not a new thing:

- A FoundationDB cluster across machines, with fault tolerance beyond one host.
- Coordinator replacement when a machine is lost, holding the quorum
  [RFD 0002](0002-allocate-addresses.md) protects.
- Backup rotation to an off-host target, per
  [RFD 0013](0013-foundationdb-backup.md).

All of this is still provisioning. None of it is actor orchestration.

It is deferred, not planned. [RFD 0016](0016-collapse-the-substrate-port.md)
removed the substrate abstraction port because only two implementations existed,
and [RFD 0021](0021-when-structure-is-justified.md) is the rule that keeps it
removed until a third real substrate appears. Multi-host provisioning is built
when a second production host is actually wanted, not before.

## Consequences

The name stays honest. A quickstart bootstraps and tears down; it does not
babysit.

For running a single container actor locally, the coded path is not
fabric-quickstart at all. It is `container-runner/examples/e2e-test/` in the
main repository: a docker-compose engine, `configure-serverless.mjs` for the
runner config, and `create-actor.mjs`. That harness is for local single-actor
work; fabric-quickstart is for standing up a cluster.

The hand-wiring that prompted this RFD is the anti-pattern it rules out. The fix
was never a new local mode; it was using the process that already exists.

## What stays out, permanently

Actor lifecycle, exclusivity, scheduling, health-driven restart, and scaling.
All Pegboard. A provisioner that reached into any of these would be a second
orchestrator, and there is exactly one.

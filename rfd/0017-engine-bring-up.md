# RFD 0017 — Engine bring-up and runner registration

## Status

Implemented, **not exercised end to end.** The code path exists and compiles;
the engine image has not been built or run under this repo, so `engine-up` has
never completed successfully here.

## Problem

Three functions in `RivetFabric.Domain.Cluster` had tests but no production
caller: `topology/1`, `runner_config/2`, and `cluster_file/3`. Under the
YAGNI-as-timing limits that removed the substrate port
([RFD 0016](0016-collapse-the-substrate-port.md)) they were candidates for
deletion.

Deleting them would have discarded the only executable record of two engine
constraints that were expensive to find:

- a datacenter must **omit** `name`, because it is derived from the map key
  ([RFD 0003](0003-engine-configuration.md))
- `drain_grace_period` must be strictly less than `request_lifespan`
  ([RFD 0010](0010-serverless-runner-configuration.md))

## Decision

Add the caller rather than remove the code. The need was always real; it just
had not been built yet, which is a different situation from structure built for
a need that may never arrive.

`Bootstrap.engine/3` brings the engine up as a quadlet node against the running
FoundationDB cluster:

1. `node_ensure` with a static address, matching
   [RFD 0002](0002-allocate-addresses.md)
2. write `/etc/rivet/topology.json` from `Cluster.topology/1`
3. write `/etc/foundationdb/fdb.cluster` from `Cluster.cluster_file/3`
4. restart, because both files are read at startup
5. poll `/health` until it answers

`Bootstrap.register_runner/2` registers a container as a serverless runner using
`Cluster.runner_config/2`.

Both are reachable from the CLI as `engine-up` and `runner-register`.

## Consequences

`node_write_file` and `node_restart` regain production callers. They had been
demoted to internal functions when the static-addressing design removed the need
for them; writing config into a container is that need reappearing for a
different reason.

`topology/1` is the reason `node_write_file` has to exist at all. The engine's
topology cannot be supplied through environment variables, so there must be a
way to put a file inside a running node.

HTTP goes through `RivetFabric.Http`, a thin `:httpc` wrapper, rather than a
dependency ([RFD 0015](0015-tooling-constraints.md)). It carries exactly two
operations, a health probe and a JSON PUT, because a third was written and
removed on the same grounds this RFD exists to serve.

## What is not verified

The engine image compiles Rust from source and is not built by `fdb-up`. Nothing
here has run against a live engine. Specifically unverified:

- that the engine accepts the topology file as written
- that `public_url` set to the container's network name is reachable by an envoy
- that runner registration succeeds

The shapes themselves come from a working deployment, but that deployment set
them by hand rather than through this code.

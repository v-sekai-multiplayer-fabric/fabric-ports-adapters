# fabric-ports-adapters

Recreate a FoundationDB-backed Rivet cluster locally on **podman + systemd
quadlets**.

## Quick start

```sh
mix test                                          # 28 tests, no podman needed
mix run -e 'RivetFabric.CLI.main(["doctor"])'     # check prerequisites
mix run -e 'RivetFabric.CLI.main(["fdb-up"])'     # bring up the cluster
mix run -e 'RivetFabric.CLI.main(["destroy"])'    # tear it down
```

`fdb-up` builds the FoundationDB image, creates a podman network with a fixed
subnet, writes one `.container` quadlet unit per node under
`~/.config/containers/systemd/`, reloads systemd, starts the units, runs
`configure new`, and waits for the database to report itself available.

`--count 1` gives a single-node cluster with `single` redundancy and no fault
tolerance.

## Why ports and adapters

`RivetFabric.Ports.Substrate` is a behaviour describing what the bootstrap needs
from the world: create a node, list nodes, exec in a node, write a file into a
node, restart, stop, destroy. Two adapters implement it:

| Adapter | Backed by | Purpose |
|---|---|---|
| `Adapters.Quadlet` | podman + systemd quadlets | the real thing |
| `Adapters.Fake` | in memory | tests, no containers needed |

The payoff is that the bugs below are reproducible in unit tests that run in
milliseconds, instead of only against a live cluster.

## Addresses are allocated, not discovered

This is the design decision the repo exists to record, and it was arrived at by
breaking it three times.

FoundationDB records coordinators by IP, so a cluster cannot form until the
addresses are known. The obvious sequence is: create the nodes, read their
addresses back, rewrite each cluster file, restart. Every step of that fails
quietly under podman.

**1. A node with no `FDB_COORDINATORS` names itself as sole coordinator.** Three
such nodes are three independent one-node clusters. Each logs `FDBD joined
cluster`, so all three look healthy, and `configure new` then succeeds against
exactly one and orphans the rest.

**2. Rewriting the cluster file does not take effect.** `fdbserver` reads it once
at startup. The natural fix, `kill 1` inside the container, silently does
nothing: the kernel discards unhandled signals sent to PID 1 from inside its own
PID namespace. Observed as a node whose on-disk file was correct while its log
still showed the old self-only set:

```
starting fdbserver on 10.89.0.2:4500
rivet:rivet@10.89.0.2:4500        <- self-only, but disk already had the merged set
```

**3. Restarting through systemd works, and then invalidates the addresses.**
Podman assigns a new address on every restart, so the restart that applies a new
coordinator list also makes that list wrong:

| | coordinator list | actual IP after restart |
|---|---|---|
| node1 | `10.89.0.5` | `10.89.0.8` |
| node2 | `10.89.0.6` | `10.89.0.9` |
| node3 | `10.89.0.7` | `10.89.0.10` |

The sequence is circular. So addresses are **allocated up front** instead:
`Spec.fdb_plan/1` assigns node N a static address on a dedicated subnet, the
coordinator set is computed before anything is created, and it is passed to each
node at creation. No restart is needed, and no node ever runs with a self-only
cluster file.

That also makes the cluster survive a restart, which is verified:

```
$ systemctl --user restart mf-rivet-fdb--mf-rivet-fdb-1.service
$ podman inspect -f '...' mf-rivet-fdb--mf-rivet-fdb-1
10.89.100.11                       <- unchanged, still in the coordinator set
$ fdbcli --exec 'status minimal'
The database is available
```

## Other things this encodes

**The engine's topology cannot be set through environment variables.**
`topology.datacenters` deserializes through an untagged enum that the env-var
source cannot merge into. Setting `RIVET__TOPOLOGY__DATACENTERS__DEFAULT__*`
fails startup with `failed to deserialize config` even with every required field
present. It has to be a file, which is why `node_write_file` is in the port.

**`name` must be omitted from a datacenter.** In the map form it is derived from
the key, and setting it is rejected: "cannot have the `name` property set
because it is automatically derived from key".

**`public_url` must be reachable from other nodes.** The engine hands it to each
envoy as `x-rivet-endpoint`, and the envoy dials it. The default
`http://127.0.0.1:6420` resolves inside the envoy's *own* container, so every
connection fails with `Connection refused` while the engine looks healthy.

**`drain_grace_period` must be less than `request_lifespan`.** It defaults to
1800s, so a shorter lifespan is rejected with a 400.
`Cluster.runner_config/2` returns `{:error, _}` rather than letting the API do it.

**Client and server FoundationDB versions are coupled.** The engine image embeds
`libfdb_c.so`, which must stay protocol-compatible with `fdbserver`. Both come
from the same pinned base image so they cannot drift.

## Images

`fdb-up` builds only the FoundationDB image. The other two compile Rust from
source and take a long time, so build them deliberately:

```sh
podman build -t rivet-fabric/engine -f assets/engine/Containerfile assets/engine
podman build -t rivet-fabric/godot-zone -f assets/godot_zone/Containerfile assets/godot_zone
```

**The Godot zone needs the fork's engine build**, from
[v-sekai-multiplayer-fabric/godot-images](https://github.com/v-sekai-multiplayer-fabric/godot-images).
That build is double-precision
(`godot.linuxbsd.template_release.double.x86_64`) and is **not**
interchangeable with an upstream godotengine.org release: mixing precisions
breaks networked state between the zone and its clients.

`ghcr.io/v-sekai-multiplayer-fabric/zone-godot-runtime` is a private package, so
either authenticate:

```sh
podman login ghcr.io
```

or build it locally from `godot-images`, which ships quadlet `.build` units for
exactly this:

```sh
systemctl --user start zone-godot-runtime-build
```

**The FoundationDB backend is not in upstream Rivet.** Upstream supports
Postgres and a RocksDB file-system backend; the `Database` enum has no
FoundationDB variant. The backend used here lives on a branch of the fork,
pinned in `domain/spec.ex`:

```
https://github.com/v-sekai-multiplayer-fabric/rivet.git
a6cd747fcd49e9f28f9c8a0c622456e763e3d771
```

## Layout

```
lib/rivet_fabric/
  ports/substrate.ex    the port: what a substrate must provide
  adapters/quadlet.ex   podman + systemd quadlets
  adapters/fake.ex      in memory; still models the split-cluster trap
  domain/cluster.ex     pure logic, no I/O
  domain/spec.ex        pinned versions, static address plan
  bootstrap.ex          the sequence, written against the port
  shell.ex              process execution, isolated
  cli.ex
assets/
  foundationdb/         entrypoint + Containerfile
  engine/Containerfile  Rivet Engine with the foundationdb feature
  godot_zone/Containerfile  headless Godot MCP zone on the fork runtime
```

## What is verified

- **28 tests**, deterministic across randomized seeds. They cover the pure
  domain logic and the bootstrap against the fake adapter, including regressions
  for all three failures above.
- **A live 3-node cluster** brought up by `fdb-up` on this design: `double`
  redundancy, 3 coordinators, fault tolerance of 1 machine, database available,
  and addresses that survive a `systemctl restart`.
- **Not verified:** the engine and godot-zone images have not been built or run
  under this repo. The engine-side notes above come from a working deployment
  elsewhere, not from a run of this code.

## Requirements

- Elixir 1.15+ (built on 1.20 / OTP 29). No dependencies; `JSON` is from OTP.
- Rootless podman 4.4+ and the podman user generator at
  `/usr/lib/systemd/user-generators/podman-user-generator`.

Run `doctor` to check.

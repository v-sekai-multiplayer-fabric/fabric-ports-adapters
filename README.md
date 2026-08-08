# rivet-fabric-ports-adapters

Recreate a FoundationDB-backed Rivet cluster, locally on **systemd quadlets** or
remotely on **Fly.io**, from the same bootstrap sequence.

Status: **proof of concept.** See [What is proven](#what-is-proven) for exactly
what has and has not been executed.

## Why ports and adapters

The bootstrap sequence is the valuable part, and it is substrate-independent:

1. create nodes, each of which bootstraps as its own sole coordinator
2. read their addresses back
3. force every node onto one shared coordinator set
4. only then `configure new`

FoundationDB coordinators are addressed by IP, and the addresses do not exist
until the nodes do. That two-phase shape is what makes the whole thing awkward,
and it is identical on podman and on Fly. So it lives once, in
`RivetFabric.Bootstrap`, written against a port.

`RivetFabric.Ports.Substrate` is an Elixir behaviour describing what a substrate
must provide: create a node, list nodes with their addresses, exec in a node,
write a file into a node, stop, destroy. Three adapters implement it:

| Adapter | Substrate | Purpose |
|---|---|---|
| `Adapters.Quadlet` | podman + systemd quadlets | local testing, costs nothing |
| `Adapters.Fly` | flyctl | remote deployment |
| `Adapters.Fake` | in-memory | unit tests, no containers needed |

The payoff is that the ordering bug below is reproducible in a unit test.

## Quick start

```sh
mix deps.get          # there are no deps; this is a no-op
mix test              # 21 tests, no podman required
mix run -e 'RivetFabric.CLI.main(["doctor"])'
mix run -e 'RivetFabric.CLI.main(["fdb-up"])'
mix run -e 'RivetFabric.CLI.main(["destroy"])'
```

`fdb-up` builds the FoundationDB image, writes one `.container` quadlet unit per
node under `~/.config/containers/systemd/`, reloads systemd, starts them, and
runs the bootstrap.

Target Fly instead with `--substrate fly`. Use `--count 1` for a single-node
cluster, which configures `single` redundancy and has no fault tolerance.

## What this encodes

Each of these cost a broken deployment. None is guessable from the Rivet source.

**Fresh nodes silently form separate clusters.** A node created before the
coordinator set is known writes a cluster file naming only itself. Three such
nodes are three independent one-node clusters, and every one of them logs
`FDBD joined cluster`, so they look healthy. `configure new` then succeeds
against exactly one and orphans the rest. `Bootstrap.verify_agreement/3` refuses
to continue unless every node's cluster file matches, and
`test/bootstrap_test.exs` reproduces the failure.

**The engine's topology cannot be set through environment variables.**
`topology.datacenters` deserializes through an untagged enum that the env-var
source cannot merge into. Setting `RIVET__TOPOLOGY__DATACENTERS__DEFAULT__*`
fails startup with `failed to deserialize config` even with every required field
supplied. It has to be a file, which is why `node_write_file` is part of the
port at all.

**`name` must be omitted from a datacenter.** In the map form it is derived from
the key, and setting it explicitly is rejected: "cannot have the `name` property
set because it is automatically derived from key".

**`public_url` must be reachable from other nodes.** The engine hands it to each
envoy as `x-rivet-endpoint`, and the envoy dials it. The default is
`http://127.0.0.1:6420`, which the envoy resolves inside its *own* container, so
every connection fails with `Connection refused` while the engine looks healthy.

**`drain_grace_period` must be less than `request_lifespan`.** It defaults to
1800s, so a runner config with a shorter lifespan is rejected with a 400.
`Cluster.runner_config/2` returns `{:error, _}` rather than letting the API
reject it.

**IPv6 addresses must be bracketed** in cluster files. Fly's private network is
IPv6-only, so this is the normal case there; podman gives IPv4, so local testing
does not exercise it. `Cluster.address/2` handles both and is doctested.

**Client and server FoundationDB versions are coupled.** The engine image embeds
`libfdb_c.so`, which must stay protocol-compatible with `fdbserver`. Both come
from the same pinned base image so they cannot drift apart.

## Layout

```
lib/rivet_fabric/
  ports/substrate.ex      the port: what a substrate must provide
  adapters/quadlet.ex     podman + systemd quadlets
  adapters/fly.ex         flyctl
  adapters/fake.ex        in-memory, models the split-cluster trap
  domain/cluster.ex       pure logic, no I/O
  domain/spec.ex          pinned versions and topology, pure data
  bootstrap.ex            the sequence, written against the port
  shell.ex               process execution, isolated
  cli.ex
assets/
  foundationdb/           entrypoint + Containerfile, substrate-neutral
  engine/Containerfile    Rivet Engine with the foundationdb feature
  godot_zone/Containerfile headless Godot MCP zone
```

## The FoundationDB backend is not upstream

Upstream Rivet supports Postgres and a RocksDB file-system backend. The
`Database` enum has no FoundationDB variant and `universaldb` has no FDB driver.
The backend used here lives on a branch of the fork and is pinned in
`domain/spec.ex`:

```
https://github.com/v-sekai-multiplayer-fabric/rivet.git
a6cd747fcd49e9f28f9c8a0c622456e763e3d771
```

The engine and godot-zone Containerfiles clone that ref and build it. Both
compile Rust from source and take a long time; `fdb-up` does not build them.

## What is proven

Being precise here, because a proof of concept that overstates itself is worse
than none.

- **Verified:** 21 tests pass, deterministically across randomized seeds. They
  cover the pure domain logic and the bootstrap ordering against the fake
  adapter, including the split-cluster reproduction.
- **Verified previously, outside this repo:** the same sequence run by hand on
  Fly produced a live 3-node `double`-redundancy cluster, a Rivet engine serving
  on FoundationDB, and a Godot actor answering MCP calls through the gateway.
- **Not yet verified:** the quadlet adapter driving a real local cluster
  end-to-end, and the `Adapters.Fly` code path, which was transcribed from
  working manual commands but has not been run as written.
- **Not built here:** the engine and godot-zone images.

## Requirements

- Elixir 1.15+ (built on 1.20 / OTP 29). No dependencies; `JSON` comes from OTP.
- For quadlet: rootless podman 4.4+ and the podman user generator at
  `/usr/lib/systemd/user-generators/podman-user-generator`.
- For Fly: `flyctl`, authenticated.

Run `doctor` to check.

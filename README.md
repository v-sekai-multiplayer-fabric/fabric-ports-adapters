# fabric-ports-adapters

Recreate a FoundationDB-backed Rivet cluster locally on **podman + systemd
quadlets**.

```sh
mix test                                          # no podman needed
mix run -e 'RivetFabric.CLI.main(["doctor"])'     # check prerequisites
mix run -e 'RivetFabric.CLI.main(["fdb-up"])'     # bring up the cluster
mix run -e 'RivetFabric.CLI.main(["destroy"])'    # tear it down
```

## RFDs

The reasoning lives in [`rfd/`](rfd/). These are decision records, not manuals:
each one states a problem, what was decided, and what it cost.

| RFD | Title |
|---|---|
| [0001](rfd/0001-substrate-port.md) | A substrate port for cluster bootstrap |
| [0002](rfd/0002-allocate-addresses.md) | Allocate node addresses, do not discover them |
| [0003](rfd/0003-engine-configuration.md) | Engine configuration constraints |
| [0004](rfd/0004-image-provenance.md) | Image provenance and version coupling |

Start with [RFD 0002](rfd/0002-allocate-addresses.md). It is the one that took
three attempts to get right, and it explains why the bootstrap looks the way it
does.

## Layout

```
lib/rivet_fabric/
  ports/substrate.ex    the port: what a substrate must provide
  adapters/quadlet.ex   podman + systemd quadlets
  adapters/fake.ex      in memory; models the split-cluster trap
  domain/cluster.ex     pure logic, no I/O
  domain/spec.ex        pinned versions, static address plan
  bootstrap.ex          the sequence, written against the port
  shell.ex              process execution, isolated
  cli.ex
assets/
  foundationdb/         entrypoint + Containerfile
  engine/               Rivet Engine with the foundationdb feature
  godot_zone/           headless Godot MCP zone on the fork runtime
```

## What is verified

- The test suite, deterministic across randomized seeds, covering the pure
  domain logic and the bootstrap against the fake adapter.
- A live 3-node cluster from `fdb-up`: `double` redundancy, 3 coordinators,
  fault tolerance of 1 machine, database available, addresses stable across
  `systemctl restart`.
- **Not verified:** the engine and godot-zone images have not been built or run
  here. See [RFD 0003](rfd/0003-engine-configuration.md) and
  [RFD 0004](rfd/0004-image-provenance.md) for where that knowledge came from.

## Requirements

- Elixir 1.15+ (built on 1.20 / OTP 29). No dependencies; `JSON` is from OTP.
- Rootless podman 4.4+ and the podman user generator at
  `/usr/lib/systemd/user-generators/podman-user-generator`.

`doctor` checks both.

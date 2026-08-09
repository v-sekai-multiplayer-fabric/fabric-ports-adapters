# RFD 0003 — Engine configuration constraints

## Status

Accepted. Encoded in `RivetFabric.Domain.Cluster` and `RivetFabric.Bootstrap`.
The topology and datacenter constraints were derived from a working deployment
outside this repo; the FoundationDB and start-ordering constraints are confirmed
by the local podman quadlet bring-up in this repo.

Serverless runner configuration was split out into
[RFD 0010](0010-serverless-runner-configuration.md). This RFD now covers only
the engine's own configuration file.

## Problem

Three Rivet Engine topology requirements are not discoverable from the source or
the docs, and each fails in a way that points somewhere else. Recording them
keeps them from being rediscovered.

## Constraints

### Topology must be a file, not environment variables

`topology.datacenters` deserializes through an untagged enum. The environment
variable config source cannot merge into it. Setting

```
RIVET__TOPOLOGY__DATACENTERS__DEFAULT__PUBLIC_URL=...
RIVET__TOPOLOGY__DATACENTERS__DEFAULT__PEER_URL=...
```

fails startup with `failed to deserialize config`, and it still fails with every
required field supplied (`name`, `datacenter_label`, `is_leader`, both URLs).

The engine merges every config file in `/etc/rivet`, so the topology is a JSON
file placed there. It is delivered as a **read-only bind mount at container
creation**, the podman equivalent of the Fly deploy's
`flyctl machine update --file-literal`. It is not written into a running
container, for the reason in "Config must be complete at first start" below.

### `name` must be omitted from a datacenter

In the map form, a datacenter's name is derived from its key. Setting it
explicitly is rejected:

```
Error: datacenter 'default' cannot have the `name` property set because it is
automatically derived from key
```

`Cluster.topology/1` omits it, and a test asserts the key is absent rather than
merely unused.

### `public_url` must be reachable from other nodes

The engine hands each envoy its datacenter's `public_url` as the
`x-rivet-endpoint` header, and the envoy dials that address to open its
WebSocket back.

The default is `http://127.0.0.1:6420`, which an envoy resolves inside its
**own** container. Every connection then fails with `Connection refused` while
the engine itself reports healthy and serves requests normally. The symptom
appears entirely on the runner side, which is the wrong place to look.


### FoundationDB is configured by addresses, not a mounted cluster file

The engine takes `RIVET__FOUNDATIONDB__ADDRESSES` (comma-separated
`ip:port` coordinators) plus `CLUSTER_DESCRIPTION`, `CLUSTER_ID`, and
`CLUSTER_FILE_WRITE_PATH`, and **writes its own `fdb.cluster` file at startup**
via `resolve_cluster_file`. This is how the Fly deploy configures it, and it is
the same on podman: the mechanism is in the engine binary, not the substrate.

The coordinators passed are exactly the set the FoundationDB nodes agreed on, so
the engine reaches the same cluster without a cluster file being injected. There
is no reason to mount a cluster file or to write one into the container.

### Config must be complete at first start

The engine exits immediately if it cannot open FoundationDB, with

```
foundationdb error 1515: No cluster file found in current directory or default location
```

Under `Restart=always` this becomes a crash loop that systemd abandons after a
few attempts (`Start request repeated too quickly`). So all config, both the
FoundationDB addresses and the topology file, is present the moment the
container starts. An earlier version started the engine first and delivered
config afterwards with `podman cp` plus a restart; the engine never survived
long enough to be reconfigured, and `podman cp` raced the container being
recreated. Delivering config up front removes the loop rather than racing it.

## Consequences

These are encoded as pure functions with tests, so they are checked without an
engine running. That is also their limitation: the tests assert that this repo
produces the right shapes, not that the engine accepts them. The evidence for
the shapes being right comes from a deployment outside this repo.

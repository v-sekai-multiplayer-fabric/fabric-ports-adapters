# RFD 0003 — Engine configuration constraints

## Status

Accepted. Encoded in `RivetFabric.Domain.Cluster`. Derived from a working
deployment, **not** from a run of this repo's engine image.

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

The engine merges every config file in `/etc/rivet`, so the topology is written
there as JSON. This constraint is the only reason `node_write_file` exists in
the substrate port ([RFD 0001](0001-substrate-port.md)).

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


## Consequences

These are encoded as pure functions with tests, so they are checked without an
engine running. That is also their limitation: the tests assert that this repo
produces the right shapes, not that the engine accepts them. The evidence for
the shapes being right comes from a deployment outside this repo.

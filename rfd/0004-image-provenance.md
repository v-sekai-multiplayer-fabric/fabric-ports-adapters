# RFD 0004 — Image provenance and version coupling

## Status

Accepted. Pinned in `RivetFabric.Domain.Spec`.

Godot runtime provenance was split out into
[RFD 0011](0011-godot-runtime-provenance.md), because its failure mode is
different: an upstream substitute builds and runs, and only desynchronises
later.

## Problem

The Rivet engine cannot be taken from upstream, and its FoundationDB client is
coupled to the cluster's server version in a way that fails late if it drifts.

## Decisions

### The FoundationDB backend comes from a fork branch

Upstream Rivet supports Postgres and a RocksDB file-system backend. Its
`Database` enum has no FoundationDB variant, and `universaldb/src/driver/`
contains only `postgres/` and `rocksdb/`. FoundationDB is documented as
enterprise-only.

The backend used here was added on a branch of the fork and is pinned:

```
https://github.com/v-sekai-multiplayer-fabric/rivet.git
a6cd747fcd49e9f28f9c8a0c622456e763e3d771
```

It sits behind a default-off `foundationdb` cargo feature, because it hard
requires `libfdb_c.so` at build and run time and a default-on feature would
break every build on a machine without FoundationDB installed.

### FoundationDB client and server versions are coupled

The engine image embeds `libfdb_c.so`, which must stay protocol-compatible with
the `fdbserver` running in the storage nodes. Both are taken from the same
pinned `docker.io/foundationdb/foundationdb:7.3.76` base image so they cannot
drift independently. Upgrading the cluster means rebuilding the engine image in
the same change.

The crate also expects `fdb.options` under `/usr/include/foundationdb`, which
the runtime-only package does not ship. The `embedded-fdb-include` feature
vendors it.


### Images are fully qualified

Every `FROM` uses a fully qualified name (`docker.io/library/debian`, not
`debian`). Rootless podman enforces short-name resolution and cannot prompt
without a TTY, so an unqualified name fails the build with
`short-name resolution enforced but cannot prompt without a TTY`.

## Consequences

`fdb-up` builds only the FoundationDB image. The engine and zone images compile
Rust from source and are built deliberately rather than as part of bootstrap.

Neither has been built or run under this repo. The engine-side knowledge in
[RFD 0003](0003-engine-configuration.md) comes from a deployment elsewhere.

The driver being pinned here is described in
[RFD 0014](0014-foundationdb-driver.md).

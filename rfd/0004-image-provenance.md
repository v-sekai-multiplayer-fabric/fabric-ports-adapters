# RFD 0004 — Image provenance and version coupling

## Status

Accepted. Pinned in `RivetFabric.Domain.Spec`.

## Problem

Three of the images this cluster needs cannot be taken from their obvious
upstream source, and two pairs of versions are coupled in ways that fail late
and confusingly if they drift.

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

### Godot comes from the fork's build, not godotengine.org

The zone image is based on
`ghcr.io/v-sekai-multiplayer-fabric/zone-godot-runtime`, built by
[v-sekai-multiplayer-fabric/godot-images](https://github.com/v-sekai-multiplayer-fabric/godot-images).

That build is **double-precision**
(`godot.linuxbsd.template_release.double.x86_64`). It is not interchangeable
with an upstream release: mixing precisions breaks networked state between the
zone and its clients. An earlier revision of this repo substituted an upstream
`Godot_v4.7.1-stable_linux.x86_64` download, which builds and runs fine and
would have failed later as desync rather than as a build error.

The package is private. Building the zone image therefore needs either

```sh
podman login ghcr.io
```

or a local build from `godot-images`, which ships quadlet `.build` units for
exactly this:

```sh
systemctl --user start zone-godot-runtime-build
```

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

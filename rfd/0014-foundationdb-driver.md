# RFD 0014 — A FoundationDB driver for UniversalDB

## Status

Accepted, implemented, verified. Backfilled: this work predates the RFD
directory and was previously recorded only in the Rivet fork.

Lives on the fork at `a6cd747fcd49e9f28f9c8a0c622456e763e3d771`, behind a
default-off `foundationdb` cargo feature. Six driver tests pass against a real
FoundationDB 7.3.76 cluster.

## Problem

Upstream Rivet has no FoundationDB backend. `Database` is
`{Postgres, FileSystem}` with `deny_unknown_fields`, and
`universaldb/src/driver/` contains only `postgres/` and `rocksdb/`.
FoundationDB is documented as enterprise-only.

Without a driver, no configuration can point the engine at an FDB cluster, so
everything else in this repo has nothing to stand on.

## The work was smaller than expected

UniversalDB's public surface is a copy of the FoundationDB Rust bindings.
`KeySelector`, `RangeOption`, `StreamingMode`, `MutationType`,
`ConflictRangeType`, `Priority`, and the `Slice`/`Value`/`Values` types are
field-for-field identical, several still carrying the upstream Apache/MIT
header. `range_option.rs` carries the foundationdb-rs copyright, and `value.rs`
documents a type as existing "to match FoundationDB API".

The residue is visible elsewhere:

- `config/src/lib.rs` registers an env list-parse key for
  `foundationdb.addresses`, a config path with no struct behind it.
- `universaldb/src/utils/mod.rs` defines `error_is_transaction_too_large`
  returning a hardcoded `false`, commented "Only implemented with fdb".
- `universaldb/src/error.rs` marks `TransactionTooOld` as
  "TODO: Implement in rocksdb and postgres drivers".

So the abstraction was designed around FoundationDB and the other two drivers
are the approximations. The FDB driver is largely passthrough: the Postgres
driver needs a `bytearange` type, a GiST exclusion constraint, and a GC task to
emulate serialisable conflict ranges, and the RocksDB driver needs a conflict
tracker and a per-transaction task. FoundationDB provides those natively.

## Decisions

### The network thread is process-global and never stops

`foundationdb::boot()` may be called once per process and returns a
`NetworkAutoStop` guard whose `Drop` calls `fdb_stop_network()` and aborts the
process on failure. Dropping it while a `Database` handle is open is a crash.

It lives in a `static OnceLock<NetworkAutoStop>`. Statics are never dropped,
which is the desired behaviour and avoids a `Box::leak`.

### Commit consumes the transaction; the trait does not

`TransactionDriver` exposes `commit_ref(&self)`, while
`foundationdb::Transaction::commit(self)` takes ownership.

The handle is held as `parking_lot::Mutex<Option<Arc<Transaction>>>`; commit
takes the `Option` and `Arc::try_unwrap`s it. `parking_lot` rather than
`tokio::sync` because `set`, `clear`, `atomic_op`, and `cancel` are synchronous
`&self` trait methods. A commit racing an open range stream fails loudly instead
of silently skipping the commit.

### FoundationDB classifies its own errors

The retry loop prefers `FdbError::is_retryable()` and `is_maybe_committed()`
over the generic `DatabaseError` mapping, falling back to the latter for errors
raised by user closures.

The verdict is resolved into a plain value **before** the backoff await, because
a borrowed `dyn Error` is not `Sync` and holding one across the await makes the
future non-`Send`.

### The feature is on by default

Originally off, on the grounds that `libfdb_c.so` is required at build and run
time and a default-on feature breaks every build on a machine without
FoundationDB installed.

**Changed in `0d7bcdde6`:** the fork exists to add this backend, so a build
without it is not a configuration anyone wants, and the default should say so.
The consequence is not confined to the engine: `universaldb` has 22 workspace
dependents, so every one of them now requires the client library, including in
CI.

Selecting `FoundationDb` in config on a binary built without the feature is
still an explicit error, not a silent fallback to another backend.

The crate expects `fdb.options` under `/usr/include/foundationdb`, which the
runtime-only package does not ship; the `embedded-fdb-include` feature vendors
it.

## Consequences

FoundationDB becomes a configuration choice for Rivet, which is what
[RFD 0008](0008-hot-tier-foundationdb.md) depends on.

The engine image and the cluster are now version-coupled: the image embeds
`libfdb_c.so`, which must stay protocol-compatible with `fdbserver`. Both come
from the same pinned base image so they cannot drift.
See [RFD 0004](0004-image-provenance.md).

## What is verified

Six integration tests against a live FoundationDB 7.3.76 cluster: set/get
roundtrip, missing keys, ordered range scans, atomic `Add` accumulation, clears,
and conflict ranges. They skip unless `FDB_CLUSTER_FILE` is set, so the suite
still passes without FoundationDB present.

**Not verified:** performance. There is no benchmark. FoundationDB's five-second
transaction limit interacts with Rivet's `TXN_TIMEOUT` in ways that remain
unmeasured, and a cold read on an undersized cluster was observed at
`duration_ms=2200`.

Separately, `universaldb/tests/integration.rs` does not compile on that branch
and did not before the change either; it references
`universaldb::options::DatabaseOption` and `Database::set_option`, neither of
which exists.

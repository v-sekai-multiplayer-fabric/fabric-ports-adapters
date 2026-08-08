# RFD 0009 — Cold tier and backup

## Status

Proposed. Nothing implemented. Was issue #7, split out of issue #4, with
issue #3 folded in.

## Goal

Offload idle actor database chunks from FoundationDB to S3-compatible storage so
dormant state costs object-storage prices, and stream it back on demand when an
actor wakes.

## Current state: nothing exists

Verified, not assumed:

```
$ grep -rniE "s3|object.store|blobstore|aws_sdk" engine/packages/depot/src/
(no matches)
```

Depot's compaction folds DELTA blobs into SHARD blobs and deletes the originals,
but **both stay in UniversalDB**. There is no eviction to external storage and
no rehydration path.

### A naming trap worth pinning down first

`docs-internal/engine/SQLITE_OPTIMIZATIONS.md` discusses "cold reads"
throughout, and there are checked-in cold-read benchmarks. **That means
cache-cold, not cold-tier.** It concerns a 50 MiB full scan taking 20.14s across
1,249 VFS `get_pages` calls, entirely within the hot store. Anyone searching for
prior art on tiering will find these and conclude the work is underway. It is
not.

## Design questions

- **Eviction unit.** SHARD blobs are the natural candidate since compaction
  already produces them. But PIDX maps page numbers to blob references, so
  eviction must rewrite PIDX entries to point at an external location without
  breaking the `COMPARE_AND_CLEAR` semantics compaction relies on.
- **Eviction trigger.** Actor idle time, blob age, or quota pressure. `CTR`
  already tracks billable bytes as a signed atomic counter and would need to
  distinguish hot from cold bytes.
- **Rehydration granularity.** Streaming a whole shard back on first touch is
  simple but pathological for a single-page read. The existing read-ahead work
  (`RIVETKIT_SQLITE_OPT_READ_AHEAD_MODE`) is relevant prior art.
- **Latency budget.** A cold-tier fetch cannot fit inside FDB's five-second
  transaction limit, so rehydration must happen outside the transaction that
  needed the page, with a retry.
- **Restore points and branching.** Depot supports forks, `RESTORE_POINT`, and
  history pins. Evicted blobs may still be referenced by ancestors, so GC must
  not delete an object a parent branch still pins.
- **VFS parity.** `docs-internal/engine/sqlite-vfs.md` requires the native Rust
  VFS and the WASM TypeScript VFS to stay 1:1. A cold-tier read path must exist
  in both or that rule breaks.

## The S3 gateway: versitygw

<https://github.com/versity/versitygw>, folded in from issue #3.

It serves two purposes that should not be conflated, because their profiles are
opposite.

### 1. Backup target

FoundationDB backs up to S3 natively. `fdbbackup` is present in the 7.3.76 image
and accepts a blobstore URL directly:

```
blobstore://<api_key>:<secret>:<security_token>@<host>[:<port>]/<name>?bucket=<bucket>
```

This needs **no Rivet changes at all** and closes a gap already recorded as an
open risk: the validated deployment had no backups configured, with the volumes
as the only copy. It is the cheaper and more urgent of the two and can land
independently of any cold-tier work.

### 2. Cold tier target

The offload path above.

Backup is write-mostly, sequential, latency-tolerant, and off the request path.
A cold tier is random-access, latency-sensitive, and directly on the actor wake
path. One versitygw deployment can serve both, but sizing and durability should
be decided per use rather than shared by default.

## Tasks

### Backup

- [ ] Stand up versitygw as a quadlet alongside the FoundationDB nodes.
- [ ] Configure `fdbbackup` against it and verify a **restore**, not just a
      backup.
- [ ] Decide cadence, retention, and whether backup runs continuously or
      scheduled.

### Cold tier

- [ ] Decide eviction unit and how PIDX represents an external reference.
- [ ] Add an object-store port so the backend is swappable, matching the
      ports-and-adapters shape of this repo
      ([RFD 0001](0001-substrate-port.md)).
- [ ] Implement eviction in the compaction worker.
- [ ] Implement rehydration in the VFS read path, native and WASM.
- [ ] Extend quota accounting to separate hot and cold bytes.
- [ ] Ensure GC and fork/restore-point pinning account for evicted objects.
- [ ] Benchmark wake latency for a fully cold actor.

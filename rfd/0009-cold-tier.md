# RFD 0009 — Cold tier

## Status

Proposed. Nothing implemented. Was issue #7, split out of issue #4.

Backup was split out into [RFD 0013](0013-foundationdb-backup.md). The two share
an S3 endpoint and nothing else, and bundling them made a one-day task look like
part of a large project.

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

## Storage backend

Whatever S3-compatible endpoint is chosen, it is shared with
[RFD 0013](0013-foundationdb-backup.md), which proposes versitygw. Sizing and
durability should be decided per use rather than shared by default: backup is
sequential, write-mostly, and off the request path, while a cold tier is
random-access and directly on the actor wake path.

Archival data has a further constraint from
[RFD 0006](0006-zone-baker-as-rivet-service.md): OpenUSD masters are the last
copy of their structure and must never be evicted somewhere unrecoverable,
whereas derived transmission formats are regenerable and can be dropped freely.

## Tasks

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

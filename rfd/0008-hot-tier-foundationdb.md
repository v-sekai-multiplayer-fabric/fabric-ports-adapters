# RFD 0008 — Hot tier: FoundationDB as unified orchestration and actor state

## Status

Largely already true. Remaining work is configuration, sizing, and measurement.
Was issue #6, split out of issue #4.

## Goal

Use FoundationDB as the single hot tier for both Rivet's orchestration metadata
and live actor SQLite pages, so compute nodes stay stateless and any node can
wake any actor without attaching disks or syncing files.

## Current state

Closer to done than the original framing implied.

**Actor pages already live in FDB-shaped keys.** Depot stores everything under
the crate-owned `[0x02]` prefix, partitioned by purpose. From
`docs-internal/engine/sqlite/storage-structure.md`, whose header reads "Update
it whenever FDB layout changes":

| Partition | Prefix | Purpose |
|---|---|---|
| `BR` | `[0x02][0x30]` | per-database hot data, metadata, staged output |
| `BRANCHES` | `[0x02][0x20]` | branch records, counters, lifecycle state |
| `CTR` | `[0x02][0x40]` | global quota counters |
| `DBPTR` | `[0x02][0x10]` | database pointer rows by bucket branch and name |
| `RESTORE_POINT` | `[0x02][0x50]` | restore point records and state |

**Orchestration metadata already shares the same store.** Pegboard, gasoline
workflows, and epoxy all go through UniversalDB, so one backend already unifies
both concerns.

**The missing piece was the backend, and it now exists.** Upstream Rivet's
`Database` enum has only `Postgres` and `FileSystem`, and
`universaldb/src/driver/` had only `postgres/` and `rocksdb/`. A FoundationDB
driver was added on the fork behind a default-off `foundationdb` cargo feature
and verified against FDB 7.3.76. See [RFD 0004](0004-image-provenance.md) for
the pin and the version coupling.

So this is now a configuration choice rather than a missing capability.

## Remaining work

- [ ] Decide whether the `foundationdb` feature is on by default for fabric
      builds, given it hard-requires `libfdb_c.so` at build and run time.
- [ ] Benchmark under load. There is correctness coverage but no performance
      data. FDB's **five-second transaction limit** interacts with Rivet's
      `TXN_TIMEOUT` in ways currently unmeasured, and a cold read on an
      undersized cluster was observed at `duration_ms=2200`.
- [ ] Audit value sizes against FDB's 100 KB value and 10 MB transaction limits
      under realistic page churn. `@rivetkit/traces` already has a 128 KiB
      actor-KV ceiling; depot's SHARD and DELTA blobs need the same treatment.
- [ ] Size the cluster. `double` redundancy needs three or more processes, and
      the validated deployment ran 2 GB per process against FDB's 4 GB
      recommendation, which `status` reports as a warning.
- [ ] Decide redundancy mode and whether nodes span failure domains.

## Out of scope

Offload of idle state to object storage. That is
[RFD 0009](0009-cold-tier.md), and unlike this, it is genuinely
unimplemented.

# RFD 0019 — Large-value conformance on FoundationDB

## Status

Proposed. Nothing run. Written because
[RFD 0018](0018-authority-and-the-trusted-substrate.md) raised the question and
reading the code narrowed it rather than closing it.

## Problem

Rivet documents a 128 KiB ceiling on an actor KV value. FoundationDB's hard
limit on a single value is 100,000 bytes, which is smaller. A 120 KiB value is
therefore above FoundationDB's limit and below Rivet's, which is the interesting
band.

## What the code already does

Chunking exists and is sized for FoundationDB on purpose.
`engine/packages/pegboard/src/actor_kv/mod.rs`:

```rust
pub const MAX_KEY_SIZE: usize = 2 * 1024;
pub const MAX_VALUE_SIZE: usize = 128 * 1024;
pub const MAX_KEYS: usize = 128;
pub const MAX_PUT_PAYLOAD_SIZE: usize = 976 * 1024;

const VALUE_CHUNK_SIZE: usize = 10_000; // 10 KB, not KiB, see https://apple.github.io/foundationdb/blob.html
```

`universaldb/src/utils/mod.rs` carries the same constant and the same citation.

So a 120 KiB value is stored as roughly thirteen 10 KB chunks, each well inside
FoundationDB's per-value limit, and the whole value is far inside the 10 MB
transaction limit. **The naive failure does not happen**, and the original
concern in RFD 0018 was misplaced.

## Why this still needs testing

The chunking is not new. What is new is the driver underneath it. The
FoundationDB driver ([RFD 0014](0014-foundationdb-driver.md)) has six
correctness tests covering set/get, ranges, atomic add, clears, and conflict
ranges. None of them writes anything near these sizes, and none exercises the
chunked read path.

Three things remain genuinely unverified against FoundationDB.

**Transaction size at the documented maximum.** `MAX_PUT_PAYLOAD_SIZE` is
976 KiB, or 999,424 bytes, and `MAX_KEYS` is 128. A put at that ceiling becomes
roughly 100 chunk writes in one transaction. That is inside FoundationDB's 10 MB
transaction limit with room to spare, but it has never been executed against the
driver, and the driver's commit path is the newest code in the stack.

**The five-second transaction limit.** FoundationDB aborts transactions older
than five seconds. A maximum-size put fanning out to ~100 chunk writes, on a
cluster sized as ours was, is the most plausible way to hit it. A cold read on
an undersized cluster was already observed at `duration_ms=2200`, which is
uncomfortably close.

**Retry classification differs by backend.** Recorded in RFD 0014 and worth
repeating because it bites exactly here: `DatabaseError::TransactionTooOld` is
marked "TODO: Implement in rocksdb and postgres drivers", and
`error_is_transaction_too_large` returns a hardcoded `false` outside
FoundationDB. So a size or age failure that the PostgreSQL and filesystem
backends would swallow or misreport is classified correctly only on
FoundationDB. Behaviour at the limits is the least portable part of the stack,
which is the opposite of the intuition.

## What to test

Against a real FoundationDB cluster, not the fake and not a single-node
degenerate case:

- [ ] Round-trip a 120 KiB value. Assert bytes out equal bytes in, since a
      chunk-reassembly bug is silent rather than loud.
- [ ] Round-trip at exactly `MAX_VALUE_SIZE` (131,072 bytes), and assert that
      one byte more is rejected by validation rather than by FoundationDB.
- [ ] A put at `MAX_PUT_PAYLOAD_SIZE` across `MAX_KEYS` keys, measuring commit
      latency against the five-second limit.
- [ ] The same three on PostgreSQL and on the filesystem backend, since the
      requirement is that the design works on all three and the error paths are
      known to differ.
- [ ] A read of a chunked value spanning a transaction retry, to confirm chunks
      cannot be reassembled from two different versions.

The last one is the only case where a bug would be silent **and** produce wrong
data rather than an error, so it is the one worth writing first.

## Why in production rather than only in a test

A local single-node cluster does not reproduce the conditions that make this
fail. Chunk writes fan out across storage servers; the five-second limit is
reached through real latency; and the observed 2.2s cold read came from an
undersized cluster under real conditions, not from a laptop.

The cheap version is to run the conformance set against a production-shaped
cluster before there is production data in it. That gets the conditions without
the risk, and it is the same window in which
[RFD 0013](0013-foundationdb-backup.md) wants a restore verified.

## Consequences

If it passes, the 128 KiB ceiling is real on all three backends and
`@rivetkit/traces` can stop hedging at 96 KiB chunks.

If it fails, the failure is most likely a timeout at the payload ceiling rather
than a size rejection, and the fix is a smaller `MAX_PUT_PAYLOAD_SIZE` on
FoundationDB rather than a change to chunking.

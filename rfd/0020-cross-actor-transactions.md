# RFD 0020 — Cross-actor linearizable transactions

## Status

**Rejected.** Not on feasibility grounds: the design below works, and the first
revision of this RFD was wrong to claim otherwise. Rejected because it is
engine-side transaction ownership, which upstream names as a thing not to add
and which `pegboard-envoy`, `envoy-client`, and the SQLite paths are documented
as relying on the absence of.

Co-location ([RFD 0012](0012-actor-indexing-and-search.md)) remains the design.
The actor boundary is the transaction boundary.

Kept in full because the analysis is sound and the question will be asked again.
A future reader should be able to see that this was considered and declined,
and on what basis, rather than rediscovering it.

## Problem

Workflows look transactional and are not. From `workflows.mdx`:

> When a step throws, any `state` or `vars` mutations it made before failing are
> never rolled back, whether the step retries or the failure is caught by
> `tryStep` or `try`.

A developer reading that API reasonably expects atomicity across steps. The gap
is silent, and silence is what makes it dangerous.

The requirement is a genuine linearizable transaction across actors, degrading
correctly on all three backends.

## The error in the first analysis

The first version of this RFD argued the feature was impossible because
FoundationDB aborts transactions older than five seconds while Rivet's
hibernation wake budget is ninety seconds, so a transaction touching a sleeping
actor could not complete.

That conflates two different spans:

| Span | Budget | Contains |
|---|---|---|
| **Acquisition** | up to 90s | waking or pausing participants |
| **Commit** | under 5s | reads and writes over their subspaces |

Nothing requires acquisition to happen *inside* the store transaction. Acquire
first, then open a transaction that only touches storage. The slow part is
outside, and the transaction itself is a handful of range operations.

The second objection was that a store-level write is invisible to a running
actor, because `state` is cached in memory. That is true, and it is precisely
why acquisition exists: a participant is either asleep, in which case there is
no cache to invalidate, or paused, in which case it is not reading.

## Design

### The primitive

```
transact(actor_keys, fn) -> Result<T>
```

1. **Order** `actor_keys` deterministically, by actor id. Uniform ordering is
   what prevents deadlock between two overlapping transactions.
2. **Acquire** each participant: Pegboard either confirms it is asleep, or
   pauses it at a dispatch boundary. This may take up to the hibernation
   budget and is not inside any store transaction.
3. **Commit**: one UniversalDB transaction reading and writing the participants'
   subspaces. Serializable by the driver, and short.
4. **Release**, invalidating any in-memory state so a resumed actor reloads
   rather than flushing a stale copy over the commit.

Acquisition is a lease with a timeout, so a crashed coordinator cannot wedge a
participant indefinitely. That is the same shape as the existing lost-timeout
and ping protocol, and should reuse it rather than introduce a second liveness
mechanism.

### Why this degrades correctly

The commit step is the only part that touches the store, and UniversalDB already
presents one serializable contract across all three drivers:

| Backend | Serializability via | Notes |
|---|---|---|
| FoundationDB | native | strict serializability |
| PostgreSQL | `bytearange` + GiST exclusion + GC task | conflict ranges emulated |
| Filesystem (RocksDB) | per-transaction conflict tracker | single node |

So the feature does not need per-backend logic. It needs the transaction to go
through UniversalDB, which is what the abstraction exists for.

Filesystem is the degenerate case: one node, so acquisition is local and the
transaction is a local conflict-tracked commit. It is the weakest deployment and
the easiest correctness case.

Two edges are not uniform and this feature will surface them, per
[RFD 0014](0014-foundationdb-driver.md):
`DatabaseError::TransactionTooOld` is unimplemented on rocksdb and postgres, and
`error_is_transaction_too_large` returns a hardcoded `false` outside
FoundationDB. A cross-actor transaction is larger and longer than anything the
drivers currently see, so it is the most likely code path to hit exactly those
gaps. **Implementing retry classification on all three drivers is a
prerequisite, not a follow-up.**

### What it costs

**It contradicts a documented invariant.** From `CLAUDE.md`:

> `pegboard-envoy`, `envoy-client`, and remote/wasm SQLite may rely on this
> invariant and must not add envoy-protocol lease keys, engine-side transaction
> ownership, or separate same-actor concurrency fences.

This feature is engine-side transaction ownership. The invariant is upstream
Rivet's, and the fork is free to diverge, but everything documented as relying
on it has to be checked rather than assumed unaffected. That is the real cost
and it is not small.

**Availability.** A paused participant is unavailable for the duration. A
transaction over many actors, or over one that is slow to wake, is a
latency spike on every one of them.

**Deadlock is prevented, not detected.** Deterministic ordering is what makes it
safe. Any code path that acquires out of order reintroduces the hazard, so
ordering belongs inside the primitive and must not be an argument.

## Scope

This is an engine change in `pegboard`, not a library change. Realistic
sequencing:

- [ ] Implement `TransactionTooOld` and `error_is_transaction_too_large` for the
      rocksdb and postgres drivers. Prerequisite, and independently useful.
- [ ] Acquisition and lease, reusing the lost-timeout and ping protocol.
- [ ] The `transact` primitive over UniversalDB.
- [ ] Invalidation on release.
- [ ] Conformance across all three backends, including the interleaving cases
      that distinguish serializable from merely atomic.

## What was chosen instead

Co-location, which is correct and cheaper for anything that can use it
([RFD 0012](0012-actor-indexing-and-search.md)). A relation-keyed actor is
linearizable today with no engine change, no acquisition latency, and no
availability cost. This feature is for the cases that genuinely cannot be
co-located.

Making workflows *honest* is worth doing regardless: naming compensation in the
API and failing loudly when a workflow mutates actors it does not own without
declaring one. That closes the silent-misreading gap even where a transaction is
not wanted.

## What would reopen this

A relation that must be atomic **and** genuinely cannot be co-located. None has
been identified. If one appears, the design above is the starting point and the
first question to answer is which components documented as relying on the
single-writer invariant actually break, as opposed to merely being documented
against it.

## Still worth doing regardless

Two items from this analysis do not depend on the rejected feature.

- [ ] Implement `TransactionTooOld` and `error_is_transaction_too_large` for the
      rocksdb and postgres drivers. Currently a `TODO` and a hardcoded `false`.
      Retry classification silently differs by backend today, which is a live
      defect independent of anything here.
- [ ] Make workflows honest: name compensation in the API and fail loudly when a
      workflow mutates actors it does not own without declaring one. The silent
      misreading is the harm; the missing transaction is not.

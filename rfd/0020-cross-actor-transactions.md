# RFD 0020 — Cross-actor linearizable transactions

## Status

Design, third revision. Two earlier approaches were rejected and are kept below,
because the reasons they failed are what make the current one work.

| Revision | Approach | Outcome |
|---|---|---|
| 1 | none; declared impossible | wrong, conflated acquisition with commit |
| 2 | acquire participants, one store transaction over their subspaces | works, but is engine-side transaction ownership |
| 3 | **intents plus a transaction record**, per CockroachDB parallel commits | preserves the actor abstraction |

Revision 3 is the design. Co-location
([RFD 0012](0012-actor-indexing-and-search.md)) remains correct and cheaper for
anything that can use it; this is for what cannot.

## Why revision 2 needed engine-side ownership, and revision 3 does not

Revision 2 made atomicity **physical**: one store transaction spanning two
actors' subspaces. Something has to own a transaction that crosses ownership
boundaries, and that something is the engine. Hence the conflict with the
single-writer invariant.

Parallel commits makes atomicity **logical**. Nothing spans a boundary:

| Piece | Lives in | Written by |
|---|---|---|
| Intent, a provisional value | the participant actor's own subspace | that actor |
| Transaction record, holding status | one actor keyed by transaction id | that actor |
| Commit | a single write to the record | that actor |
| Resolution | reader consults the record | the reader |

Every write stays inside the actor that owns the storage. The single-writer
invariant holds **unmodified**. Atomicity comes from the record being one point
of truth that flips with a single write, which one actor already guarantees.

## The protocol, and why it is worth following rather than inventing

CockroachDB's parallel commits, specified in TLA+ at
[V-Sekai/cockroach `docs/tla-plus/ParallelCommits`](https://github.com/V-Sekai/cockroach/tree/release-22.1-v-sekai/docs/tla-plus).
The spec asserts:

> - the transaction record makes only valid state transitions.
> - if implicitly committed, the commit must eventually become made explicit by
>   moving the transaction record to the "committed" state.
> - if the commit to acknowledged to the client, the commit must eventually
>   become made explicit…

and for liveness:

> - the transaction record is eventually aborted or committed.
> - all of the transaction's intents are eventually resolved.

The property that matters here is what the spec models: a committer that **can
fail at any time**, with concurrent transactions recovering. The coordinator is
not privileged and is not a component. That is exactly what removes the need for
an owner.

"Implicitly committed" is the load-bearing idea: once every intent is written
and the record is `STAGING`, the transaction *is* committed, whether or not
anyone has said so yet. Making it explicit is cleanup, and any observer can do
it. That is what buys a single round rather than two.

## Shape on Rivet

- **Transaction record**: an actor keyed by transaction id. Its whole state is
  the status and the participant list. Single writer, so status transitions are
  serialised for free.
- **Intents**: each participant writes a provisional value into its own storage,
  tagged with the transaction id.
- **Reads**: a reader encountering an intent looks up the record actor and
  resolves. Committed intents become real values; aborted ones are discarded.
- **Recovery**: a reader blocked on an intent whose committer has vanished
  drives the record to a terminal state itself. This is the "preventer" role in
  the spec, and it is why no coordinator process is required.

## The cost is opt-in, and that is the point

An earlier draft of this section said "every read must check for intents",
implying a global tax on the read path. That is wrong, and the correction
changes how attractive the design is.

**Only state that can carry an intent needs checking.** An actor that never
participates in a multi-actor transaction has no intents in its storage, so its
reads are byte-for-byte what they are today. The cost is scoped to the keys that
opt in, not to the system.

This matches how such transactions are actually distributed. They are rare and
high-value; the frequent operations are neither:

| | Frequency | Value per operation | Transactional |
|---|---|---|---|
| Entity position at tick rate | very high | negligible individually | never |
| Profile edit, upload | moderate | low | no |
| Trade, gift, ownership transfer | rare | high; a half-applied state is exploitable | yes |

A trade contract is worth two hops and a recovery obligation. A position update
is not, and never has to pay for the existence of trades.

### Declared where? Nowhere: opt in per read

Three places the opt-in could live, from least to most flexible:

| Granularity | Cost falls on | Problem |
|---|---|---|
| Per actor type | every key in every actor of that type | coarsest; a trade-capable actor taxes its own position updates |
| Per key prefix | keys under that prefix | requires deciding up front which state will ever be transactional |
| **Per read** | only the read that asks | none of the above |

Per-read is the actor-native answer, and it works because of a property of
intents that the other two obscure: **an uncommitted intent is not supposed to
be visible.** A reader that ignores intents and point-reads the key gets the
last committed value, which is exactly what it should see.

So the intent check is not a correctness requirement on every read. It is a
requirement only for readers that need to observe in-flight state, and those are
the same readers that care about linearizability.

Concretely, two read modes on the same key, chosen at the call site:

- **Point read**, unchanged from today. Returns the last resolved value. Cheap,
  and what a tick-rate position read uses.
- **Resolving read**, a range read over the key and its adjacent intent slot in
  one operation. If an intent is present, consult the record actor and resolve.
  What a trade uses.

No declaration, no schema change, no key set fixed in advance. Any key can carry
an intent; only readers who ask will look.

### The honest catch

A point read is not linearizable, and the failure is narrow but real: after a
transaction commits but before its intent is resolved, the key still holds the
old value. A point reader in that window sees stale data.

That window is bounded by resolution, which the committer does immediately and a
preventer does on recovery. It is nonetheless a genuine weakening, so the two
modes must be named for what they are rather than presented as a performance
knob. "Fast read" would be a lie; "last resolved value" is the truth.

This is the same trade CockroachDB makes with follower reads, and the same one
[RFD 0018](0018-authority-and-the-trusted-substrate.md) records between the
control and data planes: the data plane already tolerates staleness by design,
so it is the natural user of the cheap mode.

Rarity also makes the unattractive parts cheap:

- **Recovery** must still be implemented, since liveness depends on preventers
  existing. But stranded intents are rare by construction, so a sweeper can run
  infrequently and a slow one is acceptable.
- **The second hop** happens only when a read races an in-flight transaction on
  the same key, which for rare transactions is rare squared.

**It is a library, not a protocol change.** Intents and records are ordinary
actor state, so this can be built and tested without touching the engine. That
remains the strongest argument for it.

## Degradation across backends

Unchanged from revision 2, and simpler: every operation is a single-actor
transaction, which UniversalDB already provides identically on FoundationDB,
PostgreSQL, and the filesystem. There is no multi-key store transaction anywhere
in the protocol, so nothing depends on backend-specific capability. Filesystem
remains the degenerate case.

The retry-classification gap still matters, but less: single-actor transactions
are small and short, so `TransactionTooOld` and `error_is_transaction_too_large`
are far less likely to be reached than under revision 2.

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

## Revision 2, kept for the record: acquire and commit

Rejected as engine-side transaction ownership. Retained because the analysis of
the acquisition/commit split is what corrected revision 1.

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

## Co-location is still the first choice

Correct and cheaper for anything that can use it
([RFD 0012](0012-actor-indexing-and-search.md)). A relation-keyed actor is
linearizable today with no engine change, no acquisition latency, and no
availability cost. This feature is for the cases that genuinely cannot be
co-located.

Making workflows *honest* is worth doing regardless: naming compensation in the
API and failing loudly when a workflow mutates actors it does not own without
declaring one. That closes the silent-misreading gap even where a transaction is
not wanted.

## Open questions

- [ ] Port or adapt the TLA+ spec to the actor formulation, so the model checked
      is the one implemented rather than a relative of it.
- [ ] What drives recovery when nobody reads a stranded intent? The spec's
      liveness relies on a preventer eventually arriving; an actor system may
      need a sweeper.
- [ ] Does an intent block a read, or can a reader see the prior committed
      value? The latter is cheaper and weaker.
- [ ] Can the intent slot be made adjacent enough that a resolving read is one
      range operation rather than two point reads? This decides whether the
      resolving mode costs a constant factor or a round trip.
- [ ] Which relations actually need this, given co-location handles most cases?
      Expected answer: trades, gifting, and ownership transfer. Not friendships,
      which co-locate cleanly into a relation-keyed actor.

## Still worth doing regardless

Two items from this analysis do not depend on the rejected feature.

- [ ] Implement `TransactionTooOld` and `error_is_transaction_too_large` for the
      rocksdb and postgres drivers. Currently a `TODO` and a hardcoded `false`.
      Retry classification silently differs by backend today, which is a live
      defect independent of anything here.
- [ ] Make workflows honest: name compensation in the API and fail loudly when a
      workflow mutates actors it does not own without declaring one. The silent
      misreading is the harm; the missing transaction is not.

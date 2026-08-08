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

### Detection is free, so nothing needs declaring

Two earlier drafts of this section worried about where to declare transactional
state, and then designed a per-read opt-in to avoid taxing hot reads. Reading
the code retires both: **an actor KV get is already a range read that dispatches
on subkey type.**

The key layout already puts several subkeys under one user key:

```
EntryBaseKey       = (KeyWrapper)
EntryValueChunkKey = (KeyWrapper, DATA, chunk)
EntryMetadataKey   = (KeyWrapper, METADATA)
```

and the read path in `actor_kv/mod.rs` walks the range, sorting entries by which
subkey they are:

```rust
if let Ok(chunk_key) = tx.unpack::<keys::actor_kv::EntryValueChunkKey>(&entry.key()) {
    current_entry.append_chunk(chunk_key.chunk, entry.value());
} else if let Ok(metadata_key) = tx.unpack::<keys::actor_kv::EntryMetadataKey>(&entry.key()) {
    current_entry.append_metadata(metadata_key.deserialize(entry.value())?);
} else {
    bail!("unexpected sub key");
}
```

An intent is a third discriminator, `(KeyWrapper, INTENT)`. The range read
already covers it, so it arrives in the same operation that fetched the value.

| Step | Cost |
|---|---|
| Notice an intent | one more branch, on bytes already read |
| Resolve it | one hop to the record actor, **only if an intent is present** |

So there is no cheap-versus-correct choice to make. Every read is linearizable,
the conditional cost is conditional on an in-flight transaction existing on that
exact key, and nothing pays for the existence of trades. The "last resolved
value" weakening an earlier draft was ready to accept is unnecessary and should
not be built.

### The compatibility cost this does carry

The dispatch ends in:

```rust
} else {
    bail!("unexpected sub key");
}
```

An engine that does not know about `INTENT` **hard-errors** when it reads
storage written by one that does. Adding a subkey is therefore a
forward-compatibility break rather than an additive change, and needs the usual
versioned rollout rather than a flag flip.

Adjacent and worth fixing in the same change: `EntryMetadataKey` carries
`// TODO: this is mistakenly not versioned. Transition to vbare so future`
changes are safe. The versioning gap is already there, in the same key family
this work extends.

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
- [x] **Answered by the code: one range operation, and it is the one already
      performed.** Intents ride along in the existing get. See above.
- [ ] Does the `bail!` on unknown subkeys need to become tolerant before an
      intent subkey can be rolled out, and does `EntryMetadataKey` get moved to
      vbare in the same change?
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

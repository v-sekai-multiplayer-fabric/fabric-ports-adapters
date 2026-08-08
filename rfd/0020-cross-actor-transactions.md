# RFD 0020 — Cross-actor linearizable transactions

## Status

Analysis. **Not recommended as specified**, for one reason that is not a matter
of effort. A narrower version is viable and is described at the end.

## Problem

Workflows look transactional and are not. From `workflows.mdx`:

> When a step throws, any `state` or `vars` mutations it made before failing are
> never rolled back, whether the step retries or the failure is caught by
> `tryStep` or `try`.

FoundationDB underneath provides serializable transactions over the whole
keyspace, so the question is fair: why not expose that as a cross-actor
transaction and make workflows linearizable?

## The storage layer is not the obstacle

Actor storage is subspace-scoped by convention, not partitioned by enforcement:

```rust
pub fn subspace(actor_id: Id) -> universaldb::utils::Subspace {
    universaldb::utils::Subspace::new(&(RIVET, PEGBOARD, ACTOR_KV, actor_id))
}
```

A UniversalDB transaction spanning two actors' subspaces is expressible today,
and FoundationDB would serialize it correctly. Nothing in the store prevents
this.

## The obstacle is that actors are processes, not rows

Two facts, each documented, that together close the door.

**Actor state is cached in memory.** From `state.mdx`:

> `state` lives in memory and is persisted automatically, so reads and writes
> have no added latency

So a transaction that writes an actor's subspace directly produces a
linearizable *store* and an incoherent *actor*: the live process continues from
its in-memory copy and overwrites the change on its next flush. The transaction
would be correct and invisible.

**Waking cannot fit inside a transaction.** FoundationDB aborts transactions
older than five seconds. Rivet documents a hibernation wake timeout of **90
seconds**. A cross-actor transaction touching a sleeping actor therefore cannot
complete: the wake alone may exceed the transaction lifetime by an order of
magnitude, and whether a participant is asleep is not knowable before starting.

That mismatch is structural. It is not solved by a faster cluster, because the
90 second budget exists for cold starts that are legitimately slow.

## It also contradicts a stated invariant

From `CLAUDE.md`:

> Pegboard orchestrates actor exclusivity: at most one actor instance for a
> given actor id may be running or accessing that actor's storage at a time.
> This is the actor single-writer invariant… `pegboard-envoy`, `envoy-client`,
> and remote/wasm SQLite may rely on this invariant and **must not add
> envoy-protocol lease keys, engine-side transaction ownership, or separate
> same-actor concurrency fences**.

A cross-actor transaction is engine-side transaction ownership by definition. It
is named as a thing not to add, and other components are documented as relying
on its absence. Adding it is not a local change to the workflow API; it is a
change to an invariant that depot, envoy, and the SQLite paths are built on.

## What a full implementation would require

For completeness, since "can you" deserves an answer rather than a refusal:

1. A participant protocol so live actors join a transaction rather than being
   written behind. Effectively two-phase commit with actors as participants.
2. A way to bound participation inside five seconds, which means refusing any
   transaction whose participants are not already awake, and accepting that the
   same transaction succeeds or fails depending on sleep state.
3. Invalidation so a committed transaction reaches in-memory state, which means
   a generation or version check on every actor read.
4. Revisiting the single-writer invariant and everything documented as relying
   on it.

That is an engine-level project with a correctness surface larger than the
feature, and step 2 leaves a transaction whose success depends on whether a
participant happened to be asleep. That is not linearizable in any useful sense;
it is a transaction that sometimes refuses.

## The narrower version that does work

Two things are achievable and worth doing instead.

**Co-location, which is already the recommendation.** The actor boundary is the
transaction boundary ([RFD 0012](0012-actor-indexing-and-search.md)). Anything
requiring atomicity is owned by one actor, keyed by the relation rather than a
participant. This is linearizable today with no engine change.

**Make workflows honest rather than transactional.** The real defect is not the
missing guarantee, it is that the API reads as though it has one. Concretely:

- Name compensation explicitly in the API, so a step declares its undo rather
  than a comment noting that rollback does not happen.
- Fail loudly when a workflow mutates actors it does not own without declaring
  compensation, since that is the case that silently looks atomic.
- Document sagas as sagas at the call site, not only in a limits page.

That closes the gap that actually causes harm. A developer misreading a workflow
as transactional is a bug that ships; a developer who cannot get a cross-actor
transaction goes and co-locates instead.

## Recommendation

Do not add cross-actor transactions. The five-second transaction limit against
a ninety-second wake budget is not an implementation difficulty, it is an
incompatibility, and the workaround for it produces a transaction that fails
based on scheduling.

Do close the honesty gap in the workflow API, and keep co-location as the
mechanism for anything that must be atomic.

## Open questions

- [ ] Is the workflow API change worth proposing upstream, given the fork
      already carries engine changes?
- [ ] Are there relations that must be atomic **and** cannot be co-located? That
      would be the case that forces this question open again, and none has been
      identified so far.

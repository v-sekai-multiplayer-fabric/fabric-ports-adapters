# RFD 0012 — Indexing and search without a shared database

## Status

Proposed. Split out of [RFD 0005](0005-zone-backend-as-rivet-service.md), which
had bundled it with Uro's decomposition. It is separable: any service built on
single-writer actors hits these four problems, not just Uro.

## Problem

A Rivet actor is addressed by key and owns its own SQLite. There is no query
across actors. A shared relational database was providing four things that this
does not, and they have to be rebuilt individually:

1. lookup by a non-key attribute
2. uniqueness constraints
3. listing and search across entities
4. invariants spanning more than one entity

The constraint driving this is that FoundationDB should remain the **only**
stateful dependency, so "add a search index" and "add Postgres" fail the same
test.

## 1. Lookup by a non-key attribute

Authentication needs `email → user id`. The actor key is the id.

**Index actors.** A singleton actor per index, owning a SQLite table mapping
attribute to id: `email-index`, `identity-index`, `zone-name-index`.

Viable because these are low-volume and read-often. It is a bottleneck by
construction. An index actor on the path of every request is a single-writer
database with extra steps, so this must not be reached for casually.

## 2. Uniqueness

Nothing in the actor model enforces a unique attribute; two concurrent
registrations both succeed.

**The index actor owns the namespace.** Registration calls the index, which
allocates or rejects, and only then is the entity actor created. Single-writer
semantics are exactly the serialisation needed.

This makes registration two-step and therefore failable between steps. It needs
to be idempotent, and it needs a sweeper for allocations whose entity was never
created.

## 3. Listing and search

Three cases with genuinely different answers.

**Owner-scoped lists are not a problem.** "A user's avatars" is a query inside
one actor, provided that actor holds the list.

**Bounded global lists are a projection actor.** "Public zones" is a
materialised view maintained by an actor that entities notify on change. Bounded
because the entity count is bounded. Stale by construction, which suits a
browser listing and not anything transactional.

**Tag search shards by term.** This is the interesting case.

### Tag search: one actor per tag

Key the actor by the tag. `tag:forest` holds the posting list of ids carrying
that tag in its own SQLite.

- **Single-tag search wakes exactly one actor** and reads one table. Cheaper
  than the equivalent scan of a shared table, not more expensive.
- **Multi-tag AND** fans out to one actor per tag and intersects in the caller,
  bounded by the smallest list. This is the optimisation a search engine already
  makes.
- **Writes do not contend.** Tagging writes to one tag's actor; unrelated tags
  are untouched. There is no global index lock.
- **Idle tags are free**, because their actors sleep. A long tail of rare tags
  costs nothing, which is strictly better than a shared index where every term
  occupies the same structure.

An inverted index is one of the more natural things to shard across actors,
because the shard key falls out of the query.

### Relevance ranking is already distributed

**Decided: relevance ranking is required, and distributed across actors with no
central statistics holder.** That is achievable, because the quantity ranking
needs is per-term and the index is already sharded by term.

Document frequency for a term is the length of that term's posting list. A tag
actor therefore *is* the authority on its own `df`, and nothing has to aggregate
anything:

```
tag:forest   → posting list, df = |posting list|
tag:ruins    → posting list, df = |posting list|
caller       → intersect, score each doc by summing per-term weights
```

Each tag actor returns its posting list and its own `df`. The caller intersects
and scores. That is the whole mechanism.

#### Why the corpus size N is not needed

The usual objection is that IDF needs the total document count, which is global.
For the common case it cancels:

```
idf(t) = log(N / df(t)) = log N − log df(t)
```

A document matching *k* query terms scores `k·log N − Σ log df(t)`. For an **AND**
query every returned document matches all *k* terms, so `k·log N` is a constant
added to every score and does not change the ordering. Ranking by `−Σ log df(t)`
gives exactly the IDF ordering, using only per-actor values.

`N` re-enters only when *k* varies between documents, which means OR queries and
partial matches. Even then it sits inside a logarithm, so an approximate count
is sufficient and it never needs to be exact or current.

So the shared state the term-sharded design was built to avoid is not required
after all, and the exception is bounded and weak.

#### What this does cost

- The caller does the scoring, so it holds all matched posting lists at once.
  That is the same memory the intersection already needs.
- `df` is only meaningful relative to the same corpus. A tag actor that has been
  resharded reports the `df` of its shard, not of the term, so second-level
  sharding must sum `df` across shards or ranking silently skews toward
  heavily-sharded tags. Worth designing in when the threshold is set rather
  than discovering later.

### Where it breaks

- **Hot tags.** A tag on very many entities puts a large posting list behind one
  single-writer actor. Needs second-level sharding, `tag:forest:0..n`, with a
  threshold and a resharding procedure. Both are real work and should be chosen
  before they are needed.
- **Ranking.** Addressed below. An earlier draft said relevance needs a
  projection actor holding corpus-wide statistics. That was wrong.
- **Free text, not tags.** All of the above works because tags are discrete
  terms matched exactly. Prefix, fuzzy, and natural-language search are
  different problems, and SQLite FTS5 inside one actor does not generalise to a
  growing corpus.
- **Vector similarity is out of scope.** Nearest-neighbour search does not shard
  by term and none of this applies. Confirmed not required: "semantic tags"
  means discrete exact tags, so the term-sharded design stands.

## 4. Invariants across entities

There is no cross-actor transaction.

**Make the relation one-sided and derive the rest.** For a friendship, each user
actor stores its own outgoing edges; the relation is mutual when both hold an
edge. That is a read of two actors instead of a write to one shared table.

The window where one side has recorded and the other has not is inherent, and is
already true of most social graphs. It is only unacceptable where the relation
gates something safety-critical, which should be identified explicitly rather
than assumed absent.

## Authorisation is not a cross-entity query

An earlier draft treated access control as a hard case of the above. For the
common case it is not, and the reason is worth stating because it changes the
cost of everything built on it.

Two different things get called "the graph":

| | Nature | Where it lives |
|---|---|---|
| **Rules** — role hierarchies, `IS_MEMBER_OF`, `CONTROLS`, `DELEGATED_TO` | immutable, ships with the app | resident in every actor |
| **Relations** — friendships, ownership, membership | mutable, per-entity | the actor the relation describes |

Immutable shared *config* is not shared *state*, so keeping the rule set resident
everywhere raises no ownership question. Only the relations need an owner, and
the owner is obvious: the actor the relation is about.

The authorisation question in an actor system is therefore never "walk a global
graph". It is:

> May this subject do X to **me**?

One resource, answered by the actor that owns it, from edges it already holds
plus rules it already has in memory. A local read and a bounded scan, with no
fan-out. Genuinely transitive cases still walk, and Uro's adapter already bounds
that at `@fuel 8`.

The alternatives are worth naming as rejected, because both look reasonable:

- **Fetch edges per check and assemble a graph.** Storage stays actor-shaped but
  evaluation reconstitutes a global view, so every check pays a fan-out.
- **Hold one resident graph of everything.** Fastest per check and not
  actor-based at all: a single mutable structure describing every entity is the
  shared state actors exist to remove, and a linear-scanned list does not survive
  millions of user edges.

## Open questions

- [ ] **Hot-tag threshold: derive it from measurement, not from the limits.**
      A number could be computed from the documented ceilings (128 KiB per KV
      value, 976 KiB per put payload) but that gives the point where a posting
      list stops *fitting*, which is not the point where a single-writer actor
      stops *keeping up*. The latter is what matters and only measurement finds
      it. Measure: write throughput against posting-list size, read latency for
      a single-tag query as the list grows, and intersection cost for
      multi-tag AND. Shard where the curve bends, not where the value overflows.
- [ ] Resharding procedure, once the threshold is known.
- [ ] Is unranked deterministic ordering acceptable, or is relevance required?
- [ ] Does any relation in the system need genuine two-sided atomicity? If so,
      this RFD does not cover it.

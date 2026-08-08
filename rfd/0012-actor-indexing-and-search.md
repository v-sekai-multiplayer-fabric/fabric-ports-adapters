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

### Where it breaks

- **Hot tags.** A tag on very many entities puts a large posting list behind one
  single-writer actor. Needs second-level sharding, `tag:forest:0..n`, with a
  threshold and a resharding procedure. Both are real work and should be chosen
  before they are needed.
- **Ranking.** Relevance needs corpus-wide document frequency, which no single
  actor holds. Either accept a deterministic unranked order, or keep approximate
  global statistics in a small projection actor and accept lag.
- **Free text, not tags.** All of the above works because tags are discrete
  terms matched exactly. Prefix, fuzzy, and natural-language search are
  different problems, and SQLite FTS5 inside one actor does not generalise to a
  growing corpus.
- **Vector similarity is out of scope.** Nearest-neighbour search does not shard
  by term and none of this applies. If "semantic tags" means embeddings, that
  needs its own RFD.

## 4. Invariants across entities

There is no cross-actor transaction.

**Make the relation one-sided and derive the rest.** For a friendship, each user
actor stores its own outgoing edges; the relation is mutual when both hold an
edge. That is a read of two actors instead of a write to one shared table.

The window where one side has recorded and the other has not is inherent, and is
already true of most social graphs. It is only unacceptable where the relation
gates something safety-critical, which should be identified explicitly rather
than assumed absent.

## Open questions

- [ ] Hot-tag threshold and resharding procedure.
- [ ] Is unranked deterministic ordering acceptable, or is relevance required?
- [ ] Does any relation in the system need genuine two-sided atomicity? If so,
      this RFD does not cover it.

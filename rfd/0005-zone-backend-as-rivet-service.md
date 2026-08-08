# RFD 0005 — zone-backend (Uro) as a Rivet service

## Status

Proposed. Nothing implemented. Was issue #1.

The general mechanisms for indexing, uniqueness, listing, and cross-entity
relations were split out into
[RFD 0012](0012-actor-indexing-and-search.md), because they apply to any service
built on single-writer actors. This RFD covers Uro specifically.

## Problem

[zone-backend](https://github.com/v-sekai-multiplayer-fabric/zone-backend) is
Uro, the Phoenix/Elixir backend for the Multiplayer Fabric social VR platform.
It runs today as a long-lived container under docker compose behind Caddy, on a
relational database.

Two decisions are already made:

- **Rivet Guard replaces Caddy.** Uro sits behind Guard, not its own reverse
  proxy.
- **Greenfield.** There is no migration. Existing accounts, content, and zones
  do not carry over.
- **No PostgreSQL or CockroachDB.** Specifically: no *second* stateful service
  to operate alongside Rivet. SQL itself is fine. Actor-local SQLite is SQL, and
  it is the intended store.

The constraint is therefore operational rather than technical. FoundationDB is
already there for Rivet's own state
([RFD 0008](0008-hot-tier-foundationdb.md)), and the goal is that it stays the
*only* stateful dependency. Anything that would add a second one — Postgres,
CockroachDB, or an external search index — fails the same test.

That rules out the easy escape hatches, so most of this RFD is about the four
things a shared relational database was doing that a set of single-writer actors
does not provide.

## What replaces the database

Rivet actors have per-actor SQLite, backed by depot and therefore by
FoundationDB ([RFD 0008](0008-hot-tier-foundationdb.md)). Pegboard enforces a
single-writer invariant: at most one instance of a given actor may be running or
touching its storage at a time.

So each actor gets a real relational store that it alone writes. What it does
not get is a query across actors. That is the whole design problem.

## The decomposition

Uro's tables partition cleanly by owner. From `priv/repo/migrations`:

| Actor | Key | Owns |
|---|---|---|
| **User** | user id | `users`, `user_identities`, `user_privilege_ruleset`, `identity_proofs`, `backpack` and its join rows, `loop_profiles` |
| **Zone** | zone id | `zones` (`address`, `port`, `name`, `current_users`, `max_users`, `map`, `cert_hash`, `status`, `public`, `last_put_at`) |
| **Content** | content id | `avatars`, `maps`, `props`, `shared_files` including bake fields and semantic tags |

These are genuinely single-writer. A user's privileges are written by that user's
actor; a zone's occupancy is written by that zone.

**Zones are already actor-shaped and are the obvious first cut.** They
self-register at startup with multiplicity 0..∞, they are ephemeral, they own
their own liveness (`current_users`, `status`, `last_put_at`), and nothing else
writes them. A zone row is an actor's state that currently happens to live in a
shared table. Moving zones alone removes the highest-churn writes from the
database and is independently useful.

`friendships` does not fit the table, and is dealt with below.

## Zones have no registry, because authority is computed

The obvious design gives zones a registry actor: zones register at startup, the
registry holds the list, clients read it. That is what Uro does today with a
`zones` table.

It is the wrong shape, and
[lean-rebac-core](https://github.com/v-sekai-multiplayer-fabric/lean-rebac-core)
already formalises why. `Rebac/core/NoGod.lean` replaces three assumptions:

| Replaced | With |
|---|---|
| God-clock (global tick) | `VClock`, a per-node causal counter |
| Coordinator-assigned range | geometric containment in Hilbert space |
| Deterministic serialization | causal partial order |

Authority is a pure function, not an assignment:

```lean
/-- Authority for an entity at Hilbert code `h`: find the zone whose range
    contains h in the gossip-learned map.  Pure geometry; no message needed. -/
def geometricAuthority {n : Nat} (view : NodeView n) (h : Nat) : Option ZoneRange :=
  view.ranges.find? (fun r => r.contains h)
```

The authoritative zone for an entity is whichever zone's Hilbert range contains
`hilbert3D(entity.pos)`. Nobody grants it. Everyone computes it from the same
public rule, and `authority_unique` proves that under `DisjointRanges` exactly
one zone contains a given code.

### Migration is a consequence, not a protocol

An entity moving across a range boundary changes `hilbert3D(pos)`, so a
different range contains it, so authority has transferred. There is no handoff
message, no lock, and no coordinator round trip: both sides reach the same
conclusion independently because it is the same pure function over the same map.

### Why this is the zero-trust shape

A registry holds assertions about entities it is not, and cannot independently
verify them. Compromise it and every zone can be forged. That is an implicit
trust zone in the sense OMB M-22-09 targets, and it is the "god" the Lean file
is named against.

Geometric authority removes the question rather than answering it. There is no
authority to verify against, because the answer is computable by anyone and
forgeable by no one.

### Superseded by RFD 0018

The analysis below is kept for continuity, but
[RFD 0018](0018-authority-and-the-trusted-substrate.md) revises it: identity
forgery is closed by Pegboard rather than by the proofs, the range map belongs
in actor state as control-plane data, and the corpus establishes
coordination-freedom rather than unforgeability.

### What is not proven

`geometric_authority_unique` takes `DisjointRanges view.ranges` as a hypothesis,
and `view` is per-node and gossip-learned. Uniqueness therefore holds **within a
view**. Two nodes whose gossip has not converged can transiently disagree about
authority.

That is conceded by the design rather than overlooked: `VClock.concurrent`
exists precisely because concurrent operations may be serialized in either
order. Consistency here is causal, not linearizable. "No coordinator" and
"everyone always agrees" are different claims, and only the first is proven.

Anything requiring a single global answer at a single instant does not belong on
this path.

### Consequences for the browser listing

A listing of public zones remains a projection with **no authority**
([RFD 0012](0012-actor-indexing-and-search.md)). If it is stale, the
authoritative answer is still geometric. It must never become an authorisation
decision point: a client that finds a zone in the listing still authenticates to
that zone.

## The four things the database was doing

Uro needs all four of the mechanisms in
[RFD 0012](0012-actor-indexing-and-search.md), and hits them at these points:

| Mechanism | Where Uro needs it |
|---|---|
| Lookup by non-key attribute | `email → user id` for authentication; `provider + provider_uid → user id` for `user_identities` |
| Uniqueness | unique email and username at registration |
| Owner-scoped lists | a user's avatars, props, backpack contents |
| Bounded global list | public zones, for a server browser |
| Tag search | `shared_files` by semantic tag |
| One-sided relations | `friendships` |

**Confirmed: `semantic_tags` means discrete exact tags**, not embeddings, so the
term-sharded index in RFD 0012 applies directly.

## ReBAC is already portable

Uro's access control is already behind a port. `lib/uro/ports/re_bac.ex`
declares a behaviour with an opaque `graph()` term:

```elixir
@callback new_graph() :: graph()
@callback add_edge(graph(), subj, obj, rel) :: graph()
@callback check_rel(graph(), subj, rel, obj) :: boolean()
```

The default adapter, `Uro.ReBAC.ElixirAdapter`, is plain in-memory Elixir. So
authorisation does not depend on the relational store at all, and does not have
to be redesigned to move. Uro also already has `lib/uro/ports/planner.ex`, so
the ports-and-adapters shape is established in that codebase rather than
imposed by this one.

**Decided: rules stay bundled and resident; relations live in the actor they
describe.** Uro's adapter already assumes the first half, describing ReBAC
graphs as "trusted, bundled domain content, not adversarial input", and
implementing the graph as a plain list scanned linearly with recursion bounded
at `@fuel 8`. That is only viable for a small rule set, which is exactly what
bundled rules are.

Friendships and ownership are therefore not edges in that graph. They are held
by the user and content actors that own them, and a check is a local read plus a
bounded scan rather than a fan-out. See
[RFD 0012](0012-actor-indexing-and-search.md).

This makes per-request authorisation cheap, which matters for the posture
question below.

## What this costs

Greenfield removes the hardest part: no dual-write period, no backfill from the
relational store into per-actor SQLite, and no compatibility with existing ids.

What remains is still a rewrite of Uro's persistence layer, not a repackaging.
Every Ecto query becomes either an actor-local query, a call to another actor, or
a projection. The Phoenix layer, the controllers, the OpenAPI surface, and
`re_bac` largely survive; `repo.ex` and every context that reaches through it do
not.

The honest smaller alternative is to **move zones only**. Zones are the best fit
and the highest churn, they already self-register, and nothing else writes them.
Users and content stay where they are for now. This removes the busiest writes
from the database, proves the pattern, and is reversible. It does not on its own
let the database be switched off, which is the actual goal, so it is a first
step rather than a destination.

## Serving shape

`container-runner` hosts a container behind Rivet's tunnel: WebSocket clients
connect at the bare gateway path, and raw HTTP reaches the child under a
`/request/*` prefix, which the runner strips.

That prefix is a path change for every existing client of Uro's `/api/v1/`
surface. With Guard replacing Caddy, Guard is the place to absorb it, but it
should be checked rather than assumed.

## Open questions

- [ ] **Does "semantic tags" mean exact discrete tags, or embeddings?** The
      tag-per-actor design above assumes exact terms. Vector similarity search
      does not shard the same way and would need its own RFD.
- [ ] What is the hot-tag threshold, and what is the resharding procedure?
- [ ] Is unranked, deterministically ordered search acceptable, or is relevance
      ranking required?
- [ ] **Is per-request authorisation the target posture?** Re-running
      `check_rel` per action is nearly free given the above. The expensive half
      is per-request *authentication*: RivetKit establishes identity in
      `onBeforeConnect` and carries it in `createConnState`, so re-authorising
      against a cached subject still leaves an implicit trust zone. Removing it
      means presenting a credential per action, which changes the client
      protocol. Worth deciding the two halves separately.
- [ ] Does the gossip range map live in Rivet actors, or beside them? The Lean
      model assumes a `NodeView` per node; how that is populated on this
      substrate is unspecified.
- [ ] Does `/api/v1/` keep its shape through Guard, or do clients move?

## Prior art in this repo

The Godot zone is the worked example of a container behind `container-runner`,
including the readiness contract and the `/request/*` prefix behaviour. See
[RFD 0004](0004-image-provenance.md) for how its image is assembled.

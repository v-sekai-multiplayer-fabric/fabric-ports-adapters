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

The one that needs confirming before anything is designed: **`semantic_tags`
must mean discrete exact tags**, not embeddings. The term-sharded index in
RFD 0012 assumes exact matching. Vector similarity does not shard that way.

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

The open question is where the graph lives once users are actors: rebuilt per
request from the relevant actors, or held by a authorisation actor.

## What this costs

Being direct: this is a rewrite of Uro's persistence layer, not a repackaging.
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
- [ ] Where does the ReBAC graph live once users are actors?
- [ ] Zone registration currently happens at zone startup against a live Uro. If
      the registry is an actor that sleeps, a registration must wake it; confirm
      that wake-on-message is acceptable on that path.
- [ ] Does `/api/v1/` keep its shape through Guard, or do clients move?
- [ ] Is there a migration, or is this a new deployment? Existing user accounts
      and content have to land somewhere.

## Prior art in this repo

The Godot zone is the worked example of a container behind `container-runner`,
including the readiness contract and the `/request/*` prefix behaviour. See
[RFD 0004](0004-image-provenance.md) for how its image is assembled.

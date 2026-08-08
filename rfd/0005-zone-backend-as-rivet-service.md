# RFD 0005 — zone-backend (Uro) as a Rivet service

## Status

Proposed. Nothing implemented. Was issue #1.

## Problem

[zone-backend](https://github.com/v-sekai-multiplayer-fabric/zone-backend) is
Uro, the Phoenix/Elixir backend for the Multiplayer Fabric social VR platform.
It runs today as a long-lived container under docker compose behind Caddy, on a
relational database.

Two decisions are already made:

- **Rivet Guard replaces Caddy.** Uro sits behind Guard, not its own reverse
  proxy.
- **No PostgreSQL or CockroachDB.** The relational store goes away rather than
  being migrated.

The second is the hard one, and most of this RFD is about it. Dropping the
database is not a storage swap; it removes the four things the database was
doing that an actor model does not provide.

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

### 1. Secondary lookup

Actors are addressed by key. Authentication needs `email → user id`, and
`user_identities` needs `provider + provider_uid → user id`. Neither is the
actor key.

**Mechanism: index actors.** A singleton actor per index, owning a SQLite table
mapping the attribute to the id. `email-index`, `identity-index`,
`zone-name-index`.

This works because these are low-volume, write-rarely, read-often. It is a
bottleneck by construction, so it must not be used for anything high-churn. An
index actor that is on the path of every request is a single-writer database
with extra steps.

### 2. Uniqueness

Unique email, unique username. Postgres does this with a unique index; nothing
in the actor model does it for you, and two concurrent registrations will
both succeed.

**Mechanism: the index actor owns the namespace.** Registration is a call to
`email-index`, which either allocates or rejects, and only then creates the user
actor. The index actor's single-writer property is exactly the serialisation
needed. This makes registration a two-step operation that can fail between
steps, so it needs to be idempotent and to have a sweeper for orphaned
allocations.

### 3. Cross-entity queries

This is the one with no clean answer, and it should drive the decision.

Uro's API lists and searches: public zones, a user's avatars, shared files by
semantic tag. `20260720000000_create_shared_file_semantic_tags` exists precisely
to support search. There is no cross-actor query in Rivet, so every one of these
becomes a design problem rather than a `SELECT`.

Three options, in increasing cost:

- **Owner-scoped lists stay easy.** "A user's avatars" is a query inside one
  actor if the user actor holds the list. Most per-user listing is fine.
- **Bounded global lists need a projection actor.** "Public zones" is a
  materialised view maintained by an actor that zones notify on status change.
  Bounded because the zone count is bounded. Stale by construction, which is
  acceptable for a server browser and not for anything transactional.
- **Semantic search over shared files is not a projection.** Tag search over a
  growing corpus is a search-index problem, and pretending otherwise produces a
  single actor holding the whole catalogue. This wants a real index outside the
  actor system.

**If the answer to the third is "run a search index", then the claim that the
database is gone deserves scrutiny.** A search index is another stateful service
to operate. It may still be the right call, because a search index is a better
fit for tag search than a relational database was, but it should be a stated
choice rather than an accident.

### 4. Multi-entity invariants

`friendships` relates two users. Accepting a friend request writes both sides,
and there is no cross-actor transaction.

**Mechanism: make it one-sided and derive the rest.** Each user actor stores its
own outgoing edges. A friendship is mutual when both sides hold an edge, which
is a read of two actors rather than a write to one shared table. There is a
window where one side has accepted and the other has not recorded it; that is
already true of the real world and of most social graphs.

This is also where [ReBAC helps](#rebac-is-already-portable).

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

The honest smaller alternatives:

- **Move zones only.** Zones are the best fit and the highest churn. Users and
  content stay relational for now. This gets most of the operational benefit for
  a fraction of the work, and is reversible.
- **Keep a relational store that is not Postgres.** The stated constraint is no
  Postgres or CockroachDB, not no SQL. SQLite under an actor is still SQL.
  Whether a single non-Postgres relational store is acceptable changes the
  answer substantially, and is worth confirming before committing to full
  decomposition.

## Serving shape

`container-runner` hosts a container behind Rivet's tunnel: WebSocket clients
connect at the bare gateway path, and raw HTTP reaches the child under a
`/request/*` prefix, which the runner strips.

That prefix is a path change for every existing client of Uro's `/api/v1/`
surface. With Guard replacing Caddy, Guard is the place to absorb it, but it
should be checked rather than assumed.

## Open questions

- [ ] Is "no Postgres or CockroachDB" a constraint against those products, or
      against a shared relational store in general? The answer changes the scope
      by an order of magnitude.
- [ ] Does semantic tag search move to a search index, and if so, which, and who
      operates it?
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

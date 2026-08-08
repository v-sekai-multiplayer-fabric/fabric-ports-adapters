# RFD 0018 — Authority, and what the substrate already guarantees

## Status

Analysis, not a build decision. Records what is proven, what the substrate
supplies, and which of the two is doing the work. Supersedes the authorisation
reasoning in [RFD 0005](0005-zone-backend-as-rivet-service.md).

## Problem

`lean-rebac-core` proves properties about zone authority under the banner
"NO EGO, NO GOD, NO DETERMINISM". Rivet, meanwhile, documents an explicitly
trusted internal boundary. Both cannot be the whole story, and it matters which
guarantee any given design is actually leaning on.

## Rivet is a notary, by documented design

From the engine's trust boundaries:

> Treat `gateway`, `api`, `pegboard-envoy`, `nats`, `fdb`, and similar
> engine-internal services as one trusted internal boundary once traffic is
> inside the engine.

and the exclusivity invariant:

> Pegboard orchestrates actor exclusivity: at most one actor instance for a
> given actor id may be running or accessing that actor's storage at a time.
> The lost-timeout + ping protocol is responsible for making overlapping actor
> generations impossible.

So three guarantees arrive for free:

| Guarantee | From |
|---|---|
| Identity: a key resolves to exactly one live actor | Pegboard |
| Exclusivity: one writer per actor, no overlapping generations | Pegboard + lost-timeout/ping |
| Ordering: serializable transactions over actor state | UniversalDB |

## What "NoGod" actually removes

It removes the coordinator from **time** (`VClock` replaces a global tick) and
from **placement** (`geometricAuthority` computes authority from position rather
than being assigned it). Those are real results and the proofs are sound.

It does **not** establish that authority is unforgeable, and that distinction is
easy to lose in the naming. A survey of all twenty Lean repositories in the
organisation found no occurrence of `signature`, `forge`, `attest`, `authentic`,
`tamper`, `integrity`, or `nonce`. The corpus models *coordination* under
honest-but-unsynchronised nodes, not *adversarial* behaviour.

Two specific gaps:

- `NoGod.receive` adopts `msg.ranges` wholesale on causal dominance, and the
  only constraint proven is disjointness. A map with one range covering all of
  Hilbert space is trivially disjoint, so `receive_preserves_disjoint` would
  accept a node claiming universal authority. **Disjointness is not integrity.**
- `lean-interest-mgmt`'s `promoteToAuthority` is gated on capacity alone
  (`z.entities.size < cap - headroom`). Nothing checks that the entity falls in
  the zone's range.

Also worth recording: the two theorems in `ReBAC.lean` that would bind authority
to mutation, `rebac_requires_authority_for_mutation` and
`non_authority_cannot_bind_mutation`, are stated as `True := trivial` with every
hypothesis unused. Their docstrings describe the intended property; the formal
content is vacuous. That file is imported by `Research.lean`, which declares
itself "NOT on the CI production gate… aspirational".

## Where the guarantee comes from, in practice

Identity forgery is closed **by the substrate, not by the proofs**. A zone actor
cannot write another zone's state because `getOrCreate([zoneId])` routes to the
one live instance and Pegboard enforces exclusivity. There is no path to
impersonate, so nothing needs to detect it.

What remains open is narrower and real: Rivet guarantees *this write came from
the actor that owns this key*, not *what that actor said is true*. A compromised
zone with a genuine identity can still propose a hostile range map.

So "NoGod" is a property of the zone layer **relative to a trusted substrate**.
FoundationDB is a global ordering oracle; Pegboard is a coordinator that assigns
hosting. The god was removed one layer up, not abolished.

## Control plane and data plane

The confusion above dissolves once the two planes are separated.

| | Control plane | Data plane |
|---|---|---|
| Carries | range map, zone status, membership | entity state at tick rate |
| Path | through the engine, into actor state | peer-to-peer, bypasses the engine |
| Ordering | serializable, from UniversalDB | causal only, `HLC` / `VClock` |
| Wire | actor actions | the 100-byte packet in `lean-entity-packet` |

`NoGod.lean` says outright that `VClock` exists to generalise the HLC already
carried in that packet: "the physical component of an HLC maps to the local
component of `VClock.selfId`". The causality machinery is aimed at the data
plane, where nothing else can order events because the traffic never reaches the
store.

**The range map is control plane.** It changes rarely and must be consistent, so
it belongs in actor state where the substrate orders it. Gossiping it with
vector clocks reimplements, more weakly, a guarantee already available.

## This is portable across all three backends

The requirement is that the design work on filesystem, PostgreSQL, and
FoundationDB. Putting the range map in actor state satisfies that, because
UniversalDB is the portability layer and all three drivers implement the same
serializable contract:

| Backend | Conflict serializability via |
|---|---|
| FoundationDB | native |
| PostgreSQL | `bytearange` plus a GiST exclusion constraint and a GC task |
| Filesystem (RocksDB) | a per-transaction conflict tracker |

What differs is scale, not semantics: filesystem is single node, PostgreSQL is
documented as production-ready to roughly 1,000 concurrent actors, FoundationDB
scales.

**Filesystem is the degenerate case.** At one node the distributed problem
vanishes: `VClock` collapses to a single counter and `DisjointRanges` is
trivially satisfiable. It does not constrain the design; it just does not
exercise it.

Two semantic edges are not uniform and should not be relied on:
`DatabaseError::TransactionTooOld` is marked "TODO: Implement in rocksdb and
postgres drivers", and `error_is_transaction_too_large` returns a hardcoded
`false` outside FoundationDB. Retry classification therefore differs by backend
even where the happy path does not.

## Consequences

- The range map is actor state. `receive_preserves_disjoint` becomes
  unnecessary rather than insufficient, because one writer maintains the
  invariant instead of induction preserving it.
- `VClock` keeps its place on the data plane, which is what it was written for.
- Zero trust is **not** currently supported by the proofs. Claiming it would
  overstate what exists: every node is still trusted to propose an honest map
  and an honest promotion. Closing that needs a premise the corpus does not
  have, not a further lemma.

## Open questions

- [ ] Does anything require a range map when the engine is unreachable? That is
      the only argument for gossiping control-plane data, and it should be made
      explicitly rather than assumed.
- [ ] Should `promoteToAuthority` check geometric containment as well as
      capacity?
- [ ] Are the two vacuous theorems in `ReBAC.lean` intended to be proved, or are
      they documentation of an assumption the substrate is expected to discharge?

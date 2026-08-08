# RFD 0018 — Authority, and what the substrate already guarantees

## Status

Analysis. Records what Rivet guarantees, what the Lean proofs establish, and
which of the two is doing the work.

The zone-authority half was written against a decomposition that does not exist
and has been removed with RFD 0005. What remains, and what this RFD is now for,
is the **documented actor semantics** below: they describe the platform as it
is, and anything built on Rivet depends on them.

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

### The two authority theorems are vacuous, and are not cited here

`ReBAC.lean`'s `rebac_requires_authority_for_mutation` and
`non_authority_cannot_bind_mutation` are stated as `True := trivial` with every
hypothesis unused. Their docstrings describe the intended property; the formal
content is provable regardless of any input. That file is imported by
`Research.lean`, which declares itself "NOT on the CI production gate…
aspirational".

**Standard applied: prove them or do not use the proof.** This RFD does not use
them. Nothing here rests on authority binding being formally established.

#### Why they cannot be proved as written

The statement needs a concept the model lacks. `rebacCheck : PlayerClaim →
Action → Bool` is a pure function with no notion of who is asking, so "not
binding" is not expressible about it. The fix is to name the missing concept
rather than to strengthen the proof.

The following restatement compiles under Lean 4, with stand-ins for the
surrounding definitions so it needs no Mathlib:

```lean
/-- The decision this node is entitled to make.
    `none` means "not binding here; forward to the authority zone". -/
def bindingDecision (auth : Bool) (action : Action) : Option Bool :=
  match action with
  | .observe => some (rebacCheck action)
  | _        => if auth then some (rebacCheck action) else none

theorem authority_binds_any_action (action : Action) (h : isAuthority = true) :
    bindingDecision isAuthority action = some (rebacCheck action) := by
  unfold bindingDecision
  cases action <;> simp [h]

theorem non_authority_cannot_bind_mutation
    (action : Action) (hact : action = .interact ∨ action = .modify)
    (hnotauth : isAuthority = false) :
    bindingDecision isAuthority action = none := by
  unfold bindingDecision
  rcases hact with h | h <;> subst h <;> simp [hnotauth]

theorem interest_can_answer_observe (_hnotauth : isAuthority = false) :
    bindingDecision isAuthority .observe = some (rebacCheck .observe) := by
  unfold bindingDecision; simp
```

Verified to compile standalone. Not applied to `lean-rebac-core`, because that
file needs Mathlib at a pinned toolchain and nothing currently consumes the
result. The restatement is recorded so it can be applied when something does.

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

## Documented semantics to build on

Gathered from `website/src/content/docs/actors/`, so these are the platform's
own statements rather than inference. Anything inferred is marked as such.

### Identity

> Keys are unique within each actor name. — `keys.mdx`

Combined with Pegboard exclusivity, a key resolves to at most one live writer.
This is what closes identity forgery, and it is stated rather than assumed.

### State persistence

From `state.mdx`:

> `state` lives in memory and is persisted automatically, so reads and writes
> have no added latency while the data still survives sleeps, restarts,
> upgrades, and crashes.

> Reads never trigger a save, saves aren't tied to action or handler boundaries,
> and state is also flushed when the actor sleeps or shuts down.

Two consequences worth designing around:

- Saves are **not** tied to action boundaries, so an action returning is not a
  durability point. Anything requiring a durability barrier must ask for one.
- `vars` is never saved. It exists only while the actor runs.

### Sleep and wake

From `lifecycle.mdx`:

> Actors automatically sleep after a period of inactivity to free up resources.
> When a request arrives for a sleeping actor, it wakes up, restores its state,
> and handles the request.

> The actor may go to sleep at any time during the `run` handler.

> State mutations made during `onSleep` are persisted before the actor finishes
> sleeping.

`keepAwake(promise)` blocks idle sleep until the promise settles. Sleep is
therefore not a failure mode to defend against; it is the normal resting state,
and long work must hold the actor up explicitly.

### Queues

> **Durable**: messages are persisted and survive actor sleep/restart. —
> `queues.mdx`

So a queue is a durability barrier where plain state is not. It is also a
deadlock hazard: a `wait: true` message an actor sends to itself is documented
as "a guaranteed deadlock because the run loop is already busy".

### Limits that shape the design

From `limits.mdx`:

| Limit | Value |
|---|---|
| Max KV value | 128 KiB |
| Max KV key | 2 KiB |
| Max keys per operation | 128 |
| Max incoming message | 64 KiB soft, 32 MiB hard |
| Max outgoing message | 1 MiB soft, 32 MiB hard |
| Max request/response body | 20 MiB |
| Buffered per connection while asleep | 128 MiB, 65,535 messages |

### Timeouts, which bound every liveness assumption

| Timeout | Value |
|---|---|
| WebSocket open, including `onBeforeConnect` and `createConnState` | 15s |
| Message ack | 30s |
| Connection ping | 30s |
| Hibernation wake | 90s |
| `onRequest` handler | 60s, from `actionTimeout` |

The 15s figure bounds how expensive any connect-time work may be, including
authorisation. Anything that must happen before a connection is usable has to
fit inside it.

## Actors do not operate without the engine

**This is inferred, not documented, and the distinction matters.**

There is no documentation of engine unavailability. Searching the docs for
`unavailable`, `unreachable`, `offline`, `network partition`, and `split-brain`
returns nothing. No page describes a degraded or disconnected mode.

The timeout table implies the answer: every liveness timeout is short and
engine-mediated. A partition lasting more than about 30 seconds closes
connections by ack or ping timeout, and a sleeping actor that cannot be woken
inside 90 seconds disconnects its client.

So the working assumption is that a zone which cannot reach the engine has
already lost its connections, and there is no supported mode in which it
continues serving.

**Undocumented is not the same as unsupported**, and this should be confirmed
rather than relied on. If it holds, it settles the open question below: there is
no availability argument for gossiping the range map, because nothing survives
the outage the gossip would be protecting against.

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

- [ ] **Test it: partition a local cluster and observe.** The conclusion above
      is drawn from silence plus the timeout table, and it is load-bearing for
      keeping the range map in actor state, so it should be a fact rather than
      an inference. The quadlet setup can sever the engine from a zone with
      `podman network disconnect` and watch what an actor does. What to record:
      how long before connections close, whether writes made during the
      partition survive, whether the actor is rescheduled elsewhere, and whether
      anything is served while the engine is unreachable. Same class of work as
      [RFD 0019](0019-large-value-conformance.md).
- [x] **Answered: actor KV chunks at 10 KB**, sized for FoundationDB
      explicitly (`VALUE_CHUNK_SIZE`), so a 128 KiB value is ~13 chunks and the
      naive failure does not occur. What remains untested is the driver at those
      sizes, which is [RFD 0019](0019-large-value-conformance.md).
- [ ] Apply the `bindingDecision` restatement above to `lean-rebac-core`, if and
      when anything depends on authority binding being proved. Until then the
      standard is simply not to cite the vacuous theorems.

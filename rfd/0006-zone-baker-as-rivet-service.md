# RFD 0006 — zone-baker as a Rivet service

## Status

Proposed. Nothing implemented. Was issue #2.

## Problem

A **bidirectional** asset conversion service, running as a Rivet service reached
over WebSocket, storing output in a casync-backed CDN.

Four directions, with OpenUSD as the interchange hub:

| From | To |
|---|---|
| OpenUSD | `.tscn` (Godot scene) |
| `.tscn` | OpenUSD |
| any | OpenUSD |
| OpenUSD | any |

The hub-and-spoke shape is the point. Supporting *n* formats pairwise is
*n²* converters; routing everything through USD is *2n*. It also means the CDN
holds one canonical representation rather than every pairing.

The named converter is
[fabric-flow-adapters](https://github.com/v-sekai-multiplayer-fabric/fabric-flow-adapters).

## Why this fits the actor model better than [RFD 0005](0005-zone-backend-as-rivet-service.md)

Baking is a **job**, not a server. It has a natural key (the asset being baked),
it is CPU-heavy and bursty, it has a definite end, and it holds no long-lived
client state. That is close to what a Rivet actor is for:

- Cold start is acceptable, because a bake is already slow relative to process
  startup.
- Idle sleep is desirable, because bakers should not occupy capacity between
  jobs.
- Per-key singleton semantics give deduplication for free: two requests to bake
  the same asset land on the same actor rather than doing the work twice.

So unlike zone-backend, the actor model is a reason to do this, not an obstacle.

## Shape

`container-runner` hosts a child process per actor and proxies tunnelled
traffic to it. A baker child would:

1. accept a request naming a source and a target format,
2. fetch the source asset,
3. convert, routing through OpenUSD as the hub,
4. write to casync-aria-storage,
5. report the content address back.

Because conversion is bidirectional, the request has to carry a direction. That
makes the natural actor key `(source content address, target format)` rather
than the asset alone, which matters for the deduplication argument above: two
requests for the same asset in *different* formats are different work and should
not share an actor.

## Open questions

- [ ] **The export direction has no named implementation.**
      `fabric-flow-adapters` is IDTX Flow, whose README describes importing USD
      *into* Godot via `UsdStageNode3D`, `UsdMeshInstanceNode3D`,
      `UsdSkeletonNode3D` and similar. That covers **USD to `.tscn`**, one of
      the four directions.

      **`.tscn` to USD** and **any to USD** are the other half of the
      requirement and are not covered by that plugin. Either it gains an export
      path, or a second tool is needed. This should be settled early, because it
      decides whether the baker is one process or two.
- [ ] **Where does the actor boundary sit?** One actor per conversion, or one
      long-lived actor per asset that re-converts on change? The former is
      simpler; the latter caches. Either way the key needs the target format,
      per the note above.
- [ ] **Job duration versus `request_lifespan`.** A serverless runner config has
      a `request_lifespan`, and `drain_grace_period` must be strictly less than
      it ([RFD 0003](0003-engine-configuration.md)). A bake that outlives the
      lifespan needs either a longer lifespan or an async submit-and-poll
      protocol. This should be decided before the protocol is designed, because
      it changes the protocol.
- [ ] **Where does output live?** casync-aria-storage is named as the CDN.
      Whether the baker writes to it directly or hands bytes to something else
      is unspecified.
- [ ] **Is WebSocket the right surface for a job queue?** A long-running bake
      over a held WebSocket ties job liveness to connection liveness. Submitting
      over HTTP and streaming progress over WebSocket may fit better.
- [ ] **Idempotency.** If output is content-addressed, a repeat request should
      return the existing address rather than re-converting. That interacts with
      the actor-key choice above, and with round-trip fidelity: a
      USD-to-`.tscn`-to-USD result is not the same object as the original, so it
      must not collide with it in the CDN.

## Round-trip fidelity is the hard part

Bidirectional conversion through a hub raises a problem one-way conversion does
not: USD to `.tscn` to USD should ideally return something equivalent to the
input, and naively it will not.

USD carries composition that Godot's scene format has no representation for:
sublayers, references, payloads, variant sets, and the `over` specs that IDTX
Flow's own README describes being used for pseudo-instancing. Importing composes
and flattens that structure into concrete nodes. Exporting from the flattened
result cannot reconstruct what was composed away, so a round trip silently
degrades a layered stage into a flat one.

Decisions this forces:

- **Is round-tripping a requirement or a side effect?** If assets originate as
  USD and Godot is only a consumer, flattening is fine. If artists edit in
  Godot and export back, it is not.
- **Does the baker preserve provenance?** Retaining the source stage alongside
  the converted output makes a lossy round trip recoverable, at storage cost.
  Content-addressed storage makes this cheap.
- **What is the equivalence test?** "Converted correctly" needs a definition
  before it can be verified, and geometry comparison is not the same as
  structural comparison.

## If the converter is IDTX Flow, the baker is a headless Godot process

IDTX Flow is a Godot plugin. It needs Godot 4.5+ and is installed into a
project's `addons/` folder, so anything driving it runs inside Godot rather
than as a standalone binary.

That is convenient here. `assets/godot_zone/` already builds a headless Godot
image with `container-runner` as its entrypoint and an addon copied into
`/opt/zone/addons/`, which is exactly the shape a baker needs. The baker would
be the same image with a different addon and a different script, so the two
share their base and their readiness contract.

It also means the baker inherits the constraint in
[RFD 0004](0004-image-provenance.md): the runtime must be the fork's
double-precision build, not an upstream release.

## Relationship to storage

Baked output is large, immutable, and read-mostly, which is object-storage
shaped rather than FoundationDB shaped. It should go to the same class of store
discussed in [RFD 0009](0009-cold-tier-and-backup.md), though for a different
reason: cold-tier offload is about evicting cold state, whereas baked assets are
born cold-tier.

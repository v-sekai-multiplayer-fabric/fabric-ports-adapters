# RFD 0006 — zone-baker as a Rivet service

## Status

Proposed. Nothing implemented. Was issue #2.

## Problem

A service that converts arbitrary asset formats to OpenUSD and stores the result
in a casync-backed CDN, running as a Rivet service reached over WebSocket.

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

1. accept a bake request over the WebSocket surface,
2. fetch the source asset,
3. convert to OpenUSD,
4. write to casync-aria-storage,
5. report the content address back.

## Open questions

- [ ] **The named converter appears to run the other way.** This needs
      resolving before anything else, because it changes what the service is.

      `fabric-flow-adapters` is IDTX Flow, a Godot C++ plugin whose README
      states it "enables the import of Universal Scene Description (USD) files
      into Godot". Its nodes are `UsdStageNode3D`, `UsdMeshInstanceNode3D`,
      `UsdSkeletonNode3D` and so on, which build a Godot scene tree *from* a USD
      stage. That is USD to Godot.

      The requirement here is "converts any to openusd", which is the opposite
      direction. Either the requirement is worded loosely and the baker is
      really a USD-to-Godot importer, or a second tool is needed for the export
      side and has not been named.
- [ ] **Where does the actor boundary sit?** One actor per bake, or one
      long-lived actor per asset that re-bakes on change? The former is simpler;
      the latter caches.
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
- [ ] **Idempotency.** If bakes are content-addressed, a repeat request should
      return the existing address rather than re-baking. That interacts with the
      actor-key choice above.

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

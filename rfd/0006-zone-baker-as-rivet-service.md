# RFD 0006 — zone-baker as a Rivet service

## Status

Proposed. Nothing implemented. Was issue #2.

## Problem

A service that converts arbitrary asset formats to OpenUSD and stores the result
in a casync-backed CDN, running as a Rivet service reached over WebSocket.

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

- [ ] **Which converter?** "Converts any to openusd" is the requirement; the
      implementation is unspecified. Candidates differ wildly in licence,
      footprint, and format coverage.
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

## Relationship to storage

Baked output is large, immutable, and read-mostly, which is object-storage
shaped rather than FoundationDB shaped. It should go to the same class of store
discussed in [RFD 0009](0009-cold-tier-and-backup.md), though for a different
reason: cold-tier offload is about evicting cold state, whereas baked assets are
born cold-tier.

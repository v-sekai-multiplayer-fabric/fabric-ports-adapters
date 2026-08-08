# RFD 0006 — zone-baker as a Rivet service

## Status

Proposed. Nothing implemented. Was issue #2.

## Problem

A **bidirectional** asset conversion service, running as a Rivet service reached
over WebSocket, storing output in a casync-backed CDN.

The two directions are not symmetric, and the asymmetry is the design.

**OpenUSD is the archival format**, in the role `.blend` plays for a Blender
pipeline: the master an artist works from, layered and lossless, never shipped
to a client.

**`.tscn`, `.vrm`, and `.glb` are transmission formats**: derived, runtime-shaped,
and lossy by construction. `.tscn` for Godot scenes, `.vrm` for avatars with
their humanoid rig and spring-bone metadata, `.glb` for general interchange.

That gives two distinct operations:

| Direction | Operation | Fidelity requirement |
|---|---|---|
| any, `.tscn` → OpenUSD | **ingest** into the archive | high; this is the master |
| OpenUSD → `.tscn`, `.vrm`, `.glb` | **publish** a delivery artifact | lossy is expected |

The hub shape still pays off — *n* formats pairwise is *n²* converters, through
a hub it is *2n* — but the stronger reason is that the CDN then holds one
canonical representation plus regenerable derivatives, rather than a set of
peers with no master among them.

## The pieces that already exist

Three repositories cover parts of this, and they split along the same
archival/transmission line.

**[fabric-stage-runtime](https://github.com/v-sekai-multiplayer-fabric/fabric-stage-runtime)**
— OpenUSD 26.05 shipped as an Elixir/Hex package, describing itself as "for
ports, adapters and Elixir consumers". It exposes `StageRuntime.include_dir()`,
`lib_dir()` (containing `usd_ms`), and `target()`, so an Elixir port or NIF can
link against OpenUSD directly. This is the **archival** side, and it is in the
same language as this repo.

**[fabric-flow-adapters](https://github.com/v-sekai-multiplayer-fabric/fabric-flow-adapters)**
— IDTX Flow, a Godot C++ GDExtension that converts a USD stage into a Godot
scene tree (`UsdStageNode3D`, `UsdMeshInstanceNode3D`, `UsdSkeletonNode3D`).
This is the **transmission** side for `.tscn`.

**[fabric-flow-adapters-project](https://github.com/v-sekai-multiplayer-fabric/fabric-flow-adapters-project)**
— a Godot project exercising the plugin, carrying `.usda` fixtures such as
`blendshape_test.usda` and `dome.usda`. Useful as a conformance corpus.

Both trace back to
[idtx-flow](https://github.com/Immersive-Data-Center-Management/idtx-flow).

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

Because conversion is bidirectional, the request has to carry a direction. For
publish, the natural actor key is `(archive content address, target format,
converter version)` rather than the asset alone: two requests for the same asset
in *different* formats are different work and should not share an actor, and the
converter version keeps stale derivatives from being served after an upgrade.

## Open questions

- [ ] **Who owns ingest?** `fabric-stage-runtime` supplies OpenUSD to Elixir,
      which covers writing USD stages, but "any → USD" still needs per-format
      readers. OpenUSD's own plugin set covers some; the rest is unspecified.
- [ ] **Who owns `.vrm` and `.glb`?** Either runtime could, per the note above.
- [ ] **Is `.tscn` → USD needed at all?** It is only meaningful if Godot is an
      authoring surface rather than a consumer. If it is not, that direction
      drops and the Godot half becomes publish-only, which is simpler.
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
      is unspecified. Archive and derivatives likely want different retention,
      per the storage note above.
- [ ] **What is `any` on the ingest side?** The archival direction is the one
      where fidelity matters, so the accepted input set should be enumerated
      rather than left open. `.vrm` and `.glb` arriving as *input* is plausible
      for third-party assets, and is a different case from the same formats
      being emitted as output.
- [ ] **Is WebSocket the right surface for a job queue?** A long-running bake
      over a held WebSocket ties job liveness to connection liveness. Submitting
      over HTTP and streaming progress over WebSocket may fit better.
- [ ] **Idempotency.** If output is content-addressed, a repeat request should
      return the existing address rather than re-converting. That interacts with
      the actor-key choice above.
- [ ] **Is re-ingestion blocked, or merely discouraged?** The rule above says
      derived artifacts are never re-ingested. Whether the baker enforces that,
      by marking outputs with their provenance and refusing them as input, or
      whether it is left to callers, is a real choice: enforcement costs a
      metadata channel, and the failure it prevents is silent.

## Round-tripping is an anti-pattern here, not a requirement

An earlier draft of this RFD treated USD → `.tscn` → USD equivalence as the hard
problem. With the archival/transmission split it is not a problem, because that
path should not be taken.

USD carries composition that no transmission format represents: sublayers,
references, payloads, variant sets, and the `over` specs IDTX Flow's own README
describes for pseudo-instancing. Publishing flattens all of it. Re-ingesting a
published artifact would then archive the flattened result as if it were a
master, quietly destroying the layering.

The rule that follows: **derived artifacts are never re-ingested.** A `.glb`
that came out of the baker is an output, and the archive already holds its
source. Ingestion applies to assets arriving from outside the pipeline, and to
`.tscn` only when Godot is genuinely the authoring surface for that asset.

Consequences worth stating:

- **Derived artifacts are disposable.** Anything in a transmission format can be
  regenerated from the archive, so losing one costs compute, not data. Only the
  archive needs durability guarantees. This is a different storage class from
  the archive itself, and lines up with the tiering in
  [RFD 0009](0009-cold-tier.md): archival USD must never be evicted
  to somewhere unrecoverable, while derivatives are cache-shaped and can be
  dropped freely.
- **The converter version belongs in the derived key.** When a converter
  improves, existing derivatives are stale but still valid. Keying them by
  `(archive address, target format, converter version)` makes regeneration a
  cache miss rather than a migration.
- **Fidelity effort belongs on the ingest side.** Loss on publish is expected
  and bounded by the target format. Loss on ingest is permanent, because the
  archive is the last copy of that structure.

## The baker is probably two runtimes, not one

An earlier draft assumed the baker had to be a headless Godot process, because
IDTX Flow is a Godot plugin. `fabric-stage-runtime` makes that only half true.

**Archival operations do not need Godot.** Reading, writing, and composing USD
stages is OpenUSD's job, and `fabric-stage-runtime` makes that linkable from
Elixir. Ingest (`any` → USD) and any pure-USD manipulation can run in the same
BEAM process as the service itself.

**`.tscn` output does need Godot**, because a Godot scene is defined by Godot's
own serialisation and IDTX Flow runs inside the engine. That path inherits the
constraint from [RFD 0004](0004-image-provenance.md): the runtime must be the
fork's double-precision build, not an upstream release.

`assets/godot_zone/` already builds a headless Godot image with
`container-runner` as its entrypoint and an addon copied into
`/opt/zone/addons/`, which is the shape that half needs. It would be the same
base image with a different addon and script, sharing the readiness contract.

`.vrm` and `.glb` are undecided between the two. Godot can export glTF, and
OpenUSD has its own conversion surface, so either runtime could own them. Since
`.vrm` is glTF plus humanoid and spring-bone extensions, whichever side owns it
must preserve those, which is a reason to prefer the runtime that understands
avatars.

### This would be the repo's first dependency

`mix.exs` currently declares `defp deps, do: []` deliberately: a bootstrap tool
that runs before anything else exists should not need a package fetch. Taking
`stage_runtime` as a dependency is defensible for a baker, but it is a change of
character for this repo and should be a conscious one. Keeping the baker as a
separate Mix application that depends on both, rather than folding it into the
bootstrap tool, avoids the question.

## Relationship to storage

Baked output is large, immutable, and read-mostly, which is object-storage
shaped rather than FoundationDB shaped. It should go to the same class of store
discussed in [RFD 0009](0009-cold-tier.md), though for a different
reason: cold-tier offload is about evicting cold state, whereas baked assets are
born cold-tier.

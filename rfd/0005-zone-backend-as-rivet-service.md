# RFD 0005 — zone-backend (Uro) as a Rivet service

## Status

Proposed. Nothing implemented. Was issue #1.

## Problem

[zone-backend](https://github.com/v-sekai-multiplayer-fabric/zone-backend) is
Uro, the Phoenix/Elixir backend for the Multiplayer Fabric social VR platform.
It runs today as a long-lived container under docker compose, alongside Caddy,
from `multiplayer-fabric-hosting/`.

The ask is to run it as a Rivet service, reached over WebSocket.

## How a container becomes a Rivet service

`container-runner` already does this. It is a RivetKit serverless app that
spawns a child process per actor and proxies Rivet's tunnelled traffic to it:

- WebSocket clients connect at the bare gateway path.
- Raw HTTP reaches the child under a `/request/*` prefix, which the runner
  strips.
- The actor `input` payload can override the child's command, args, and env per
  actor.
- Readiness is a TCP connect to the child's port by default, or a stdout beacon
  for a child that binds only UDP.

So the mechanical work is small: wrap Uro's release in an image with
`rivet-container-runner` as the entrypoint. This is the same shape as the Godot
zone in `assets/godot_zone/`.

## The design tension

The mechanics are easy; the model is not.

A Rivet actor is a **per-key singleton with a lifecycle**. It is created against
a key, it sleeps when idle, and it can be destroyed and rescheduled elsewhere.
Uro is a **multi-tenant web application** with a Postgres database, sessions,
and zone servers that register themselves at startup with multiplicity 0..∞.

Those do not map onto each other without a decision:

- **One actor for all of Uro.** Simplest, but the actor is then a singleton that
  must never sleep, which is a Rivet service in name only. It gains cold-start
  risk and lifecycle machinery it does not want, and gains nothing over a plain
  container.
- **One actor per tenant or per zone.** Fits the actor model, but Uro is not
  written to be partitioned that way, and its Postgres schema is shared.
- **Split Uro.** Keep the web tier as a normal container and move only the parts
  that are genuinely per-zone into actors. Largest change, best fit.

This should be settled before any packaging work, because the packaging differs
per option.

## Open questions

- [ ] Which of the three models above, or a fourth?
- [ ] What owns Uro's Postgres? Rivet's storage is FoundationDB
      ([RFD 0008](0008-hot-tier-foundationdb.md)); Uro expects Postgres. Running
      both is likely correct but should be stated, not assumed.
- [ ] "Must be rivet container via websocket" — is WebSocket the *only* surface,
      or does Uro's existing HTTP API keep its own ingress? Uro serves a REST
      API at `/api/v1/` today, and `container-runner` exposes HTTP under
      `/request/*`, which is a path change for every existing client.
- [ ] Zone servers register with Uro at startup. If Uro is an actor that sleeps,
      what happens to a registration made while it was asleep?
- [ ] Does Caddy stay in front, or does Rivet Guard replace it?

## Prior art in this repo

The Godot zone is the worked example of a container behind `container-runner`,
including the readiness contract and the `/request/*` prefix behaviour. See
[RFD 0004](0004-image-provenance.md) for how its image is assembled.

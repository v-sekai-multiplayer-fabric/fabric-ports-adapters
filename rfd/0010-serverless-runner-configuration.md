# RFD 0010 — Serverless runner configuration

## Status

Accepted. Encoded in `Cluster.runner_config/2`. Split out of
[RFD 0003](0003-engine-configuration.md), which had bundled it with engine
topology; the two are configured through different surfaces and fail in
different places.

## Problem

Registering a container as a serverless runner has a constraint that is not
stated in the API documentation and is only discovered by being rejected.

## Constraint

`drain_grace_period` must be **strictly less than** `request_lifespan`.

`drain_grace_period` defaults to 1800s. A runner config with a shorter lifespan
is rejected:

```
Invalid runner config: `drain_grace_period` must be less than `request_lifespan`
(1800s >= 300s)
```

The default is large enough that any lifespan chosen for a short-lived workload
trips it. Setting `request_lifespan: 300` alone, which looks reasonable, fails.

## Decision

`Cluster.runner_config/2` validates the pair and returns `{:error, reason}`
rather than emitting a config the API will reject. The defaults it uses are
`request_lifespan: 900` with `drain_grace_period: 60`, which satisfy the
constraint and are internally consistent, so the zero-argument form is always
valid.

## Consequences

The failure surfaces before a request is made, with a message naming both
values. A test asserts the rejection case, so the constraint cannot be
regressed silently.

This interacts with job duration. Any workload whose unit of work can outlive
`request_lifespan` needs either a longer lifespan or an asynchronous
submit-and-poll protocol, and that choice changes the protocol rather than just
a number. See [RFD 0006](0006-zone-baker-as-rivet-service.md), where a bake can
plausibly exceed it.

## Registration shape

For reference, the accepted body:

```json
{"datacenters": {"default": {"serverless": {
  "url": "https://host/api/rivet",
  "request_lifespan": 900,
  "drain_grace_period": 60,
  "max_concurrent_actors": 4
}}}}
```

`url` carries `container-runner`'s base path, which defaults to `/api/rivet`.
The engine calls that path to start an actor.

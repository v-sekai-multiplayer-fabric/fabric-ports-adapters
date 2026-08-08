# RFD 0011 — Godot runtime provenance

## Status

Accepted. Pinned in `RivetFabric.Domain.Spec`. Split out of
[RFD 0004](0004-image-provenance.md), which had bundled Godot with the
FoundationDB and Rivet pins; this one has a different failure mode and is worth
finding on its own.

## Problem

The Godot zone needs a Godot engine binary. The obvious source is an upstream
release from godotengine.org, and using one is wrong in a way that does not
surface as an error.

## Decision

The zone image is based on
`ghcr.io/v-sekai-multiplayer-fabric/zone-godot-runtime`, built by
[godot-images](https://github.com/v-sekai-multiplayer-fabric/godot-images) from
the fork's engine source.

That build is **double-precision**:
`godot.linuxbsd.template_release.double.x86_64`, per its quadlet `.build` unit.

## Why an upstream release is not a substitute

Precision is a compile-time property of the engine. A double-precision build and
a single-precision build disagree about the wire representation of positions and
transforms, so a zone built one way and a client built the other will connect,
run, and desynchronise.

An earlier revision of this repo substituted
`Godot_v4.7.1-stable_linux.x86_64`. It downloaded, built, booted headless,
served MCP, and answered a WebSocket echo. Every check passed. The mistake would
have surfaced later as drift between zone and client, which is a much more
expensive place to find it than a failed build.

This is the reason the pin exists rather than a version floor.

## Access

The package is private. Building the zone image needs either

```sh
podman login ghcr.io
```

or a local build from `godot-images`, which ships quadlet `.build` units for
exactly this and is the same substrate this repo targets:

```sh
systemctl --user start zone-godot-runtime-build
```

Verified private as of writing: `podman manifest inspect` returns `DENIED`, and
an anonymous GHCR token request returns
`{"errors":[{"code":"DENIED","message":"invalid token"}]}`.

## Consequences

Anything else that runs Godot inherits this. If the zone-baker turns out to be a
headless Godot process for its `.tscn` side
([RFD 0006](0006-zone-baker-as-rivet-service.md)), it must use the same runtime,
not an upstream release.

The end-to-end MCP run recorded in [RFD 0007](0007-webtransport-in-guard.md)
used the upstream build and has **not** been repeated against this one. It
demonstrates actor lifecycle, readiness, and gateway routing. It does not
demonstrate the zone.

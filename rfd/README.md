# RFDs

Decision records, not manuals. Each states a problem, what was decided, and what
it cost. [0000](0000-how-to-write-an-rfd.md) describes the conventions;
[0021](0021-when-structure-is-justified.md) sets the limits that decide whether
something gets built at all.

Sections below are grouped by **what is actually known**, not by how finished
they feel. Several RFDs record constraints learned from a deployment that
happened outside this repository, and saying so is the point of the grouping.

## Process

| RFD | Title |
|---|---|
| [0000](0000-how-to-write-an-rfd.md) | How to write an RFD |
| [0021](0021-when-structure-is-justified.md) | When structure is justified |

## Implemented and verified here

Code in this repository, exercised by its tests or by a run that was observed.

| RFD | Title |
|---|---|
| [0002](0002-allocate-addresses.md) | Allocate node addresses, do not discover them |
| [0014](0014-foundationdb-driver.md) | A FoundationDB driver for UniversalDB |
| [0015](0015-tooling-constraints.md) | Tooling constraints: no dependencies, deterministic tests |
| [0016](0016-collapse-the-substrate-port.md) | Collapse the substrate port |

## Recorded here, not verified here

Encoded in this repository and covered by unit tests, but the behaviour they
describe was observed in a deployment elsewhere. Nothing here has been accepted
by a live engine, and the images have never been built.

| RFD | Title |
|---|---|
| [0003](0003-engine-configuration.md) | Engine configuration constraints |
| [0004](0004-image-provenance.md) | Image provenance and version coupling |
| [0010](0010-serverless-runner-configuration.md) | Serverless runner configuration |
| [0011](0011-godot-runtime-provenance.md) | Godot runtime provenance |

## Proposed, or built elsewhere

| RFD | Title | State |
|---|---|---|
| [0007](0007-webtransport-in-guard.md) | WebTransport in Guard | steps 1-4 done on the fork |
| [0008](0008-hot-tier-foundationdb.md) | Hot tier: FoundationDB as unified orchestration and actor state | largely already true |
| [0013](0013-foundationdb-backup.md) | FoundationDB backup | nothing implemented |
| [0017](0017-engine-bring-up.md) | Engine bring-up and runner registration | code exists, never run |
| [0018](0018-authority-and-the-trusted-substrate.md) | Authority, and what the substrate already guarantees | analysis; its Lean fix is merged upstream |
| [0019](0019-large-value-conformance.md) | Large-value conformance on FoundationDB | proposed, nothing run |

## Superseded

| RFD | Title | Superseded by |
|---|---|---|
| [0001](0001-substrate-port.md) | A substrate port for cluster bootstrap | [0016](0016-collapse-the-substrate-port.md) |

Kept rather than removed because a specific condition would revive it: a second
production substrate. That is the difference between keeping an analysis and
maintaining a backlog.

## Removed

Five RFDs were removed in `8788100` because nothing consumed them: **0005**
(decomposing Uro into actors), **0006** (zone-baker), **0009** (cold storage
tier), **0012** (actor-based indexing and search), and **0020** (cross-actor
transactions).

They contained real analysis and it is recoverable from git history. It was
removed from the index because a list of confident answers to questions nobody
has asked reads as a backlog. The limits that drove the removal are in
[0021](0021-when-structure-is-justified.md).

## Where to start

[0002](0002-allocate-addresses.md) took three attempts to get right and explains
why the bootstrap looks the way it does.
[0018](0018-authority-and-the-trusted-substrate.md) documents the actor
semantics everything else depends on.

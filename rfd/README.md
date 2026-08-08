# RFDs

Decision records, not manuals. Each states a problem, what was decided, and what
it cost. [RFD 0000](0000-how-to-write-an-rfd.md) describes the conventions.

## Process

| RFD | Title |
|---|---|
| [0000](0000-how-to-write-an-rfd.md) | How to write an RFD |
| [0021](0021-when-structure-is-justified.md) | When structure is justified |

## Implemented and verified

| RFD | Title |
|---|---|
| [0001](0001-substrate-port.md) | A substrate port for cluster bootstrap (superseded by 0016) |
| [0002](0002-allocate-addresses.md) | Allocate node addresses, do not discover them |
| [0003](0003-engine-configuration.md) | Engine topology configuration |
| [0004](0004-image-provenance.md) | Engine image provenance and version coupling |
| [0010](0010-serverless-runner-configuration.md) | Serverless runner configuration |
| [0011](0011-godot-runtime-provenance.md) | Godot runtime provenance |
| [0014](0014-foundationdb-driver.md) | A FoundationDB driver for UniversalDB |
| [0015](0015-tooling-constraints.md) | Tooling constraints: no dependencies, deterministic tests |
| [0016](0016-collapse-the-substrate-port.md) | Collapse the substrate port |

## Proposed, or partially built elsewhere

| RFD | Title | State |
|---|---|---|
| [0007](0007-webtransport-in-guard.md) | WebTransport in Guard | steps 1-4 done on the fork |
| [0008](0008-hot-tier-foundationdb.md) | Hot tier: FoundationDB as unified state | largely already true |
| [0013](0013-foundationdb-backup.md) | FoundationDB backup | nothing implemented |
| [0017](0017-engine-bring-up.md) | Engine bring-up and runner registration | code exists, never run |
| [0018](0018-authority-and-the-trusted-substrate.md) | Authority, and what the substrate already guarantees | analysis |
| [0019](0019-large-value-conformance.md) | Large-value conformance on FoundationDB | proposed, nothing run |

## Removed

Five RFDs were removed because nothing consumed them. They described systems
that do not exist: a zone-baker, a cold storage tier, an actor-based search
index, cross-actor transactions, and a decomposition of Uro into actors.

They contained real analysis, and it is recoverable from git history. It was
removed from the index because a list of confident answers to questions nobody
has asked reads as a backlog, and maintaining it costs more than rederiving it
when there is a reason to. The limits that drove the removal are in
[0021](0021-when-structure-is-justified.md).

Removed in `485383a..`: 0005, 0006, 0009, 0012, 0020.

## Where to start

[0002](0002-allocate-addresses.md) took three attempts to get right and explains
why the bootstrap looks the way it does.

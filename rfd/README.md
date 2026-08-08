# RFDs

Decision records, not manuals. Each states a problem, what was decided, and what
it cost. [RFD 0000](0000-how-to-write-an-rfd.md) describes the conventions.

## Process

| RFD | Title |
|---|---|
| [0000](0000-how-to-write-an-rfd.md) | How to write an RFD |

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
| [0005](0005-zone-backend-as-rivet-service.md) | zone-backend (Uro) as a Rivet service | proposed |
| [0006](0006-zone-baker-as-rivet-service.md) | zone-baker as a Rivet service | proposed |
| [0007](0007-webtransport-in-guard.md) | WebTransport in Guard | steps 1-4 done on the fork |
| [0008](0008-hot-tier-foundationdb.md) | Hot tier: FoundationDB as unified state | largely already true |
| [0009](0009-cold-tier.md) | Cold tier: offload idle actor state | nothing implemented |
| [0012](0012-actor-indexing-and-search.md) | Indexing and search without a shared database | proposed |
| [0013](0013-foundationdb-backup.md) | FoundationDB backup | nothing implemented, cheapest item |
| [0017](0017-engine-bring-up.md) | Engine bring-up and runner registration | code exists, never run |
| [0018](0018-authority-and-the-trusted-substrate.md) | Authority, and what the substrate already guarantees | analysis |
| [0019](0019-large-value-conformance.md) | Large-value conformance on FoundationDB | proposed, nothing run |
| [0020](0020-cross-actor-transactions.md) | Cross-actor linearizable transactions | design: intents + txn record |

## Where to start

[0002](0002-allocate-addresses.md) took three attempts to get right and explains
why the bootstrap looks the way it does. [0012](0012-actor-indexing-and-search.md)
is the one with the most reusable design in it.

# RFDs

Decision records, not manuals. Each states a problem, what was decided, and what
it cost.

Implemented and verified:

| RFD | Title |
|---|---|
| [0001](0001-substrate-port.md) | A substrate port for cluster bootstrap |
| [0002](0002-allocate-addresses.md) | Allocate node addresses, do not discover them |
| [0003](0003-engine-configuration.md) | Engine configuration constraints |
| [0004](0004-image-provenance.md) | Image provenance and version coupling |

Proposed, or partially built elsewhere:

| RFD | Title | State |
|---|---|---|
| [0005](0005-zone-backend-as-rivet-service.md) | zone-backend (Uro) as a Rivet service | proposed |
| [0006](0006-zone-baker-as-rivet-service.md) | zone-baker as a Rivet service | proposed |
| [0007](0007-webtransport-in-guard.md) | WebTransport in Guard | steps 1-4 done on the fork |
| [0008](0008-hot-tier-foundationdb.md) | Hot tier: FoundationDB as unified state | largely already true |
| [0009](0009-cold-tier-and-backup.md) | Cold tier and backup | nothing implemented |

Start with [0002](0002-allocate-addresses.md). It took three attempts to get
right and explains why the bootstrap looks the way it does.

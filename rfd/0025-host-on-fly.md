# RFD 0025 — Host the fabric cluster on Fly.io

## Status

Accepted. Split out of [RFD 0023](0023-where-to-host-the-cluster.md), which
surveyed six options and keeps that comparison. This RFD records the choice and
what it costs.

The configuration is checked in at `self-host/fly/` and has been executed once:
a three-node FoundationDB cluster with `double` redundancy, and the engine
serving `{"runtime":"engine","status":"ok"}` against it. It was then destroyed to
stop billing, so **nothing is running now**.

## Problem

The fabric needs somewhere to run. [RFD 0023](0023-where-to-host-the-cluster.md)
priced six options and found the cheap answer is not the obvious one: Hetzner
Cloud raised prices three times in 2026, dedicated hardware is cheaper per gigabyte
than anything metered, and three Contabo VPS undercut a single Hetzner box while
being more redundant.

None of that settles it, because price per gigabyte is not the only axis. Two
requirements arrived from elsewhere and neither is about RAM:

- [RFD 0024](0024-prove-webtransport-with-shadermotion.md) needs **inbound UDP**,
  because HTTP/3 is QUIC. A host that routes only TCP cannot run the experiment.
- [RFD 0013](0013-foundationdb-backup.md) needs an **off-host S3-compatible
  target**, and deliberately left the vendor open.

## Decision

**Compute on Fly.io. Backups to Tigris.**

### The bill

Sizing is not a guess here, because it is checked in. `self-host/fly/*/fly.toml`
specifies `shared-cpu-2x` at `2gb` for all three apps, and
`foundationdb/fly.toml` provisions `initial_size = "10gb"` per node.

Fly states the rule as "the price of a named CPU/RAM preset, plus about $5 per
30 days per GB of additional RAM". Backing the CPU share out of the published
`shared-cpu-1x` 256 MB price of $2.02 gives ~$0.77 of CPU, so `shared-cpu-2x` at
2 GB is ~$1.54 + $10.00 = **~$11.54/machine**.

| Item | From | Monthly |
|---|---|---|
| 3 × FoundationDB, `shared-cpu-2x` 2 GB | `foundationdb/fly.toml` | $34.62 |
| 1 × engine, `min_machines_running = 1` | `engine/fly.toml` | $11.54 |
| Zone, `min_machines_running = 0`, `auto_stop = "suspend"` | `godot-zone/fly.toml` | ~$0 idle |
| 3 × 10 GB volumes at $0.15/GB | `initial_size` | $4.50 |
| Dedicated IPv4, required for UDP | [RFD 0024](0024-prove-webtransport-with-shadermotion.md) | $2.00 |
| **Always-on total** | | **~$52.66** |

Egress is extra at $0.02/GB in North America and Europe, which is ~$20 per
terabyte. RFD 0024 is the first thing that moves enough traffic to notice.

This is not cheap in absolute terms. ~$53 buys 8 GB across four machines, about
what one Hetzner AX41 costs with 64 GB.

## Why it wins anyway

### The zone line matches the actor model

`godot-zone/fly.toml` sets `min_machines_running = 0` with
`auto_stop_machines = "suspend"`, so conversion capacity costs nothing until
someone uploads a glb. On a rented box that capacity is paid for whether or not
it is used.

This is the one place where the billing model agrees with the architecture
rather than fighting it. A Rivet Actor is allocated on demand and may sleep;
paying per machine-second expresses that directly. It is why Fly is not merely
"convenient rather than cheap".

### The deployment has been executed, not just written

Every other option in RFD 0023 is priced from a rate card and a plan.
`self-host/fly/deploy.sh` brought up a real cluster, which is how
[RFD 0002](0002-allocate-addresses.md) learned that coordinators must be
allocated static addresses rather than discovered, and how
[RFD 0003](0003-engine-configuration.md) learned that the topology has to be
written as a file because the env source cannot merge into an untagged enum.

Those lessons cost a deployment to find. They are already paid for here.

### UDP is available, with conditions

Fly supports inbound UDP, but not by default and not for free:

- It requires a **dedicated IPv4** at $2/month. A shared IPv4 will not do.
- It does not work over public IPv6, because `fly-global-services` has no IPv6.
- The app must bind the special `fly-global-services` address.
- The internal port must equal the external port, because Fly rewrites the IP
  for UDP but not the port.

The last constraint is convenient rather than awkward.
[RFD 0007](0007-webtransport-in-guard.md) step 6 already plans to reuse
`https.port` over UDP, which is the conventional HTTP/3 pairing, so no config
schema change is needed and Fly's no-rewrite behaviour is what makes it work.

### Tigris settles the backup target

[RFD 0013](0013-foundationdb-backup.md) needs off-host S3-compatible storage and
only ever sees a `blobstore://` URL. Fly's own object storage satisfies that on
the same account.

| | Tigris | DO Spaces |
|---|---|---|
| Storage | $0.02/GB, first 5 GB free | $5/month minimum for 250 GB |
| Egress | none charged | metered beyond 1 TB |
| Account | same as compute | separate |

Spaces bills a $5 floor whether the backup is 2 GB or 200 GB. The bigger point
is egress: the one time a backup is read in full is a **restore**, which is the
worst possible moment to be metering bandwidth.

## The free allowance is a place, not a discount

The legacy Hobby allowance is three `shared-cpu-1x` **256 MB** VMs plus 3 GB of
volume. Pricing that as a flat discount misses the point. The question is which
roles fit, and two do.

A FoundationDB **coordinator** is not a data node. Upstream describes
coordinators as "communicating and storing a small amount of shared state", with
the performance impact of acting as one "negligible". The 4 GB per-process
guidance applies to storage and log roles. Three coordinators at 256 MB with 1 GB
of volume each is exactly the allowance, and `foundationdb/fly.toml` already
exposes `FDB_CLASS`, so this is configuration rather than new code.

The second fit is the backup agent above. It streams mutations to a blobstore and
holds no database state.

**What this saves is not mainly money.** Coordinators were already riding along
on the data nodes for free, so moving them off saves nothing directly. The backup
agent saves ~$11.54, and only if it would otherwise get a dedicated machine.

The real gain is stability, and `foundationdb/fly.toml` says why in its own
comments: "a suspended coordinator takes the cluster down", and "coordinators are
addressed by IP, so machine count and identity are load bearing". That constraint
is the entire subject of [RFD 0002](0002-allocate-addresses.md).

Coordinators on three machines that never resize and never get recreated make the
data nodes ordinary again. They become resizable, restartable, and replaceable
without touching the quorum that RFD 0002 had to allocate static addresses to
protect. The free tier stops being a discount and becomes somewhere to put the
role that must not move.

## What is verified

- **The cluster ran.** Three FoundationDB nodes, `double` redundancy, engine
  serving health against it. See [RFD 0002](0002-allocate-addresses.md) and
  [RFD 0014](0014-foundationdb-driver.md).
- **The sizing is checked in**, not estimated, and is the only option in RFD 0023
  where that is true.

## Not verified

- **`fdbserver` in 256 MB.** No source states it starts in that footprint, only
  that the coordination state is small. `fdbserver` also defaults to an 8 GiB
  memory *limit*, which is a cap rather than a reservation. The quadlet rig
  answers this without paying anyone, so test locally first.
- **Whether the account carries a monthly credit.** Fly's docs say plainly that
  "current customers use pay-as-you-go pricing with no included monthly credits",
  and no $15/month credit appears in any published plan. If one exists it is
  account-specific and settled by an invoice, not a rate card. At $15 it would
  put this at **~$38/month net**, which does not change the decision.
- **UDP end to end.** The constraints above are from Fly's documentation. Nothing
  has sent a QUIC packet through Fly to an actor, because
  [RFD 0007](0007-webtransport-in-guard.md) steps 5 and 6 are not done.
- **The engine image.** Never built ([RFD 0017](0017-engine-bring-up.md)), so
  `engine-up` has never run here or anywhere.

## Consequences

**Fault tolerance is real but small.** Four machines in one region is not
multi-region. `deploy.sh` passes the same `${REGION}` to every app, so a region
outage takes everything. That is a deliberate scope limit, not an oversight.

**Egress becomes the variable to watch.** Compute is fixed and predictable;
bandwidth is not. At $0.02/GB the demo is affordable, but a workload that
streams continuously would change the arithmetic, and nobody has counted RFD
0024's runs.

**A cheaper option is being declined knowingly.** Three Contabo VPS at ~€13.50
total is roughly a quarter of this and is more distributed. That trade is
being made for a deployment that already works and a billing model that matches
the actor lifecycle, not because the alternative was worse on price.

## Open questions

- [ ] Does the account carry a monthly credit? An invoice settles it.
- [ ] Do coordinators hold quorum in 256 MB? If so, move them onto the free
      allowance and make the data nodes freely replaceable.
- [ ] Does the zone's `auto_stop = "suspend"` interact badly with a conversion in
      flight? A 100 MB glb takes ~17 s and the machine must not suspend under it.
- [ ] What region, given RFD 0024 measures latency from a real client network?
      `sjc` is what `deploy.sh` used, chosen without a stated reason.

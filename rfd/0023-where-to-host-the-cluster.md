# RFD 0023 — Where to host the fabric cluster

## Status

Proposed as a survey. The decision it led to is
[RFD 0025](0025-host-on-fly.md). Prices surveyed **August 2026** and are volatile: Hetzner raised cloud
prices three times during 2026, most recently on 15 June. Re-check before
committing.

## Requirements, from what has been measured

Not guessed. These come from the cluster that actually ran.

| Component | Needs | Source |
|---|---|---|
| FoundationDB × 3 | 4 GB per process recommended; ran at 2 GB and `status` warned | [RFD 0008](0008-hot-tier-foundationdb.md) |
| Rivet Engine × 1 | `libfdb_c.so`, public ingress on 6420 | [RFD 0004](0004-image-provenance.md) |
| Godot zone × N | 43.8 MiB idle; a 100 MB conversion needs roughly 300–500 MB | [RFD 0022](0022-glb-to-godot-scene.md) |
| Storage | 3 × 10 GB volumes provisioned on the Fly run | [RFD 0002](0002-allocate-addresses.md) |
| Backup target | off-host, S3-compatible | [RFD 0013](0013-foundationdb-backup.md) |

So roughly **16–24 GB RAM, ~100 GB disk, one public IP**, plus somewhere else
entirely for backups.

### What RFD 0024 adds

[RFD 0024](0024-prove-webtransport-with-shadermotion.md) proposes a WebTransport
experiment, and it changes three things that were not priced before.

**Inbound UDP is now mandatory.** HTTP/3 is QUIC over UDP, so a host that only
routes TCP cannot run the experiment at all. On rented VMs this is free and
uninteresting. On Fly it is neither: UDP requires a **dedicated IPv4 at
$2/month**, does not work over public IPv6, must bind the special
`fly-global-services` address, and must use the same port externally that it
binds internally. That last point is convenient rather than awkward, because
[RFD 0007](0007-webtransport-in-guard.md) step 6 already plans to reuse
`https.port` over UDP and Fly does not rewrite UDP ports.

**Egress stops being a rounding error.** The experiment streams a 100 MB VRM per
run and repeats it, once per transport, many times. Bandwidth moves from a
footnote to a line item, and it is the column where the options differ most.

**Impairment needs `NET_ADMIN`, but probably not on the host.** `tc netem` needs
the capability wherever it runs, and the natural place to run it is the test
client rather than the server. Impairing the viewer's own downlink is both more
faithful to the scenario and outside the hosting decision entirely. This is
called out so nobody buys a privileged host for it.

## The tension that decides this

`double` redundancy tolerates losing one machine. That is the property
[RFD 0002](0002-allocate-addresses.md) verified: *fault tolerance 1 machine*.

**On a single host, three FoundationDB nodes are three processes, not three
machines.** Losing the host loses all of them at once, and the redundancy is
decoration. So the question is not simply "cheapest" but which of two different
things is being bought:

- **Cheapest that runs the stack** — one box, everything containerised.
  Fine for development and for proving the pipeline. Not fault tolerant.
- **Cheapest that keeps the fault tolerance already designed for** — three
  separate machines, which is a different and not necessarily larger bill.

## Prices, August 2026

| Option | Spec | Monthly | Machines |
|---|---|---|---|
| [Hetzner AX41](https://www.hetzner.com/dedicated-rootserver/ax41/) dedicated | Ryzen 5 3600, 64 GB, 2 × 512 GB NVMe | ~€49 | 1 |
| [Hetzner CPX22](https://northflank.com/blog/hetzner-cloud-server-price-increases) cloud | shared vCPU | €19.49 each | n |
| [Hetzner CX23](https://costgoat.com/pricing/hetzner) cloud | shared vCPU, entry | €5.49 each | n |
| [Contabo](https://contabo.com/blog/best-vps-hosting-providers/) entry VPS | 4 vCPU, 6 GB, 100 GB NVMe, 32 TB traffic | €4.50 each | n |
| [Netcup](http://netcupvoucher.com/blog/netcup-vs-hetzner-budget-servers-2026) entry VPS | 2 vCPU, 2 GB, 64 GB SSD | €3.35 each | n |

### The June 2026 increase changes the usual answer

Hetzner Cloud is the reflexive recommendation and is no longer the cheap option
for this shape of workload. On 15 June 2026 CPX rose about 144% and CCX by up to
209%. A four-VM cloud deployment on CPX22 is now roughly €78/month, which is
**more than the AX41 dedicated box with 64 GB of RAM**.

Netcup is reported not to have moved since May 2026, which matters as much as
the headline number: a provider that repriced three times in a year is a
different risk from one that did not.

## Accounts that already exist

DigitalOcean, Fly.io, and Google are already set up. That is worth real money
even though none of them is the cheapest line item, because an existing account
has no procurement, no new security review, no separate invoice, and possibly
credits already paid for.

| Provider | Relevant offer | Monthly for our shape |
|---|---|---|
| [DigitalOcean](https://www.digitalocean.com/pricing/droplets) Premium AMD NVMe | 8 GiB tier at $54 | ~$162 for three |
| [DigitalOcean](https://www.digitalocean.com/pricing/droplets) General Purpose | 8 GB from $63 | ~$189 for three |
| [DigitalOcean](https://www.digitalocean.com/pricing/droplets) Memory-Optimized | 16 GB from $84 | ~$252 for three |
| Fly.io | per machine plus per volume | 5 machines + 30 GB previously |
| Google Compute | always-on VMs, sustained-use discounts | not surveyed |

So DigitalOcean is roughly **three times** the Hetzner dedicated box for
equivalent RAM, and ten times a three-node Contabo deployment. That is the
honest number.

### The part that changes the recommendation anyway

**Every one of them can host the backups.** DigitalOcean Spaces, Google Cloud
Storage, and Fly's Tigris all present an S3-compatible surface, and
[RFD 0013](0013-foundationdb-backup.md) deliberately leaves the vendor open
because `fdbbackup` only ever sees a `blobstore://` URL.

So this requirement does not discriminate between the accounts, and it is the
single cheapest thing on this page to actually do. It closes a gap where the
volumes are currently the only copy of the data.
[RFD 0025](0025-host-on-fly.md) picks Tigris, on zero egress rather than on
storage price.

**Fly.io is already targeted by working code.** `deploy.sh` brought up a real
three-node cluster there, and the engine and zone Containerfiles were written
for it. It is not the cheapest, but it is the only option on this page where the
deployment path has been executed rather than described.

## Egress, which RFD 0024 promotes to a real cost

Rates differ by more than an order of magnitude, and the workload is now bulk
transfer rather than a control plane.

| Option | Included | Overage | 100 GB/month | 1 TB/month |
|---|---|---|---|---|
| Hetzner AX41 | 20 TB | ~€1/TB | included | included |
| Contabo VPS | 32 TB | — | included | included |
| DigitalOcean | 1 TB+ per droplet | $0.01/GB | included | included |
| Fly.io | none | $0.02/GB | $2.00 | $20.00 |
| Google, Standard Tier | 200 GiB/account | $0.085/GB | included | ~$70 |
| Google, Premium Tier | **1 GiB/month** | **$0.12/GB** | **$11.88** | **$119.88** |

Google's default is Premium, and Premium includes one gibibyte. Reports in 2026
describe GCP as having doubled egress rates. At a terabyte that single line is
**larger than the compute bill**, taking Google from ~$52 to ~$172 and making it
the most expensive option here rather than the mid-priced one.

Standard Tier fixes most of it and is a deliberate choice that has to be made
per resource. It routes over the public internet instead of Google's backbone,
which for a latency experiment is a trade worth thinking about rather than a
free win.

Bare-metal and VPS options simply do not have this problem. 20 to 32 TB included
means the experiment never reaches the meter.

## Options

### A. One Hetzner AX41, everything containerised — ~€49/month

64 GB RAM against a 16–24 GB requirement, so three FoundationDB nodes get their
recommended 4 GB each with room for zones doing 100 MB conversions. Quadlets
already work this way ([RFD 0001](0001-substrate-port.md)), so the local
bring-up transfers directly.

**Not fault tolerant.** One host, one failure domain. Honest for development.

### B. Three Contabo VPS — ~€13.50/month

6 GB each, so one FoundationDB process per machine at above the recommended
4 GB, across three real failure domains. Cheaper than option A **and** actually
distributed, which is the surprising result of this survey.

Contabo's performance is widely described as variable and best suited to simpler
workloads. FoundationDB is latency-sensitive, and a cold read on the undersized
Fly cluster was already observed at `duration_ms=2200`
([RFD 0008](0008-hot-tier-foundationdb.md)). This needs measuring, not assuming.

### C. Three Netcup VPS — ~€10/month

Cheapest genuinely distributed option, and the most stable pricing. But 2 GB per
machine is **below** FoundationDB's 4 GB recommendation, and 2 GB is exactly
what the Fly deployment ran while `status` complained. Leaves nothing for a
Godot zone doing a 100 MB conversion, so zones would need their own machines.

### D. Fly.io — the configuration already built, ~$53/month

The only option whose sizing is checked in rather than estimated:
`self-host/fly/*/fly.toml` at `shared-cpu-2x`/`2gb` with 10 GB volumes. Four
machines, ~8 GB total, plus $2 for the dedicated IPv4 that inbound UDP requires.

Two properties no other option has: the zone scales to zero, so idle conversion
capacity is free, and the deployment has actually been executed.

**This is the option that was chosen.** Pulled out into
[RFD 0025](0025-host-on-fly.md), which carries the full bill, the UDP
constraints, the free-allowance analysis, and what is verified.

### E. DigitalOcean — existing account, ~3x the price

Three 8 GiB droplets at roughly $162/month against ~€49 for a dedicated box with
64 GB. The premium buys an account that already exists, an API the team knows,
and Spaces for backups in the same place.

Defensible if the time cost of onboarding a new vendor is worth more than
~$110/month, which for a small team it may well be. Note that it is also the
most expensive of the three accounts already held, by roughly 3x.

### F. Google Compute Engine — existing account, ~$52/month

Priced against the same shape as option D, so the two are comparable.
`e2-small` is 2 shared vCPU and 2 GB, matching `shared-cpu-2x` at `2gb`
closely enough.

| Item | Rate | Monthly |
|---|---|---|
| 3 × `e2-small` FoundationDB | $12.23 | $36.69 |
| 1 × `e2-small` engine | $12.23 | $12.23 |
| 30 GB `pd-balanced` | $0.10/GiB | $3.00 |
| Egress at 1 TB, Premium Tier | default | $119.88 |
| **On-demand total, control plane only** | | **~$51.92** |
| **With 1 TB of demo traffic** | | **~$171.80** |

That lands within a dollar of Fly, which is a coincidence worth noticing: two
very different billing models converge because both are really charging ~$5–6
per GB of RAM per month.

**Two Google-specific levers, one useful and one not.**

A one-year committed use discount takes `e2-medium` from $24.46 to $15.41, a
37% cut. Applied here that is roughly **$34/month**, the cheapest of any managed
option. But it commits a year to a stack that has not yet run end to end
([RFD 0017](0017-engine-bring-up.md)). Committing before the engine image builds
is buying certainty about the wrong variable.

Spot pricing is steeper still, `e2-medium` at $0.0201/hour against $0.0335. Spot
is disqualifying for FoundationDB nodes, which is precisely where the money is.
It would suit zones, which are already designed to be interruptible.

**What Google does not have is Fly's zero.** The always-free tier is one
`e2-micro` at 1 GB plus 30 GB of standard disk, which offsets roughly $6/month
and cannot host a FoundationDB node. On plain Compute Engine a zone VM bills
whether or not anyone is converting anything. Getting scale-to-zero means Cloud
Run, and the zone actor is a stateful container holding a SceneTree, which is
not what Cloud Run is for. This is the same point as option D from the other
side: the pricing model either matches the actor lifecycle or it does not.


## Recommendation

**Fly.io, recorded in [RFD 0025](0025-host-on-fly.md).** Backups to Tigris on the
same account, which satisfies [RFD 0013](0013-foundationdb-backup.md) with no new
vendor.

The survey is kept because the decision is not obvious from price alone, and
because the runners-up matter if the choice is revisited:

| Option | Compute | With 1 TB demo traffic | Notes |
|---|---|---|---|
| A. Hetzner AX41 | ~€49 | included | 64 GB, but one failure domain |
| B. Three Contabo VPS | ~€13.50 | included | cheapest **and** more redundant |
| C. Three Netcup VPS | ~€10 | included | leaves no headroom |
| D. Fly.io | ~$53 | ~$73 | chosen, see RFD 0025 |
| E. DigitalOcean | ~$162 | ~$162 | ~3x for compute |
| F. Google Compute | ~$52 | **~$172** | Premium egress dominates |

**The cheapest option was declined knowingly.** Option B is roughly a quarter of
Fly and is genuinely distributed, where option A puts three FoundationDB
processes on one host and calls it three nodes. Fly was chosen for a deployment
that already works and a billing model that matches the actor lifecycle, not
because B was worse on price. If cost becomes the binding constraint, B is where
to go, after benchmarking FoundationDB on Contabo.

**Egress is what reorders the table.** At the control plane alone Fly and Google
are within a dollar. At a terabyte Google is the most expensive option here, and
DigitalOcean's included transfer stops looking absurd. Bare metal and VPS never
reach the meter at all.

## What this does not account for

- **No benchmarks.** Every option is priced on RAM and core count, and
  FoundationDB is sensitive to disk latency and network jitter, neither of which
  appears in a price table.
- **How much traffic the experiment actually generates.** The 100 GB and 1 TB
  columns are illustrative brackets, not a measurement. A 100 MB conversion
  moves ~230 MB across the wire in base64, and RFD 0024 repeats transfers per
  transport, but nobody has counted the runs.
- **Prices move.** Hetzner changed three times in 2026. This is a snapshot.
- **Nothing is deployed to any of these right now.** The Fly cluster did run
  and was verified, then was destroyed to stop billing. Its configuration is
  still checked in and is the only sizing here that is not an estimate.

## Open questions

- [ ] Does FoundationDB perform acceptably on Contabo, given the variability
      reports? That decides whether option B is real.
- [ ] Does Google Standard Tier networking distort the latency measurement? It
      avoids the egress bill by leaving the backbone, which is exactly the
      variable RFD 0024 is measuring.
- [ ] Do zones need their own machines, or do they share with FoundationDB? A
      100 MB conversion next to a database is contention worth measuring.

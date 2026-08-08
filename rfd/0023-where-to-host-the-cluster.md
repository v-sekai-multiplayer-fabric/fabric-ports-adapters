# RFD 0023 — Where to host the fabric cluster

## Status

Proposed. Prices surveyed **August 2026** and are volatile: Hetzner raised cloud
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

**DigitalOcean Spaces is S3-compatible**, and Google Cloud Storage has an
S3-compatible surface. [RFD 0013](0013-foundationdb-backup.md) requires an
off-host S3 target and deliberately leaves the vendor open, because `fdbbackup`
only sees a `blobstore://` URL.

That requirement is satisfied today, on an account that already exists, with no
new vendor and no versitygw to operate. It is the single cheapest thing on this
page to actually do, and it closes a gap where the volumes are currently the
only copy of the data.

**Fly.io is already targeted by working code.** `deploy.sh` brought up a real
three-node cluster there, and the engine and zone Containerfiles were written
for it. It is not the cheapest, but it is the only option on this page where the
deployment path has been executed rather than described.

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

### D. Fly.io — the configuration already built, ~$51/month

The only option whose sizing is not a guess, because it is checked in.
`self-host/fly/*/fly.toml` specifies `shared-cpu-2x` at `2gb` for all three
apps, and `foundationdb/fly.toml` provisions `initial_size = "10gb"` per node.

Fly states the rule as "the price of a named CPU/RAM preset, plus about $5 per
30 days per GB of additional RAM". Backing the CPU share out of the published
`shared-cpu-1x` 256 MB price of $2.02 gives ~$0.77 of CPU, so `shared-cpu-2x`
at 2 GB is ~$1.54 + $10.00 = **~$11.54/machine**.

| Item | From | Monthly |
|---|---|---|
| 3 × FoundationDB, `shared-cpu-2x` 2 GB | `foundationdb/fly.toml` | $34.62 |
| 1 × engine, `min_machines_running = 1` | `engine/fly.toml` | $11.54 |
| Zone, `min_machines_running = 0`, `auto_stop = "suspend"` | `godot-zone/fly.toml` | ~$0 idle |
| 3 × 10 GB volumes at $0.15/GB | `initial_size` | $4.50 |
| **Always-on total** | | **~$50.66** |

Egress is extra at $0.02/GB in North America and Europe.

**The zone line is the interesting one.** It is configured to scale to zero and
suspend, so conversion capacity costs nothing until someone uploads a glb. On a
rented box that capacity is paid for whether or not it is used. This is the one
place where the pricing model matches the actor model rather than fighting it,
and it is why Fly is not simply "convenient rather than cheap".

The rest is expensive: ~$51 buys 8 GB across four machines, which is roughly
what one AX41 costs with 64 GB.

**On the free allowance.** The legacy Hobby allowance is three `shared-cpu-1x`
**256 MB** VMs plus 3 GB of volume. It is wrong to price this as a flat discount:
the question is which roles fit, and two of them do.

A FoundationDB *coordinator* is not a data node. Upstream describes coordinators
as "communicating and storing a small amount of shared state", with the
performance impact of acting as one "negligible". The 4 GB per-process guidance
is for storage and log roles. Three coordinators at 256 MB with 1 GB of volume
each is exactly the free allowance, and `foundationdb/fly.toml` already exposes
`FDB_CLASS`, so this is configuration rather than new code.

The second fit is the backup agent from
[RFD 0013](0013-foundationdb-backup.md). It streams mutations to a blobstore and
holds no database state.

**What this saves is not mainly money.** Coordinators were already riding along
on the data nodes for free, so moving them off saves nothing directly; the
backup agent saves one machine, ~$11.54, only if it would otherwise get a
dedicated one. The real gain is stability, and `foundationdb/fly.toml` says why
in its own comment: "a suspended coordinator takes the cluster down", and
"coordinators are addressed by IP, so machine count and identity are load
bearing". That constraint is the entire subject of
[RFD 0002](0002-allocate-addresses.md).

Coordinators on three machines that never resize and never get recreated make
the data nodes ordinary again. They can be resized, restarted, or replaced
without touching the quorum that RFD 0002 had to allocate static addresses to
protect. The free tier stops being a discount and becomes a place to put the
role that must not move.

**Unverified, and cheap to verify.** No source states that `fdbserver` starts in
256 MB, only that the coordination state is small; `fdbserver` also defaults to
an 8 GiB memory *limit*, which is a cap rather than a reservation. The quadlet
rig exists precisely to answer this without paying anyone, so this should be
tested locally before being relied on.

Fly's current docs say plainly that "current customers use pay-as-you-go pricing
with no included monthly credits", so whether the allowance applies at all is
account-specific and settled by an invoice, not the rate card.

Fly's current docs say plainly that "current customers use pay-as-you-go pricing
with no included monthly credits", and no $15/month credit appears in any
published plan. If the account does carry one, it is account-specific and worth
confirming against an actual invoice rather than the rate card. At $15/month it
would put Fly at **~$36/month net**, which does not change the ordering below.

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
| **On-demand total** | | **~$51.92** |

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

**Split the decision, because the two halves have different answers.**

**Backups: Tigris, now.** Fly's own object storage is S3-compatible, which is
all [RFD 0013](0013-foundationdb-backup.md) requires, and it beats DigitalOcean
Spaces on both axes that matter here:

| | Tigris | DO Spaces |
|---|---|---|
| Storage | $0.02/GB, first 5 GB free | $5/month minimum for 250 GB |
| Egress | none charged | metered beyond 1 TB |
| Account | same as compute | separate |

Spaces bills a $5 floor whether the backup is 2 GB or 200 GB. More importantly
Tigris charges nothing for egress, and the one time a backup is read in full is
a restore, which is the worst possible moment to meter bandwidth.

Prefer Tigris. It is the only item here that protects data that already exists,
and it does not depend on the compute decision.

**Compute: option A for now, option B when fault tolerance is required.**

Nothing has run end to end yet: the engine image has never been built
([RFD 0017](0017-engine-bring-up.md)), so the immediate need is one machine that
can run the whole stack while that is proved. 64 GB for €49 buys enough headroom
that sizing stops being a variable while other things are debugged, and matches
the quadlet bring-up already working locally.

Option B is the better production answer and is cheaper, which is unusual enough
to double-check before relying on it. Move when the fault tolerance is worth
having, and benchmark FoundationDB on Contabo first.

**If no new vendor is wanted, the answer is Fly, not DigitalOcean.** Now that
all three existing accounts are priced against the same shape, they separate
cleanly:

| Existing account | Monthly | Config written? | Zone scales to zero? |
|---|---|---|---|
| Fly.io | ~$51 | yes, and it ran | yes |
| Google Compute | ~$52 (~$34 committed) | no | no |
| DigitalOcean | ~$162 | no | no |

Fly and Google cost the same to within a dollar, so the tiebreaks are that Fly's
deployment already exists and has been executed, and that its zone bills nothing
while idle. Google's committed-use discount is the cheaper number, but it buys a
year of certainty about a stack that has not run yet.

DigitalOcean is 3x either of them for compute, and Tigris removes the reason to
use it for storage too. Its earlier framing here as the incumbent-account option
was wrong: it is the most expensive account already held, not the convenient
one.

## What this does not account for

- **No benchmarks.** Every option is priced on RAM and core count, and
  FoundationDB is sensitive to disk latency and network jitter, neither of which
  appears in a price table.
- **Bandwidth.** A 100 MB conversion moves ~230 MB across the wire in base64.
  Contabo advertises 32 TB; the others are not compared here.
- **Prices move.** Hetzner changed three times in 2026. This is a snapshot.
- **Nothing is deployed to any of these right now.** The Fly cluster did run
  and was verified, then was destroyed to stop billing. Its configuration is
  still checked in and is the only sizing here that is not an estimate.

## Open questions

- [ ] Does FoundationDB perform acceptably on Contabo, given the variability
      reports? That decides whether option B is real.
- [ ] Does `fdbserver` start and hold a coordinator quorum in 256 MB? If it
      does, the free allowance can host the role that must not move. Testable on
      the quadlet rig for nothing.
- [ ] Does the Fly account carry a monthly credit? Published plans show none,
      and the legacy allowance is too small to run FoundationDB. An invoice
      settles it; the rate card does not.
- [ ] Do zones need their own machines, or do they share with FoundationDB? A
      100 MB conversion next to a database is contention worth measuring.

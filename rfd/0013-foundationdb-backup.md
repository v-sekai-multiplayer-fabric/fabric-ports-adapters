# RFD 0013 — FoundationDB backup

## Status

Mechanism proven live on the local quadlet substrate: continuous `fdbbackup`
writing through versitygw into a volume, a snapshot completing and its bytes
landing on disk. Not yet codified into the bootstrap, and restore is not yet
verified. Originally bundled with a cold-storage tier, which has since been
removed as having no consumer. Backup survived that removal because it protects
data that exists rather than data that might.

## Problem

There is no backup. The validated deployment ran a three-node cluster with the
volumes as the only copy of the data. `double` redundancy survives losing one
machine; it does not survive an operator error, a bad migration, or a corrupt
write.

## Why this is separate from the cold tier

Both want S3-compatible storage, which is why they were written up together.
Their requirements are opposite:

| | Backup | Cold tier |
|---|---|---|
| Access pattern | sequential | random |
| Write ratio | write-mostly | write-once, read-on-wake |
| Latency | tolerant | on the actor wake path |
| Rivet changes | **none** | substantial |

Bundling them made the whole thing look like a large project. Backup is not.

## Decision

Continuous backup to an off-host S3-compatible target, using FoundationDB's
native backup. `fdbbackup` is already present in the
`foundationdb/foundationdb:7.3.76` image and accepts a blobstore URL directly:

```
blobstore://<api_key>:<secret>:<security_token>@<host>[:<port>]/<name>?bucket=<bucket>
```

Confirmed present in the image in use.

This needs **no changes to Rivet, depot, or the VFS**. It operates below all of
them, on the cluster itself.

## S3 endpoint

The target must be **off-host** and S3-compatible. Beyond that the shape is
deliberately open: a managed provider and
[versitygw](https://github.com/versity/versitygw) on a separate machine are
interchangeable from `fdbbackup`'s point of view, because versitygw encapsulates
whatever is behind it and presents S3 either way.

Running versitygw beside the FoundationDB nodes is useful for proving the
mechanism, including a verified restore, but it is not a backup: it does not
survive losing that machine.

A cold tier could reuse the same endpoint, but sizing and durability should be
decided per use rather than shared by default, given the profile difference
above.

## What the live proof settled

Three things that were not guessable and each cost an attempt:

- **The volume is the object store.** versitygw's `posix /data` backend maps a
  top-level directory to a bucket, so creating the bucket is `mkdir /data/<name>`
  and the S3 objects are plain files under it. This is the whole point of "an S3
  emulator and a volume": no separate object database.
- **Plain HTTP, with `secure_connection=0`.** On the fabric network there is no
  TLS. FDB connected immediately once that parameter was set
  (`S3BlobStoreEndpointNewConnectionSuccess`); the earlier "operation timed out"
  was a short default request timeout, not a transport problem.
- **Credentials go inline in the URL, not a credentials file.** A
  `--blob-credentials` file keyed `access_key@host:port` failed with
  `backup_auth_missing`: FDB keys its lookup on `access_key@host` without the
  port. `blobstore://<key>:<secret>@<host>:<port>/...` sidesteps the lookup and
  is acceptable for a local dev quickstart. A file (keyed without the port) is
  the right choice off-host where the secret must not sit in `fdbbackup status`.

A `backup_agent` must be running for any data to move; with inline-URL
credentials the agent needs only `-C <cluster file>`, since it reads the
destination (with its inline secret) from the database.

## Tasks

- [x] Stand up versitygw and prove `fdbbackup` writes through it into a volume.
- [ ] Codify it into the bootstrap: a versitygw quadlet, a `backup_agent`
      quadlet, and `fdbbackup start`, behind CLI verbs.
- [ ] **Verify a restore, not just a backup.** An unverified backup is not a
      backup, and `fdbrestore` is in the same image.
- [x] **Decided: continuous** (`fdbbackup start`), targeting near-zero data
      loss. Costs a permanently running backup agent and steady write traffic to
      the S3 endpoint.
- [ ] Decide retention.
- [ ] Decide where the blobstore credentials live, given they cannot go in the
      repo.

## Open questions

- [x] **Decided: off-host.** A target on the same machine as the cluster does
      not survive losing that machine, which is most of the point. Consequence
      for local quadlet testing: the backup target is deliberately *not* part of
      the same set of units, so a purely local bring-up cannot demonstrate the
      real configuration, only the mechanism.
- [x] **The exact target is deliberately unspecified.** The requirement is an
      off-host S3-compatible endpoint. Whether that is a managed provider or
      versitygw on a separate machine is an operational choice, not an
      architectural one, because versitygw encapsulates its backing store behind
      the S3 interface either way. `fdbbackup` sees the same `blobstore://` URL
      regardless.
- [ ] Where do the blobstore credentials live? They cannot be in the repo, and
      the quadlet units need them at start.

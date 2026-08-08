# RFD 0026 — Terminate TLS inside the engine, and keep the certificate

## Status

Partially implemented on the fork's `webtransport-datagrams` branch. The
certificate resolver and the QUIC bind address are done and verified; issuance
is not.

Backfilled after the fact. The decisions here were made while unblocking
[RFD 0007](0007-webtransport-in-guard.md), and they are load bearing enough to
find on their own.

## Problem

[RFD 0007](0007-webtransport-in-guard.md) built a QUIC listener that never
bound. The cause was not in any of the transport code:

```rust
// engine/packages/guard/src/tls.rs, before this RFD
pub async fn create_cert_resolver(...) -> Result<Option<CertResolverFn>> {
    return Ok(None);
    // ~80 lines of the real implementation, commented out
}
```

`guard-core/src/server.rs` spawns the HTTP/3 listener only when a certificate
resolver exists, so returning `None` disabled HTTPS and HTTP/3 together. It had
been that way since `6c92532ef` (2025-10-21, a monorepo reorg), so it reads as
refactor collateral rather than a decision. The commented code depended on
`cluster::ops::datacenter::get` and `rivet.edge()`, neither of which still
exists, so it was inert text rather than dead code.

Underneath that sat a constraint that is not going away: **Fly terminates TLS at
its edge for TCP only.** UDP arrives as raw packets. QUIC's handshake *is*
TLS 1.3, so it happens inside the container and the private key has to be there.
No hosted certificate can serve this.

## Decision

### A real certificate, not a pinned self-signed one

The deliverable is a browser demo, and a browser will not open a WebTransport
session to an untrusted server.

WebTransport's `serverCertificateHashes` would permit a self-signed certificate
pinned by SHA-256, and it is tempting because it needs no CA. It was rejected:

- The specification frames it as being for "prototype work against ad-hoc
  servers", and the W3C document is still a Working Draft in Working Group Last
  Call, so breaking changes can still land.
- It caps validity at **under two weeks** and requires ECDSA P-256. That forces
  a regenerate-and-redistribute cycle every 13 days, and the hash has to reach
  every client out of band. It is the WebRTC DTLS-fingerprint pattern, which
  WebRTC solves with a signalling channel that does not exist here.

Let's Encrypt cannot serve that path anyway: its shortest certificate is 90
days, well past the ceiling. The two approaches are not substitutes.

### The hostname is free

**`fly.dev` is on the Public Suffix List.** Let's Encrypt therefore treats
`mf-rivet-engine.fly.dev` as its own registrable domain, and a certificate can
be issued for the app's existing hostname over HTTP-01.

No domain purchase, no DNS control, no custom domain. This is the fact that
turns ACME from a project into a task, and it is worth knowing before anyone
buys a domain to solve this.

### The certificate lives in UniversalDB, not on disk

This is the part that would have caused real damage.

- `flyctl volumes list --app mf-rivet-engine` is **empty**. The container
  filesystem does not survive a restart, let alone a machine replacement.
- Let's Encrypt permits **5 duplicate certificates per exact name set per week,
  global across all accounts**.

A certificate written to the filesystem would be reissued on every boot, and a
few deploys would exhaust the weekly limit and lock the demo out for a week. It
would fail silently at first and bite hardest during exactly the iteration that
caused it. The ACME account credentials carry the same risk for the same reason:
registering a fresh account per boot is separately rate limited.

FoundationDB is already durable, already reachable from guard's context, and
survives machine replacement rather than merely restart. It also means several
engine instances share one certificate rather than each ordering its own, which
would hit the same limit from a different direction.

Guard takes its own subspace, `(RIVET, GUARD)`, rather than borrowing
pegboard's, whose root is scanned and cleared wholesale by orchestration GC.
Every value stored is an opaque blob — a PEM chain, a PEM key, the ACME account
credentials in the client's own encoding — so nothing here needs a versioned
schema. Expiry is parsed back out of the certificate rather than stored beside
it, which is what keeps that true.

### The resolver starts empty

HTTP-01 cannot complete until the plain HTTP listener is answering challenges,
but the QUIC listener only spawns when a resolver already exists. Those two
orderings conflict.

Resolved by handing back a resolver immediately, backed by a slot that is
initially empty. Both listeners bind, handshakes fail cleanly until a
certificate arrives, and issuance swaps one in from a spawned task. A
certificate already in the store is loaded inline before the resolver is
returned, so a restart serves immediately and orders nothing.

### Local development needs no certificate authority

The deployed path needs a real certificate, but the demo is built and proven
locally long before it is deployed, and there a certificate authority is
unnecessary.

A self-signed certificate that Guard serves is accepted by Chromium through the
`--ignore-certificate-errors-spki-list=<hash>` launch flag, where the hash is
the SHA-256 of the certificate's public key. That is a different mechanism from
WebTransport's `serverCertificateHashes`, which pins the certificate rather than
the key and is refused above two weeks of validity. The launch flag has no such
limit, so `self-host/webtransport/gen-cert.sh` is enough.

Two constraints make it work. The page must be served over `http://localhost` or
another secure context, because `WebTransport` is undefined on a `file://` or
`data:` origin. And the client must force QUIC to the server with
`--origin-to-force-quic-on`, or Chromium never attempts it and the failure reads
as a server fault.

This is what the Playwright MCP is configured for, in
`~/.config/rivet-wt/playwright-mcp.json`: the bundled Chromium, the two flags,
and `file://` navigation left blocked in favour of a local HTTP server. A real
browser then drives the demo with no ACME in the loop, which is why issuance is
off the critical path for building it.

### The QUIC listener needs its own bind address

Fly is explicit:

> `0.0.0.0`, `*`, and `INADDR_ANY` generally won't do: Linux will use the wrong
> source address in replies.

Guard bound `0.0.0.0` for both listeners, so on Fly the UDP socket would exist
and never see a packet. `guard.https.quic_host` now overrides the QUIC bind
address only, resolved as a hostname so `fly-global-services` works directly.
The TCP acceptor is unchanged.

## What is verified

Against a local debug build:

```
message="loaded TLS certificate" cert_path=.../api.crt
message="TLS certificate resolver configured"
message="HTTP/3 server listening" addr=0.0.0.0:16443
```

and `addr=127.0.0.1:16444` with `quic_host` set, which is the behaviour Fly
requires. Twenty-two tests pass in `rivet-guard`, covering the empty slot, a
certificate swapped in after startup, malformed and missing inputs erroring
rather than silently disabling TLS, and the key layout.

The resolver is also proven above the unit level: a real browser completed a
WebTransport handshake against the release image using this resolver and a
self-signed certificate, accepted through Chromium's SPKI-list flag. So the TLS
path serves QUIC, not only HTTPS. See
[RFD 0007](0007-webtransport-in-guard.md).

## Not verified

- **Issuance.** No certificate has been ordered. The ACME client, the
  `/.well-known/acme-challenge/` route, and the single-flight lock are not
  written.
- **UDP end to end on Fly.** A dedicated IPv4, `37.16.24.183`, is now allocated
  ($2/month), and `self-host/fly/engine/fly.toml` declares the UDP service on
  443 with `quic_host = fly-global-services`. What remains unverified is the
  deploy itself: `flyctl ssh console --command "ss -ulnp"` should show UDP 443
  bound to the `fly-global-services` address, and that check needs a certificate
  in place first, because Guard skips the QUIC listener when no resolver exists.
- **That a restart orders nothing.** This is the behaviour protecting the rate
  limit, so it deserves an explicit test rather than an assumption.

## Consequences

Guard now owns durable state, which it did not before. That is a small widening
of its responsibility and the reason it got its own subspace rather than a
corner of someone else's.

Certificate issuance becomes a startup-time dependency on an external service.
It is deliberately not fatal: a missing or unreachable ACME service leaves the
listeners bound and failing handshakes, rather than preventing the engine from
starting.

## Open questions

- [ ] Where does the single-flight lock's TTL land? An order takes tens of
      seconds, and a lock that expires mid-order is how duplicate certificates
      get issued. Minutes, not seconds, but the number is unchosen.
- [ ] Should a stored certificate near expiry be served while a renewal runs, or
      should renewal block? Serving stale-but-valid is almost certainly right.
- [ ] `CertResolver::resolve` returns `None` when a client sends no SNI, so
      `https://<ip>/` cannot work. Browsers always send SNI, so this is only a
      problem for IP-addressed clients. Worth relaxing separately.

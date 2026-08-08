# RFD 0007 — WebTransport in Guard

## Status

Partially implemented on the fork's `webtransport` branch. Steps 1 to 4 done,
5 to 8 open. Was issue #5.

The plan of record is `engine/packages/guard-core/WEBTRANSPORT.md` on that
branch. This RFD records verified status, not intent.

## Problem

Give Guard a WebTransport surface so a client reaches an actor over QUIC rather
than TCP. Head-of-line blocking then applies per stream instead of per
connection.

## Why WebTransport rather than WebSocket over HTTP/3

`zone-client-godot` is a web and WASM build. A browser cannot open a WebSocket
over HTTP/3 from JavaScript, which is what RFC 9220 defines, so that route
excludes the web client. A browser can open a WebTransport session.

WebTransport also carries datagrams as well as streams, so a pose stream has a
path later without a second transport change.

A WebTransport bidirectional stream carries WebSocket framing, so Guard's
internals keep their shape and QUIC sits underneath. The tunnel between Guard
and an actor is WebSocket-shaped in both directions, so a reliable ordered
stream over QUIC needs no new tunnel frame type and no `container-runner`
change. Unreliable datagrams are a separate, later project.

## Status, verified against the branch

Checked against code rather than taken from the plan document.

| Step | Status | Evidence |
|---|---|---|
| 1. Erase the transport in `WebSocketHandle` | Done | `websocket_handle.rs:22` is `pub type WebSocketReceiver = Peekable<BoxedWsStream>`; `:26` is a boxed `Sink`; `from_stream<S>` accepts any `WebSocketStream<S>` |
| 2. Workspace QUIC dependencies | Done | `[workspace.dependencies.quinn]`, `h3-quinn`, `h3-webtransport` in the root manifest, all wired into `guard-core` |
| 3. QUIC endpoint with ALPN `h3` | Done | `guard-core/src/h3_server.rs` exports `ALPN_H3`, `quic_server_config`, `run_h3_listener` |
| 4. WebSocket framing over a bidi stream | Done | `BidiStream` already implements `AsyncRead`/`AsyncWrite`, so no adapter was needed |
| 5. Route into `ProxyService` | **Not done** | `grep -rn serve_custom_websocket engine/packages/guard-core/src/` returns nothing |
| 6. Bind the listener in `run_server` | **Not done** | `run_h3_listener` has no call sites outside its own module and the `lib.rs` re-export |
| 7. Godot demo | Partial | see below |
| 8. Measure against the 15.6 ms tick | Not done | |

The transport plumbing exists and compiles. Nothing is wired into the request
path.

## The coupling point, and why it was boxed

`websocket_handle.rs` originally hardcoded the transport in two type aliases
over `WebSocketStream<TokioIo<Upgraded>>`. `WebSocketHandle` appears 66 times
across `guard-core`, `pegboard-runner`, `pegboard-gateway2`, and the Rust SDKs,
so making the handle generic would have reached all 66 sites.

Boxing the split halves keeps the public API identical and confines the change
to one file. The cost is one dynamic dispatch per message, which is noise
against a network hop.

## The remaining seam

Step 5 is the substantial piece and the plan documents it exactly.
`handle_websocket_upgrade` performs the hyper upgrade at the top, which a
WebTransport stream cannot supply, so the seam must sit after it. The actor path
is the `CustomServe(handler)` arm; its spawned async block should be extracted
into a crate-visible function taking the handle as a parameter rather than
constructing one internally. The TCP path then passes
`WebSocketHandle::new(client_ws)` and the HTTP/3 path passes
`WebSocketHandle::from_stream(ws_stream)` from step 1.

Steps 5 and 6 should land together. Extracting the function is only useful once
something calls it, and the UDP bind is only useful once the seam exists.

## Step 7, and a correction

The demo actor at `container-runner/examples/godot-demo` was taken from "never
executed" to verified running. Its README had recorded *"Nothing here ran"* and
flagged two uncertainties, both now resolved by running it:

- `WebSocketPeer.accept_stream` inside the polling loop works; a raw handshake
  returns `101 Switching Protocols` and the echo comes back.
- `_cmds.root` resolves usefully under `--script`, where there is no
  `current_scene`; MCP `tools/list` returns the full tool catalog.

It was deployed and answered a live MCP call through Rivet's gateway.

**That run used an upstream godotengine.org build, which was a mistake.** The
fork's runtime is double-precision and is not interchangeable; see
[RFD 0004](0004-image-provenance.md). The image reference has been corrected,
but the end-to-end run has **not** been repeated against the double-precision
build. Treat it as proving the actor, readiness, and gateway routing, not the
zone itself.

What remains for step 7 is the WebTransport client, which the pinned engine
supplies through `WebTransportPeer`.

## Step 8

`container-runner/examples/e2e-test/load-test.mjs` reports `p50`, `p95`, `p99`,
and `max`. The target is `p95` against the 15.6 ms tick.

A local cluster is now reproducible ([RFD 0002](0002-allocate-addresses.md)), so
the harness has somewhere to run. The plan's requirement that measurement come
from a real client network rather than from inside the datacenter still stands
and is **not** satisfied by a local run.

## Upstream

As of 2026-08-08 upstream Rivet had no open PR or issue for WebTransport, QUIC,
or HTTP/3, no branch matching those names across 1042 branches, and no `quinn`
or `h3` entry in any workspace manifest. Every `webtransport` path in the
upstream tree belongs to Unity's vendored `SimpleWebTransport`, which is a
WebSocket library. There is nothing to rebase onto.

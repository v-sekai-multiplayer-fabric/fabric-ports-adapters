# RFD 0007 — WebTransport in Guard

## Status

Steps 1 to 6 done on the fork's `webtransport-datagrams` branch, plus a
datagram transport and per-stream routing that were not in the original plan.
Both transports are proven end to end against the release engine image: a
headless Chromium opened a WebTransport session and got a reply on both a
reliable stream and an unreliable datagram. Steps 7 and 8, the ShaderMotion
demo and the measurement, are open. Was issue #5.

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
| 5. Route into `ProxyService` | Done | `serve_custom_websocket` extracted from the `CustomServe` arm; `ProxyServiceFactory::serve_webtransport` resolves a route from the CONNECT request |
| 6. Bind the listener in `run_server` | Done | `run_h3_listener` spawned on the HTTPS port over UDP; logged `HTTP/3 server listening addr=0.0.0.0:16443` on a live process |
| 7. Godot demo | Partial | the zone speaks MCP over WebSocket; no WebTransport client exists |
| 8. Measure against the 15.6 ms tick | Not done | |

The listener binds and reaches actors, and both channel types answer a real
browser.

### Verified against a real browser and the release image

A headless Chromium, launched with `--origin-to-force-quic-on` and the
certificate's SPKI hash, ran against the engine's release Docker image, not a
`cargo` debug build:

- **Reliable, over a stream.** The stream sent its 2-byte length plus path
  header, then a WebSocket-framed `ping`, and read back `pong`. Guard logged the
  session, the route resolution, and the `CustomServe` dispatch.
- **Unreliable, over a datagram.** The stream sent a header carrying
  `rivet_unreliable=1`, then the payload travelled as a session datagram. Guard
  logged `received a datagram len=...` and answered.

A live page pinging each channel at 10 Hz held zero loss on loopback, which is
expected there; the drop behaviour only shows under an impaired link.

One lesson worth keeping. The datagram path first appeared broken, and the fault
was the test, not the transport. A datagram carries raw application bytes with
no WebSocket framing, so a client must send raw bytes and a handler must accept
`Message::Binary`. The stream path parses framing, so the same hand-built frame
worked there and hid the mismatch. The two paths are not interchangeable at the
byte level, only at the `WebSocketHandle` level.

Two capabilities were added beyond the plan, because the plan's demo would not
have proved anything:

- **A datagram transport.** A connection whose target carries
  `rivet_unreliable=1` is served over QUIC datagrams instead of a stream.
  `WebSocketHandle` was already erased over its transport, so this fits behind
  it and nothing downstream knows. This is the only WebSocket-impossible
  capability, and the plan had deferred it as "a separate project".
- **Per-stream routing.** A session CONNECTs to one path, so one session would
  otherwise reach one actor. Each stream now names its target as a `u16` length
  plus path before framing begins, which is what lets one connection serve two
  zones and therefore share one congestion controller.

The channel model ended up as small as the requirement: **many reliable
channels, one unreliable**. A reliable channel is a bidirectional stream, which
QUIC already keeps ordered and free of head-of-line blocking against the others,
so reliable multiplexing was free. The unreliable channel is the session
datagrams, which need no framing because there is only one. An interim design
that added channel identifiers, sequence numbers, and RTP over QUIC framing was
reverted: nothing needed several unreliable channels, and the machinery was cost
without a caller.

### What blocked it for so long, and it was not the tunnel

The listener could not bind because `guard/src/tls.rs` returned `Ok(None)`
unconditionally, with the real implementation commented out since `6c92532ef`
(2025-10-21, a monorepo reorg). `guard-core/src/server.rs` spawns the QUIC
listener only when a certificate resolver exists, so no certificate meant no
HTTP/3, and the cause was in a file nobody would think to read.

The tunnel was assumed to be the obstacle and is not. `universalpubsub` has no
JetStream anywhere, so NATS core is already at-most-once; the reliability lives
above it as `ToServerWebSocketMessageAck` tracking for hibernation. In the end
no protocol change was needed at all, because unreliability is only required on
the client-to-Guard leg, which is the impaired one.

A datagram kind was added to **runner-protocol** v8 and then reverted: that
protocol does not reach a container actor, which speaks envoy-protocol. See
[RFD 0024](0024-prove-webtransport-with-shadermotion.md).

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

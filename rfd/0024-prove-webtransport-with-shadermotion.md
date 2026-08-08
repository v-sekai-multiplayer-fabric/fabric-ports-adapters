# RFD 0024 — Stream ShaderMotion to a VRM, and prove WebTransport doing it

## Status

Proposed. Nothing here is implemented, and nothing is measured.

Steps 1 through 6 of [RFD 0007](0007-webtransport-in-guard.md) are done. Steps 5
and 6 landed on the `webtransport-datagrams` branch: `serve_custom_websocket` is
extracted so any transport can drive a custom-serve handler,
`ProxyServiceFactory::serve_webtransport` resolves a route from the CONNECT
request, and `run_h3_listener` is bound on the HTTPS port over UDP. The QUIC
listener is reachable rather than merely compiled.

Steps 7 and 8 are not done, and neither is the tunnel work below.

Modelled on [RFD 0022](0022-glb-to-godot-scene.md), which keeps the asset
conversion path and no longer describes a demo.

## Problem

[RFD 0007](0007-webtransport-in-guard.md) chose WebTransport, and the
demonstration built for it ended up speaking WebSocket. Two commits took it
there, `d279c34b7` and `1ae56caa3`, because with routing unwired there was no
WebTransport path to demonstrate against.

That leaves the transport unjustified, and the obvious fix is worthless. Running
the existing MCP surface over a WebTransport stream proves nothing, because **a
WebTransport bidirectional stream is reliable and ordered, exactly like a
WebSocket**. Moving MCP onto one is a port, not evidence.

The demo has to do something WebSocket cannot do, or the transport work is
unmotivated.

### Independent streams alone do not clear that bar

The usual pitch is a bulk transfer on one stream and control traffic on another,
with no head-of-line blocking between them. A client can open two WebSockets,
get two TCP connections, and have the same isolation. Cheaper is not impossible.

That objection holds only while the two flows are considered separately. Put
them on one bottleneck and it fails, which is the design below.

### Unreliable datagrams do

WebSocket has no unreliable mode. Not a flag, not an option, not a workaround,
because it is defined over a reliable ordered byte stream.

At a 15.6 ms tick a pose that arrives late is worse than useless, because a
newer one has already superseded it. TCP cannot know that. It retransmits the
stale pose and holds every fresher pose behind it until the retransmission
lands, so loss becomes latency for the whole stream and the avatar stalls
instead of degrading. Discarding late data is the feature.

## Decision

One viewer, two actors, one deliberately constrained downlink.

- **Zone A**, the asset zone, converts and streams a 100 MB VRM. This is the path
  [RFD 0022](0022-glb-to-godot-scene.md) documents, measured at 43 MB in 17 s.
- **Zone B**, the motion zone, receives ShaderMotion poses from a performer and
  broadcasts them.

The viewer receives both at once: it is downloading the avatar's model while
already receiving that avatar's motion. If the motion stutters until the model
lands, the experience is broken, and this is the ordinary case in social VR
rather than an edge case.

The contention is therefore at one client's downlink, with two actors behind it.
That is what makes the comparison fair: the same link, the same two flows,
changing only the transport.

## The cluster, end to end

```mermaid
flowchart TB
    subgraph perf["🖥️ Performer browser"]
        SC["🖵 desktop capture<br/>ScreenCapture.js"]
        CR2["✂️ region select<br/>Cropper.js"]
        MD["🔢 MotionDecoder.js<br/>frame → 40×45 slots"]
        SC --> CR2 --> MD
    end

    subgraph edge["🌐 Rivet edge"]
        GQ["🛡️ Guard — QUIC<br/>HTTP/3 + WebTransport"]
        GW["🔀 pegboard-gateway<br/>tunnel, needs datagram frame"]
    end

    subgraph zones["📦 Two zone actors"]
        ZB["🎞️ Zone B — motion<br/>broadcasts poses"]
        ZA["📦 Zone A — asset<br/>glb/vrm → RSCC scene"]
    end

    subgraph view["🥽 Viewer — zone-client-godot"]
        HU["🦴 godot-humanoid<br/>bone_swing_twists"]
        VRM["🧍 VRM rig"]
        HU --> VRM
    end

    subgraph engine["🧠 Rivet Engine + storage"]
        PB["📋 Pegboard<br/>lifecycle, exclusivity"]
        UDB["🗃️ UniversalDB"]
        FDB[("FoundationDB")]
        UDB --> FDB
    end

    MD -->|"~260 B datagram<br/>per frame"| GQ
    GQ --> GW --> ZB
    ZB -->|"pose datagrams"| GQ
    ZA -->|"VRM bytes, reliable stream"| GQ
    GQ ==>|"⚠️ one bottleneck<br/>tc netem"| HU

    PB -.-> zones
    zones -.-> UDB
```

The thick edge is the whole experiment. Both flows cross it, so whichever
transport carries them decides whether the bulk transfer can starve the motion.

## The frame path

```mermaid
sequenceDiagram
    participant P as 🖥️ Performer
    participant G as 🛡️ Guard QUIC
    participant B as 🎞️ Zone B
    participant A as 📦 Zone A
    participant V as 🥽 Viewer

    V->>A: asset_begin, VRM
    A-->>V: chunked RSCC, reliable stream

    loop every video frame
        P->>P: capture region → decode slots 0..129
        P->>G: datagram, ~260 B
        G->>B: tunnel datagram
        B->>G: broadcast pose
        G-->>V: datagram
        V->>V: slots → bone_swing_twists → VRM
    end

    Note over G,V: both flows share one bottleneck
    Note over V: measure frame latency during the transfer
```

## The client is a web page

Modelled on `container-runner/examples/godot-demo/web`, which
[RFD 0022](0022-glb-to-godot-scene.md) added following
`examples/raw-fetch-handler`. Two pages rather than one:

**Performer.** A source picker offering a recorded ShaderMotion video or a
desktop stream, the crop rectangle from `Cropper.js`, and a running frame
counter. It decodes locally and sends slots, not pixels.

**Viewer.** The VRM, a download progress bar for it, and a live latency readout
next to the 15.6 ms tick so the effect is visible rather than only plotted.

### Recorded video for the measurement, desktop stream for the demo

Both are worth having and they are not interchangeable.

A **recorded ShaderMotion video** is what the benchmark uses. Comparing
WebSocket against WebTransport requires identical motion in both runs, and a
recording replays byte for byte. A live source does not, so any latency
difference it showed would be confounded by the motion itself differing between
runs.

A **desktop stream** is the better thing to show a person, because the latency
is felt rather than plotted. It needs no motion capture and no pose estimator:
the screen is already displaying an encoded ShaderMotion texture, so capturing a
region of it captures motion data directly. `ScreenCapture.js` handles screen
geometry and `Cropper.js` the region selection, both already written.

Measure with the recording. Demo with the desktop stream.

## Why each choice

**ShaderMotion as the payload.** Per
`shader_motion_specification/frame_layout.md`, each frame is a **40×45 matrix of
real numbers between ±1**, and a humanoid occupies the first three columns, slots
0 through 129. Most slots hold swing-twist angles in XYZ, scaled from
[-180°, +180°] to [-1, +1]. **Every frame is a complete pose with no dependency
on the frame before it.** Nothing is a delta, so nothing is corrupted by a gap.

**Decode on the client, send slots.** 130 slots at 16 bits is roughly 260 bytes,
comfortably inside one QUIC datagram. That buys the property the whole
experiment rests on: no fragmentation, so a loss costs exactly one pose rather
than a partial frame that cannot be decoded at all. Sending video frames instead
would fragment, and a single lost fragment would discard the whole frame.

**A gap is self-healing.** The next frame is a full replacement, so a drop costs
one skipped pose and the avatar keeps moving. Over WebSocket the same loss is
retransmitted and every fresher pose queues behind a pose that is already
obsolete. The avatar stutters where it should have skipped.

**`godot-humanoid` as the rig.** It is GDScript and exposes `bone_swing_twists`
and `muscle_settings` in `humanoid_pose_calculator.gd`, which is **the same
swing-twist representation the ShaderMotion frame layout emits**. The two share
an author, lox9973, so they were built to meet, and a decoded slot matrix drives
the humanoid without an intermediate format.

**One session, not two.** A WebTransport session is established by a single
CONNECT to a single URL, and `RequestContext` routes on hostname plus path.
Streams inside a session carry no path, so one session resolves to one actor
unless the first bytes of each stream name their target. That demultiplexing
does not exist yet, and it is the mechanism rather than optional framing: two
sessions would restore two congestion controllers and hand back the advantage
being measured.

**Two WebSockets do not rescue the baseline.** Two TCP connections are
independent at the transport layer and not independent on the wire. They share
the bottleneck queue, and every motion frame waits behind bulk bytes TCP has no
reason to treat as less urgent. The stall moves out of the transport into the
network path, where opening more connections cannot reach it. TCP offers no way
to say "this connection yields to that one", because priority across independent
connections is not something the kernel or the network can express. One QUIC
connection can: two streams, one congestion controller, and a sender that knows
motion outranks bulk.

## Prior art and licensing

| Piece | Where | License |
|---|---|---|
| Upstream ShaderMotion | `gitlab.com/lox9973/ShaderMotion`, since 2020 | MIT |
| Format specification | `shader-motion-navy-lead-ostrich/shader_motion_specification` | MIT, lox9973 |
| Reference decoder, JS | `MotionDecoder.js`, `HumanPoser.js` | MIT |
| Capture and crop, JS | `ScreenCapture.js`, `Cropper.js` | MIT |
| Original, C# | `blender-shader-motion` | MIT |
| Godot humanoid rig | `godot-humanoid` | Apache-2.0 |

Both licenses permit the port with attribution. These are `V-Sekai` and
`lox9973` repos rather than `v-sekai-multiplayer-fabric`, so upstream stays
read-only and anything written lands in the fabric org.

## The claim, stated so it can fail

On a shared bottleneck, WebTransport holds the viewer's frame-latency p99 near
the 15.6 ms tick while the VRM transfer saturates the link, and two WebSockets
cannot, at any connection count.

Cap the bottleneck with `tc netem` so Zone A's transfer saturates it, and add 2%
loss with 50 ms RTT, an ordinary mobile network rather than a pathological one.
`container-runner/examples/e2e-test/load-test.mjs` already reports `p50`, `p95`,
`p99`, and `max`.

| | WebSocket, two connections | WebTransport, one session |
|---|---|---|
| Zone A VRM transfer | saturates bottleneck | saturates bottleneck |
| Viewer p99 during transfer | expected to climb with queue depth | expected flat near tick |
| Cross-flow priority | not expressible | stream priority, or datagrams |
| One lost frame | stutter, stale pose retransmitted | skip, next frame is a full pose |

If p99 stays flat on both, this RFD has disproved its own premise. That is worth
knowing, because [RFD 0007](0007-webtransport-in-guard.md) chose the transport
on this reasoning, and the tunnel work is only justified if the gap is real.

## Measured

Nothing. This RFD proposes an experiment and reports no results.

The only figures it leans on come from
[RFD 0022](0022-glb-to-godot-scene.md): 43 MB converted in 17 s with the zone at
43.8 MiB, which is the load Zone A generates.

## Not verified

- **The 260-byte frame size** is computed from the slot count in the
  specification at an assumed 16 bits per slot, not observed on the wire.
- **The 15.6 ms tick surviving the internal path.**
  [RFD 0007](0007-webtransport-in-guard.md) estimates 1 to 3 ms for four broker
  crossings and that estimate has never been measured. If it is wrong, the
  external transport is not the bottleneck and this experiment measures the
  wrong leg.
- **That `godot-humanoid` accepts ShaderMotion slots directly.** The
  representations match on inspection and share an author. No one has fed one
  into the other.

## What blocks it

QUIC is not the blocker. `h3_server.rs` already calls `.enable_datagram(true)`,
and `WebTransportSession` exposes `datagram_reader` and `datagram_sender`.

The tunnel is, but less than first described, and the correction is worth
recording because it changes the cost.

**The transport underneath is already at-most-once.** `universalpubsub` has
memory, NATS, and postgres drivers, and there is no JetStream anywhere in the
package. NATS core does not retransmit, so nothing at that layer has to be
persuaded to drop.

**The reliability lives above it.** The tunnel adds its own acknowledgement
layer for hibernation: `ToServerWebSocketMessageAck` in the v7 schema, tracked
in `shared_state.rs` as `WebSocketMessageNotAcked` against
`gateway_hws_message_ack_timeout_ms`. That is what makes a WebSocket message
survive an actor hibernating, and it is what a datagram must bypass.

So the work is to add a message kind that is deliberately excluded from ack
tracking, not to build a new delivery mode through a broker that refuses to drop
things. The broker already drops things.

Two further facts for whoever picks this up. The protocol is versioned BARE at
`PROTOCOL_MK2_VERSION = 7`, so a new kind means a `v8.bare` schema with
field-by-field converters and a matching bump of the TypeScript
`PROTOCOL_VERSION`, per the repository's own rule against editing a published
schema. And `guard` depends on **both** `pegboard-gateway` and
`pegboard-gateway2`, so check which one carries a given deployment before
changing either.

The work, in order:

1. ~~Steps 5 and 6 of [RFD 0007](0007-webtransport-in-guard.md).~~ Done. The
   listener is bound and WebTransport streams route to actors.
2. A `v8.bare` datagram kind excluded from ack tracking, plus stream
   demultiplexing so one session reaches both zones.
3. The `MotionDecoder.js` port, and wiring it to `godot-humanoid`.
4. The measurement.

Step 2 is still the largest piece, mostly because a protocol version bump has to
be done properly rather than because the broker fights it.

## Deferred

**Datagrams for the VRM transfer.** Bulk transfer wants reliability and
ordering, and a reliable stream is the right carrier. Nothing here argues
otherwise.

**Many performers in one zone.** The demo is one performer and one viewer.
Broadcast fan-out is a separate question about zone capacity, not about
transport, and adding it would confound the measurement.

**Native client.** The viewer is `zone-client-godot` as a web build, because
that is what makes WebTransport necessary rather than optional. A native client
could use raw QUIC and would not exercise the same path.

## Consequences

A droppable tunnel path is the foundation for pose replication generally, not
only for this demonstration, which is the argument for paying for it once here.

It also puts a load-bearing dependency on an upstream format. ShaderMotion is
MIT and specified in-repo, so the risk is bounded, but the fabric org takes on a
port it has to maintain.

If the measurement comes out flat, the honest outcome is to keep WebSocket and
close [RFD 0007](0007-webtransport-in-guard.md) unimplemented.

## Open questions

- [ ] What bottleneck bandwidth makes the contention realistic rather than
      staged? Too tight and WebSocket fails trivially, too loose and neither
      transport is stressed.
- [ ] Datagrams only, or datagrams plus a reliable pose on join? A viewer
      arriving mid-stream has no pose until the next frame, which is roughly
      16 ms and probably fine, but it is unverified.
- [ ] Where does the decoder live so both the zone and a future native client
      can use it, given the reference is JavaScript and the rig is GDScript?
- [ ] Does the fork's double-precision runtime change any of the swing-twist
      maths? See [RFD 0011](0011-godot-runtime-provenance.md).

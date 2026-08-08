# RFD 0015 — Tooling constraints: no dependencies, deterministic tests

## Status

Accepted, implemented. Backfilled from decisions made while building the
bootstrap.

## Problem

This is a bootstrap tool. It runs before the cluster exists, on a machine that
may have nothing set up, and its job is to make the thing that everything else
depends on. Two properties follow from that, and both were arrived at by
hitting the alternative.

## Decision: no dependencies

`mix.exs` declares `defp deps, do: []` and means it.

Everything needed is in OTP:

- `JSON` for encoding and decoding, from OTP 27 onward
- `System.cmd/3` for driving `podman` and `systemctl`
- `Task` for timeouts

A bootstrap tool that cannot run until it has fetched packages has the same
chicken-and-egg problem as a cluster that cannot start until it knows its own
addresses. Keeping the dependency list empty means `mix test` works on a fresh
checkout with no network.

This is a real constraint and not a preference. Adding a dependency is allowed,
but it changes the character of the repo and should be a deliberate choice. See
[RFD 0006](0006-zone-baker-as-rivet-service.md), where taking `stage_runtime`
would be the first one, and where keeping the baker as a separate Mix
application avoids the question.

## Decision: tests do not touch the substrate

**Superseded by [RFD 0016](0016-collapse-the-substrate-port.md).** The Fake was
deleted with the port, so the bootstrap sequence is no longer covered. What
follows is retained because the reasoning still holds and would apply again if
the port returns.

`Adapters.Fake` implements the full substrate port in memory, so the entire
bootstrap sequence is exercised without podman.

This is what makes the sequence testable at all. The ordering failures in
[RFD 0002](0002-allocate-addresses.md) were found by running a real cluster,
which is slow and leaves state behind. With the fake, each is a test that runs
in milliseconds, and the fake deliberately models the split-cluster trap so a
regression fails a test rather than a deployment.

The suite dropped from 15 seconds to under 0.1 once static addressing removed
the sleeps it had been waiting on.

## Decision: flakes are root-caused, not retried

A test failed intermittently and passed on a fixed seed. The failure was a
named `Agent` surviving into the following test: `on_exit` runs after the test
process dies, so the next `start_link` could hit
`{:error, {:already_started, _}}`.

The fix was `start_supervised!`, which ties the agent's lifetime to the test
process and brings it down deterministically before the next test starts. Not a
retry, not a sleep, not a fixed seed.

Verified by running the suite across eight randomised seeds with zero failures.
Pinning the seed would have hidden it; retrying would have hidden it more.

## Applying this to configuration, not just code

The same rule catches redundant configuration, and it is easier to miss there
because the usual defence is that it "costs nothing".

When `foundationdb` became the fork's default feature, the explicit
`--features foundationdb` in `assets/engine/Containerfile` became redundant. The
argument for keeping it was that it documents the requirement where someone
would look when a build breaks. That is the same argument YAGNI rejects
everywhere else: it is duplicate state that can drift from the default, a second
place to update, and it reads as load-bearing when it is not. Removed, with a
comment stating that the fork selects the backend by default.

"It costs nothing" is not a reason to keep something. Nothing that is retained
costs nothing.

## Consequences

The suite is fast enough to run on every change and honest enough to be trusted
when it passes.

The cost is that the fake must stay faithful. A fake that drifts from the real
adapter turns green tests into false confidence, which is worse than no tests.
Anything the fake models — currently address assignment and cluster-file seeding
— has to be updated when the quadlet adapter's behaviour changes.

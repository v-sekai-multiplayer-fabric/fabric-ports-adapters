# RFD 0021 — When structure is justified

## Status

Accepted, applied. Backfilled: these limits were agreed and acted on before
being written down, and three RFDs already cite them without defining them.

## Problem

The manuals repository's RFD 0071 states YAGNI as a **timing** rule rather than
a frugality one:

> YAGNI is a timing rule, not a thrift rule. Building structure ahead of the
> feature that needs it spends an option and delays a return.

That is the right principle and it is not testable. "Near-term need" admits any
answer, so it cannot settle an argument about whether a particular abstraction
should exist. Three limits make it operational.

## The limits

**1. A need is near-term when a consumer exists today.**

Not planned, not committed, not scheduled. Written and running. A named future
consumer does not qualify, because that is the argument YAGNI exists to refuse.

**2. An interface needs three consumers.**

The classic rule of three. Two implementations is a coincidence; three is a
pattern. Test doubles do not count, which is the consequential part: an
in-memory fake is not a production consumer, however useful it is.

**3. The rule is retroactive. Audit and strip now.**

Not a gate on new work only. Existing structure with no current consumer is
removed rather than left until someone touches that file.

## What this has cost, concretely

Recording the price, because a rule that only ever felt good would be suspicious.

**The substrate port was deleted** ([RFD 0016](0016-collapse-the-substrate-port.md)).
It had two implementations, `Quadlet` and `Fake`, and the third was removed
earlier when the deployment target narrowed. 327 lines went, including
`test/bootstrap_test.exs`.

That forfeited the tests covering the ordering failures in
[RFD 0002](0002-allocate-addresses.md): three nodes forming three separate
clusters, the PID-1 signal that silently does nothing, and addresses surviving a
restart. Those behaviours are now verifiable only by creating real containers.
The concern was raised before the change and the decision reaffirmed, so it is a
known cost rather than an oversight.

**Five RFDs were removed** in `8788100`: 0005 (decomposing Uro into actors),
0006 (zone-baker), 0009 (cold storage tier), 0012 (actor-based indexing and
search), and 0020 (cross-actor transactions). Each contained real analysis. None
had a consumer. They are recoverable from git history.

**An index of the RFDs was removed** for the same reason, one step removed:
`rfd/README.md` restated every RFD's number, title, and status, all of which
already live in the files. It desynchronised three times, and each fix was
manual. A directory listing is generated; a hand-maintained table of the same
information is duplicate state that drifts silently, because nothing fails when
it is wrong.

The rule that catches this is the one in
[RFD 0015](0015-tooling-constraints.md): "it costs nothing" is not a reason to
keep something.

**Open questions went from 56 to 16**, and of those 16, 13 are tasks rather than
questions. Most of what looked like a design backlog was confident answers to
questions nobody had asked.

## The failure mode it caught

Worth recording because it was not obvious from inside.

Cross-actor transactions were designed four times, through four architectures:
declared impossible, then acquire-and-commit, then intents with a transaction
record, then a per-read opt-in that the code turned out to make unnecessary.
Each revision corrected a real error in the last. The work was good.

Nothing consumed any of it. The expected users were trades, gifting, and
ownership transfer, none of which exist. Four rounds of correct reasoning
produced nothing, and it only stopped because the rule was invoked.

An hour of careful thought did not notice. The rule noticed immediately. That is
the argument for having a rule rather than judgement.

## What the limits do not decide

They say when structure is justified, not whether an idea is good. A rejected
RFD with sound analysis is worth keeping if something specific would revive it,
which is why [RFD 0001](0001-substrate-port.md) survives its own supersession:
it records the shape to restore if a second production substrate appears.

The distinction is between *keeping an analysis* and *maintaining a backlog*.
The first is cheap. The second implies the questions are live.

[RFD 0001](0001-substrate-port.md) is the worked example: superseded by
[0016](0016-collapse-the-substrate-port.md) and kept, because a specific
condition would revive it. A second production substrate brings the port back,
and the shape to restore is written down. The five removed RFDs had no such
trigger.

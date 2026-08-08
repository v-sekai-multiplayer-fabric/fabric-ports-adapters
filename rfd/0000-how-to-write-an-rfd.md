# RFD 0000 — How to write an RFD

## Status

Accepted. This RFD describes itself.

## What an RFD is here

A record of a decision: what the problem was, what was chosen, and what it cost.
Written so that someone arriving later does not have to rediscover the same
thing by breaking it.

## What an RFD is not

**Not a manual.** If it explains how to use the thing, it belongs in the README
or in a docstring next to the code. An RFD explains why the thing is shaped the
way it is. `mix run -e '...'` is a manual; "addresses are allocated rather than
discovered, because a restart reassigns them" is an RFD.

**Not a status report.** "Currently we are working on X" rots within a week.
State what was decided and what is verified; if something is unfinished, say so
under Status and move on.

**Not a wish list.** An RFD with no problem statement is a feature request. Open
issues are fine inside an RFD, but they hang off a decision that has been made,
not in place of one.

## Structure

There is no template to fill in, but every RFD has at least:

```markdown
# RFD NNNN — Title

## Status
## Problem
## Decision
## Consequences
```

Add sections when the subject needs them. `Alternatives considered`,
`Open questions`, and `What is verified` earn their place often. Sections that
say nothing should be deleted rather than left empty.

### Status

One of: **Proposed**, **Accepted**, or **Accepted, implemented**. Add what was
actually verified and what was not. A status line that overstates is worse than
no status line, because the next person builds on it.

If the RFD was split out of another, or supersedes one, say so here with a link.

### Problem

What went wrong, or what could not be done. Concrete. If a failure was observed,
quote the failure — an error string is worth a paragraph of description:

```
Error: datacenter 'default' cannot have the `name` property set because it is
automatically derived from key
```

### Decision

What was chosen. Present tense, definite. Not "we could" or "it might be good
to".

### Consequences

What this costs, what it rules out, and what now has to be true. This is the
section people skip and later wish they had written. If the decision made
something worse as well as better, that belongs here.

## Rules

**One subject per RFD.** If the Decision section has two unrelated decisions in
it, split it. A useful test: could someone need one half without the other? If
so, they are two RFDs. Backup and cold-tier storage shared an S3 endpoint and
nothing else, and bundling them made a one-day task look like a quarter's work.

**Number monotonically, never renumber.** Numbers are addresses. When an RFD is
split, the new parts get new numbers at the end and the original is trimmed to
point at them. Existing links stay valid.

**Verify claims before writing them.** Prefer a command and its output to a
recollection. Where a claim could not be verified, say which:

> Not verified: the engine and godot-zone images have not been built or run
> here.

**Record the wrong turn when it was expensive.** An RFD that only states the
final answer teaches nothing about why the obvious approach fails. Three
different attempts at coordinator bootstrap failed silently before the fourth
worked; that history is the most useful part of
[RFD 0002](0002-allocate-addresses.md), not an embarrassment to trim.

**Correct in place, and say so.** When something turns out to be wrong, edit the
RFD and name the correction rather than quietly deleting it. "An earlier draft
of this RFD said X. That was wrong, because Y." The reader needs to know the
earlier reasoning was considered and rejected, not merely absent.

**Link rather than repeat.** A fact should live in one RFD. Others reference it.

## Style

Plain sentences. No em dashes. Lowercase log messages and identifiers as they
appear in the code. Tables where a comparison is genuinely two-dimensional, not
as decoration.

Write for someone competent who was not there. Assume they can read code and
cannot read minds.

## Numbering

`rfd/NNNN-kebab-case-title.md`, four digits, allocated in order. This one is
0000 because it is about the process rather than the system.

`rfd/README.md` indexes them, split by whether they are implemented or proposed.
Update it in the same change that adds an RFD.

---
name: stack-layers
description: Decide whether a piece of work should ship as a stack of dependent pull requests, and if so where the layer boundaries go. Use when a plan has several implementation units, when a branch has grown past comfortable review size, or when a stackup hook has just asked the question. Also use when a stack needs restacking after review, or when it is time to land one.
---

# Stack or one pull request

`gh stack` builds a chain of pull requests that each build on the one below.
The bottom targets the trunk. Reviewers read one focused change at a time
instead of one large one.

This skill answers **whether to stack and where the layers go**. It does not
teach the commands — `gh stack --help` is authoritative, and
`ce-commit-push-pr` already carries verified command semantics, submission, and
landing.

## The decision

Stack when the work splits into steps that are **each reviewable on their own**
and **must land in order**. The test is whether a reviewer could approve the
bottom layer without reading the top one. If yes, the boundary is real.

Ship one pull request when any of these hold:

- The change is one logical change. Splitting it produces layers that only make
  sense together.
- The only available split is by file or by mechanical batch, not by meaning.
- Every layer would need the others to be understandable.
- The whole change is small enough to read in one sitting.

**"One pull request, because this is one logical change" is a correct answer.**
A forced stack is worse than no stack: it costs the reviewer more context, not
less, and `ce-commit-push-pr` refuses artificial slices for that reason.

## Where the boundaries go

Good layers, bottom to top:

1. Foundation first — types, schema, config, or the interface everything else
   consumes.
2. Then the behavior that uses it.
3. Then the surface that exposes the behavior.

A layer must be coherent against its parent and must not depend on anything
above it. Prefer whole-file groups and existing commit boundaries. Do not split
a single file into layers with partial staging — that produces layers that do
not build.

Keep the count honest. Three well-chosen layers beat seven thin ones.

## Deciding at plan time

This is the cheap moment. A plan already knows its implementation units and
their dependencies, so the layer boundaries are usually visible without
re-reading any code. Record the decision in the plan — the layers in dependency
order, or the reason the work is one pull request — so the person implementing
it does not have to re-derive it from a finished diff.

Slicing a completed change into layers afterwards is harder and less honest,
because the commits were never built that way.

## After review

Changing a lower layer changes what every layer above it is based on, so the
stack needs restacking. `gh stack` does the cascade; the thing to watch is that
a rebase conflict leaves the stack mid-flight. Resolve it before pushing again.

## Landing

A stack lands as a unit. The whole chain merges in one all-or-nothing
operation with a chosen merge method, so a squash preference survives without
forcing a restack of the layers above. Do not merge the bottom layer by hand
and then repair the rest.

## When the repository does not support it

Some repositories do not have stacked pull requests enabled. `gh stack` reports
that plainly. Ship the single pull request and move on — this is not a failure
worth working around.

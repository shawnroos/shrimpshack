---
title: "A filter applied after the page limit reports nothing found"
date: 2026-09-23
module: plugins/work
problem_type: logic_error
component: api_layer
severity: high
category: logic-errors
symptoms:
  - "the candidate list came back empty while matching issues existed in Linear"
  - "the emptiness was indistinguishable from a genuinely empty result, and the skill's own text tells the reader not to widen out of it"
  - "every test passed: each fixture page held fewer rows than the limit, so the discarded rows never displaced a match"
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
tags: [pagination, filtering, linear-api, false-empty]
---

# A filter applied after the page limit reports nothing found

## Problem

`/work:bind` asks Linear for a page of candidate issues, then narrows them to the team the session declared. The narrowing ran on the answer. Linear had already chosen which issues to return, so a page filled with another team's issues left nothing after filtering — and the list reported no candidates while the matching issues sat on the next page, unasked for.

## Symptoms

- An empty candidate list in a session whose team plainly has open issues.
- Nothing in the output distinguishes "none match" from "none survived the filter", and the skill tells the reader that an empty list is not a reason to widen the search.
- The whole suite stayed green. Every fixture page held fewer rows than the limit, so discarded rows never pushed a match off the page — the arithmetic that causes the bug never happened in a test.

## What Didn't Work

- **Filtering harder.** The filter was correct. Applying it to a page that was already chosen is what made it wrong.
- **Trusting the test count.** 930 passing tests did not touch the interaction between the page limit and the filter. The bug lives in the relationship between two things that each work.

## Solution

Put the narrowing where the page is chosen — in the query's own filter — and keep exactly one comparison in the code:

```
# before: the server picked a page, then we discarded rows from it
q = issues(first: $n, filter: {project: {id: {eq: $p}}})
rows | _inside_context          # team dropped here

# after: the server picks a page of rows already inside the context
q = issues(first: $n, filter: {project: {id: {eq: $p}}, team: {id: {eq: $t}}})
rows | _inside_context          # still the single guard, now rarely excluding
```

The client-side guard stays. It is the one place the context question is answered, and it still catches anything the server filter cannot express. What changes is that the page is no longer spent on rows that were never eligible.

## Why This Works

A limit and a filter compose in one order only. Filter-then-limit answers "the first N things you want"; limit-then-filter answers "whatever survives of the first N things you were given", which is a different question and has no stable answer. Moving the predicate to the side that owns the limit is the only version that cannot silently under-report.

## Prevention

- When a result set is both **limited** and **filtered**, check which side applies each. If the limit is applied first, the filter can only ever shrink a page someone else chose.
- A false empty is worse than an error: it reads as a fact about the world. Where a filter can empty a list, the emptiness needs to be distinguishable from "nothing exists", or the filter belongs upstream.
- Test the interaction, not each half: fill a page to the limit entirely with rows the filter rejects, and assert that a matching row beyond the page is still found. Both halves passing their own tests is exactly the state this bug ships in.

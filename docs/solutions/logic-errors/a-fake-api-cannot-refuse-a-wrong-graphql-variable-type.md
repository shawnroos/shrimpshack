---
title: "A fake API cannot refuse a wrong GraphQL variable type"
date: 2026-09-15
module: plugins/work
problem_type: logic_error
component: verification
severity: high
category: logic-errors
applies_when:
  - "a query is written against a fake that routes by body text and prunes by selection set, and no test ever sends it to the real endpoint"
  - "a variable is declared `String!` for an argument whose comparator type is `ID` (Linear's `IDComparator`), or any other type the schema spells differently from the value's shape"
  - "you are about to add a query to `plugins/work/lib/linear.sh` or `plugins/work/bin/` that the existing probe transcript does not cover"
symptoms:
  - "every bats test green, the live snapshot for a bound space reports `linear.status: unavailable` with an empty board (2026-09-15, `plugins/work/bin/work-snapshot.sh` team-states query)"
  - "the real API answers `Variable \"$id\" of type \"String!\" used in position expecting type \"ID\"` with `GRAPHQL_VALIDATION_FAILED`, which `herdr_linear::query` maps to unavailable, so the failure looks like an outage"
tags:
  - fake-linear
  - graphql-validation
  - variable-type
  - probe-transcript
  - false-green
---

## Context

`plugins/work/tests/fixtures/fake-linear.sh` stands in for curl. It routes a request by substrings of
its body and prunes a canned response down to the selection set the query asked for. That
proves the credential path and the field set. It knows nothing about GraphQL *types*: a
query that declares `query($id:String!){teams(filter:{id:{eq:$id}}…` is served the same
canned states as the correct `query($id:ID!)`.

`plugins/work/bin/work-snapshot.sh` shipped the `String!` spelling. Twenty-five snapshot tests passed.
The first run against a real bound space came back `linear.status: unavailable` with no
groups, because Linear refuses the query before executing it and the plugin's error mapper
reads `GRAPHQL_VALIDATION_FAILED` as an unreachable API.

## The fix shape

1. Declare the variable with the type the schema names for that argument (`ID!` for an
   `IDComparator`). The type is in the probe's introspection output, not in the fake.
2. Teach the fake the refusal you observed, as a captured body: the `teams(` arm in
   `fake-linear.sh` now answers the real `GRAPHQL_VALIDATION_FAILED` envelope when the body
   carries `$id:String!` together with `{id:{eq:$id}}`, and `plugins/work/tests/unit/fake-linear.bats` pins both
   spellings. Reverting the script's type turns five snapshot tests red.
3. Run the real read once before calling the unit done. `bin/work-snapshot.sh <bound space>`
   against the live API is a read-only smoke and takes seconds; it is the only check that
   sees the schema.

## Why the fake cannot be made to catch the class

The fake would need the schema to validate types, and then it would be a second Linear.
It can only encode refusals someone has observed. So the rule is not "make the fake
stricter"; it is "every new query gets one real-API run, and every refusal that run
surfaces becomes a fake arm and a test". `plugins/work/tests/probe/customviews.sh` is where such runs
are recorded; its transcript is the source of the field names and types the libraries use.

## Prevention

Before declaring a new Linear query done: (a) find its argument types in the probe
transcript or add them there; (b) run the read against the real endpoint once from a
worktree; (c) if the endpoint refuses anything, add the captured refusal to the fake and a
test that sends both the wrong and the right spelling.

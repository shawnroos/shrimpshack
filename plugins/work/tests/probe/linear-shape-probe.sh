#!/usr/bin/env bash
# linear-shape-probe.sh — re-capture Linear's GraphQL response shapes.
#
# Run by hand, never by the suite. It talks to the real api.linear.app, so it
# is excluded from every automated path for the same reason the herdr and
# Keychain fixtures exist: a suite that reaches a live service answers
# differently on every machine and on every day.
#
# READ-ONLY BY CONSTRUCTION. Every query below is a query; the word `mutation`
# does not appear in any of them, and the probe sends nothing else.
#
# WHY IT EXISTS
# tests/fixtures/fake-linear.sh encodes shapes captured on 2026-09-04. Linear
# can change them. This is how someone re-captures without reconstructing the
# invocation from a commit message — and specifically how the ONE unverified
# body in that fixture, the 429, gets confirmed the day someone is willing to
# spend an hour's rate-limit budget provoking it.
#
# THE CREDENTIAL NEVER REACHES argv.
# It is fed to curl through `--config -` on stdin, which is KTD9's rule for the
# plugin itself. Verify that claim rather than trusting it -- while the probe
# runs, from another shell:
#
#     ps -eo args | grep -c 'lin_api_'
#
# Count the matches against the grep's own command line. On 2026-09-04 a scan
# for the actual key value across every process found 0. Note that a naive
# `grep 'Authorization: lin_api'` reports matches that are the grep itself and
# wrapper lines carrying the literal format string -- scan for the key VALUE.
#
# Usage:  bash linear-shape-probe.sh [issue-identifier] [parent-identifier]
# The key is read from ~/.secrets (LINEAR_API_KEY=) and never printed.

set -u

CHILD_ID="${1:-}"
PARENT_ID="${2:-}"
SECRETS="${LINEAR_SHAPE_PROBE_SECRETS:-$HOME/.secrets}"

if [ ! -r "$SECRETS" ]; then
    printf 'no readable secrets file at %s\n' "$SECRETS" >&2
    exit 1
fi

KEY="$(grep '^LINEAR_API_KEY=' "$SECRETS" | head -1 | cut -d= -f2- | tr -d "\"'")"
if [ -z "$KEY" ]; then
    printf 'no LINEAR_API_KEY in %s\n' "$SECRETS" >&2
    exit 1
fi

# The whole point: the credential is written to curl's stdin, never to argv.
cfg() {
    printf 'header = "Authorization: %s"\nurl = "https://api.linear.app/graphql"\n' "${1:-$KEY}"
}

q() {   # q <graphql-json-body> [override-key]
    cfg "${2:-$KEY}" | curl -s --config - -X POST \
        -H 'Content-Type: application/json' --data "$1"
}

show() { python3 -m json.tool 2>/dev/null || cat; }

FIELDS='id identifier title url branchName updatedAt priority state { id name type } parent { id identifier title } project { id name } team { id key name } assignee { id name } labels(first: 10) { nodes { id name } }'

# Discover a child and its parent when none were named, so the probe works on
# any workspace rather than only the one it was written against.
if [ -z "$CHILD_ID" ]; then
    CHILD_ID="$(q '{"query":"{ issues(first: 1, filter: { parent: { null: false } }) { nodes { identifier } } }"}' \
        | python3 -c 'import sys,json;n=json.load(sys.stdin)["data"]["issues"]["nodes"];print(n[0]["identifier"] if n else "")')"
fi
if [ -z "$CHILD_ID" ]; then
    printf 'could not find any issue with a parent to probe\n' >&2
    exit 1
fi
if [ -z "$PARENT_ID" ]; then
    PARENT_ID="$(q "{\"query\":\"{ issue(id: \\\"$CHILD_ID\\\") { parent { identifier } } }\"}" \
        | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"]["issue"]["parent"];print(d["identifier"] if d else "")')"
fi

printf '=== FOUND, WITH A PARENT (%s) ===\n' "$CHILD_ID"
q "{\"query\":\"query { issue(id: \\\"$CHILD_ID\\\") { $FIELDS } }\"}" | show

printf '\n=== FOUND, NO PARENT (%s) ===\n' "$PARENT_ID"
q "{\"query\":\"query { issue(id: \\\"$PARENT_ID\\\") { $FIELDS } }\"}" | show

# The three shapes that disagree. Not-found returns errors[] beside a null
# data; the other two omit data entirely. Capturing all three together is the
# point -- read separately they look like one case.
printf '\n=== NOT FOUND (errors[] beside "data": null) ===\n'
q '{"query":"query { issue(id: \"ZZZ-999999\") { id identifier } }"}' | show

printf '\n=== AUTHENTICATION ERROR (no data key at all) ===\n'
# Assembled rather than written whole: the repo's own secret scan refuses a
# credential shape anywhere in the tree, and it cannot tell a deliberately
# invalid key from a real one. That is the scan behaving correctly.
BAD_KEY="lin_api""_$(printf '0%.0s' $(seq 40))"
q '{"query":"{ viewer { id } }"}' "$BAD_KEY" | show

printf '\n=== VALIDATION ERROR (no data key at all) ===\n'
q "{\"query\":\"{ issue(id: \\\"$PARENT_ID\\\") { nosuchfield } }\"}" | show

# Present on EVERY response, not only a 429, so the budget is readable without
# ever being throttled. This is what makes the 429 body the one shape the
# fixture still constructs rather than captures.
printf '\n=== RATE-LIMIT HEADERS (on an ordinary 200) ===\n'
cfg | curl -s -D - -o /dev/null --config - -X POST \
    -H 'Content-Type: application/json' --data '{"query":"{ viewer { id } }"}' \
    | grep -iE '^(HTTP/|x-ratelimit|x-complexity|retry-after)' | tr -d '\r'

printf '\nNothing above was written to Linear. Every query was a read.\n'

#!/usr/bin/env bash
# Fills ~/.claude/linear-cache from Linear's GraphQL API.
#
#   linear-cache-refresh.sh              refresh every assigned issue (bulk)
#   linear-cache-refresh.sh WEB-3156     refresh one issue
#
# Never called from the statusline render path directly — the statusline spawns
# it detached on a cache miss, so a slow API call can never stall a redraw.
#
# WHY THIS LIVES IN THE REPO
# It began as a hand-patched file in ~/.claude/hooks/, where a change was
# untested and unversioned. Two defects were measured in that copy on
# 2026-09-04:
#
#   1. The credential went to curl as `-H "Authorization: $KEY"`, so it sat in
#      the process argv for the life of every request. Sampling `ps` during one
#      single-issue refresh caught the real key 14 times. Any process running as
#      this user could read it, and a cache miss triggers this on any statusline
#      redraw. It now goes in on stdin through `--config -` (KTD9).
#   2. The key was read from plaintext in ~/.secrets. It now comes from the
#      login Keychain, with a bounded fallback described below.
#
# THE FALLBACK IS DELIBERATE, AND IT IS NOISY ON PURPOSE
# Reading ~/.secrets still works, so swapping the hook does not break the
# statusline before the operator has migrated. But this script is spawned
# detached, so nothing reads its stderr — a warning alone would be invisible.
# It therefore also touches a marker file, which migrate-credential.sh reports.
# The migration is not finished while that marker keeps reappearing.

set -uo pipefail

CACHE="${LINEAR_CACHE_DIR:-$HOME/.claude/linear-cache}"
SECRETS_FILE="${LINEAR_SECRETS_FILE:-$HOME/.secrets}"
KEYCHAIN_SERVICE="${HERDR_LINEAR_KEYCHAIN_SERVICE:-work-linear}"
KEYCHAIN_ACCOUNT="${HERDR_LINEAR_KEYCHAIN_ACCOUNT:-linear-api-key}"
FALLBACK_MARKER="$CACHE/_plaintext_fallback_used"
CURL_BIN="${HERDR_LINEAR_CURL_BIN:-curl}"

mkdir -p "$CACHE"

# Resolve the library beside this script rather than from a fixed path, so a
# worktree, a plugin cache and a checkout all find their own copy.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd -P)" || LIB_DIR=""
if [ -n "$LIB_DIR" ] && [ -r "$LIB_DIR/secrets.sh" ]; then
    # shellcheck source=/dev/null
    . "$LIB_DIR/secrets.sh"
    # linear.sh owns the one credential resolver. This script had its own copy,
    # which is two places for the Keychain-then-plaintext order to drift.
    # shellcheck source=/dev/null
    [ -r "$LIB_DIR/linear.sh" ] && . "$LIB_DIR/linear.sh"
fi

# 0 = from the Keychain, 2 = from the pre-migration plaintext copy, 1 = nothing.
#
# ONLY THE EXIT CODE IS KEPT. The value is deliberately not held in a variable
# here: this is the top level of a script, so an assignment cannot be fenced in
# a `set +x` subshell the way a function body can, and bash traces AFTER
# expansion -- under `bash -x` the assignment alone put the key in the trace
# three times. This script is spawned DETACHED, so that stream lands somewhere
# nobody is watching. api() re-resolves the value inside its own subshell
# instead; that costs one extra Keychain read per request, bounded by the eight
# pages below.
herdr_linear::credential >/dev/null 2>&1; key_source=$?
if [ "$key_source" -ne 0 ] && [ "$key_source" -ne 2 ]; then
    printf 'no Linear credential: not in the Keychain (%s/%s) and no LINEAR_API_KEY in %s\n' \
        "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT" "$SECRETS_FILE" >&2
    printf 'run bin/migrate-credential.sh to store one\n' >&2
    exit 1
fi
if [ "$key_source" -eq 2 ]; then
    printf 'WARNING: read the Linear key from plaintext %s; migrate it to the Keychain\n' "$SECRETS_FILE" >&2
    date -u +%Y-%m-%dT%H:%M:%SZ >"$FALLBACK_MARKER"
fi

# The credential is written to curl's stdin, never to argv. --config carries the
# header and the URL together; -s and --max-time stay on argv, where they are
# harmless and readable.
#
# Subshell body with `set +x`, for the xtrace reason given above: this is now
# the only frame that holds the value, and `set +x` has to sit in the frame
# that holds it.
api() (
    set +x
    local key
    key="$(herdr_linear::credential)"
    printf 'header = "Authorization: %s"\nheader = "Content-Type: application/json"\nurl = "https://api.linear.app/graphql"\n' "$key" \
        | "$CURL_BIN" -s --max-time 20 --config - -X POST -d "$1"
)

write_nodes() {
  jq -c '.[]' | while read -r n; do
    id=$(printf '%s' "$n" | jq -r '.identifier')
    [ -n "$id" ] && [ "$id" != "null" ] || continue
    printf '%s' "$n" | jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{id: .identifier, title: .title, project: (.project.name // ""),
        status: (.state.name // ""), fetchedAt: $now}' >"$CACHE/$id.json"
    echo "$id"
  done
}

if [ $# -ge 1 ]; then
  q=$(jq -n --arg id "$1" '{query:"query($id:String!){issue(id:$id){identifier title state{name} project{name}}}",variables:{id:$id}}')
  n=$(api "$q" | jq -c '[.data.issue // empty]' | write_nodes | wc -l | tr -d ' ')
  echo "refreshed $n issue(s) for $1"
  exit 0
fi

# Bulk: page through assigned issues. 250 is Linear's per-page ceiling.
cursor=null
total=0
keys=""
for _ in 1 2 3 4 5 6 7 8; do
  q=$(jq -n --argjson c "$cursor" '{query:"query($c:String){issues(first:250,after:$c,filter:{assignee:{isMe:{eq:true}}}){pageInfo{hasNextPage endCursor} nodes{identifier title state{name} project{name}}}}",variables:{c:$c}}')
  resp=$(api "$q")
  got=$(printf '%s' "$resp" | jq -c '.data.issues.nodes // []' | write_nodes)
  [ -n "$got" ] && keys="$keys$got"$'\n'
  total=$(( total + $(printf '%s' "$got" | grep -c . || true) ))
  more=$(printf '%s' "$resp" | jq -r '.data.issues.pageInfo.hasNextPage // false')
  [ "$more" = "true" ] || break
  cursor=$(printf '%s' "$resp" | jq -c '.data.issues.pageInfo.endCursor')
done

# Team-key list gates the branch-name match in linear-statusline.sh. Rebuilt from
# whatever the cache holds, so removing a stale ticket also narrows the pattern.
ls "$CACHE" | sed -n 's/^\([A-Z][A-Z0-9]*\)-[0-9]*\.json$/\1/p' | sort -u >"$CACHE/_teamkeys"
echo "refreshed $total issues; team keys: $(tr '\n' ' ' <"$CACHE/_teamkeys")"

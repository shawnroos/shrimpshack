#!/usr/bin/env bash
# The only place that talks to Linear. Sourced, never executed.
#
# Everything that could go wrong at this boundary is centralised here on
# purpose: a second caller building its own request is a second chance to put
# the credential in argv, to write to an issue nobody bound, or to block a
# session start on an unreachable API.
#
# THREE BOUNDS THIS FILE ENFORCES
#
# 1. The credential never reaches argv (R27, KTD9). It goes to curl on stdin
#    through `--config -`. tests/fixtures/fake-linear.sh exits 98 if it ever
#    appears in an argument, so a regression fails the suite.
#
# 2. Writes are bounded in code, not by the credential (R30, KTD2). A personal
#    Linear key carries the whole account -- there is no scope to lean on. The
#    bound lives in the binding record: the bound issue, plus the children this
#    plugin created and recorded. That set is NEVER derived from Linear, because
#    a tracker-derived child list means anyone who can re-parent an issue can
#    move it into the writable set.
#
# 3. A read cannot hang a session (R14). Every call is bounded well inside the
#    hook's budget and answers "unavailable" rather than blocking.

HERDR_LINEAR_API_URL="${HERDR_LINEAR_API_URL:-https://api.linear.app/graphql}"
HERDR_LINEAR_CURL_BIN="${HERDR_LINEAR_CURL_BIN:-curl}"
HERDR_LINEAR_CACHE_DIR="${LINEAR_CACHE_DIR:-$HOME/.claude/linear-cache}"
HERDR_LINEAR_SECRETS_FILE="${LINEAR_SECRETS_FILE:-$HOME/.secrets}"
HERDR_LINEAR_KEYCHAIN_SERVICE="${HERDR_LINEAR_KEYCHAIN_SERVICE:-herdr-linear}"
HERDR_LINEAR_KEYCHAIN_ACCOUNT="${HERDR_LINEAR_KEYCHAIN_ACCOUNT:-linear-api-key}"

# Well inside a hook's budget. A session start that waits longer than this on a
# tracker has already failed at its job, which is to not be in the way.
HERDR_LINEAR_TIMEOUT_SECONDS="${HERDR_LINEAR_TIMEOUT_SECONDS:-8}"

# KTD5. The cache holds {id,title,project,status,fetchedAt} and nothing else --
# no parent, no team, no updatedAt. It answers the identity half of R12 and the
# rest always comes from the API, so the saving is one field-set, not one call.
HERDR_LINEAR_CACHE_MAX_AGE_SECONDS="${HERDR_LINEAR_CACHE_MAX_AGE_SECONDS:-3600}"

HERDR_LINEAR_RETRY_MAX="${HERDR_LINEAR_RETRY_MAX:-3}"
HERDR_LINEAR_RETRY_BASE_MS="${HERDR_LINEAR_RETRY_BASE_MS:-500}"

HERDR_LINEAR_OK=0
HERDR_LINEAR_UNAVAILABLE=1     # network, timeout, or a body we cannot read
HERDR_LINEAR_NOT_FOUND=2       # Linear answered, and there is no such issue
HERDR_LINEAR_AUTH=3            # the credential was refused
HERDR_LINEAR_RATELIMITED=4     # still limited after backing off
HERDR_LINEAR_REFUSED=5         # the plugin's own bound said no

# _post returns either curl's own exit code or this. It is deliberately outside
# curl's range: curl 3 means "malformed URL" and would otherwise be
# indistinguishable from the enum's AUTH, so "we have no key" and "the URL was
# wrong" would report as the same thing.
HERDR_LINEAR_NOCRED=90

# ------------------------------------------------------------- the credential

# One resolver, used by every reader including bin/linear-cache-refresh.sh.
# Exit 0 = from the Keychain, 2 = from the pre-migration plaintext copy, so a
# caller can report the fallback without re-deriving where the value came from.
herdr_linear::credential() (
    set +x
    local k=""
    if command -v herdr_linear::keychain_read >/dev/null 2>&1; then
        k="$(herdr_linear::keychain_read "$HERDR_LINEAR_KEYCHAIN_SERVICE" "$HERDR_LINEAR_KEYCHAIN_ACCOUNT" 2>/dev/null)" || k=""
    fi
    if [ -n "$k" ]; then printf '%s' "$k"; return 0; fi
    k="$(grep '^LINEAR_API_KEY=' "$HERDR_LINEAR_SECRETS_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"' \r')"
    [ -n "$k" ] || return 1
    printf '%s' "$k"
    return 2
)

# --------------------------------------------------------- branch to identifier

# KTD6. Shape match anywhere in the branch, case-insensitive, tolerating the
# missing hyphen -- the same shape linear-pin.sh already validates. No team list
# is consulted: ~/.claude/linear-cache/_teamkeys is derived from cached
# filenames and is already stale, so gating on it would reject real issues for
# teams that happen not to be cached. A non-existent identifier is settled by
# the fetch returning nothing, which is a correct answer rather than a guess.
herdr_linear::branch_identifier() {
    local branch="${1:-}" m
    [ -n "$branch" ] || return 1
    # TWO alternatives, hyphenated first. A single pattern with an optional
    # hyphen cannot do this: `[A-Z][A-Z0-9]{1,7}-?[0-9]{1,6}` against `web3045`
    # lets the letter class eat the digits and then backtrack one, yielding
    # WEB304-5 instead of WEB-3045 -- silently the wrong issue, on the plan's
    # own example. Hyphenated form allows digits in the team key (X2-14);
    # unhyphenated requires a letters-only key, because `X23045` cannot be split
    # correctly by any rule and guessing is worse than not matching.
    m="$(printf '%s' "$branch" \
        | grep -oiE '[A-Z][A-Z0-9]{0,7}-[0-9]{1,6}|[A-Z]{2,8}[0-9]{1,6}' \
        | head -1)" || return 1
    [ -n "$m" ] || return 1
    # Normalise to the canonical UPPER-NNN form Linear uses. The SAME two
    # alternatives as the match above, and for the same reason: one pattern with
    # an optional hyphen re-introduces the greedy split here even after the grep
    # gets it right, so WEB3045 normalises to WEB304-5. The bug has two sites.
    local norm
    norm="$(printf '%s' "$m" | tr '[:lower:]' '[:upper:]' \
        | sed -E 's/^([A-Z][A-Z0-9]{0,7})-([0-9]{1,6})$/\1-\2/; s/^([A-Z]{2,8})([0-9]{1,6})$/\1-\2/')"
    # sed prints its input unchanged when no pattern matches, so the function's
    # output would otherwise be default-allow: a branch like
    # `feature/ab12cd34-thing` could escape as the "identifier" AB12CD34 and go
    # to Linear as a lookup.
    #
    # KNOWINGLY UNREACHABLE TODAY, AND KEPT ANYWAY. Every string the matcher
    # above can produce is normalisable by one of the two sed rules, so no input
    # currently reaches this and mutating it away turns no test red. It stays
    # because the matcher and the normaliser are two patterns that have to agree
    # about the same grammar, and they have already disagreed once in this
    # file's history -- the greedy split was fixed in the grep and left in the
    # sed. This is what makes the next divergence fail closed instead of leaking
    # a malformed identifier. Do not read a green suite as evidence it fires.
    case "$norm" in
        [A-Z]*-[0-9]*) ;;
        *) return 1 ;;
    esac
    printf '%s' "$norm" | grep -qE '^[A-Z][A-Z0-9]{0,7}-[0-9]{1,6}$' || return 1
    printf '%s' "$norm"
}

# ------------------------------------------------------------------ the request

# The credential is written to curl's stdin. Nothing else in this file builds a
# request, so this is the single place that rule has to hold.
herdr_linear::_post() {
    local body="$1" key rc
    # credential answers 0 from the Keychain and 2 from the pre-migration
    # plaintext copy. BOTH are a usable key -- 2 is "here it is, and you should
    # know where it came from", not a failure. Treating any non-zero as auth
    # failure made every call fail while the migration is still outstanding,
    # which is the state the machine is in right now.
    key="$(herdr_linear::credential)"; rc=$?
    case "$rc" in
        0|2) ;;
        *) return "$HERDR_LINEAR_NOCRED" ;;
    esac
    [ -n "$key" ] || return "$HERDR_LINEAR_NOCRED"
    printf 'header = "Authorization: %s"\nheader = "Content-Type: application/json"\nurl = "%s"\n' \
        "$key" "$HERDR_LINEAR_API_URL" \
        | "$HERDR_LINEAR_CURL_BIN" -s --max-time "$HERDR_LINEAR_TIMEOUT_SECONDS" \
            --config - -X POST -d "$body"
    rc=$?
    return "$rc"
}

herdr_linear::_error_code() {
    printf '%s' "$1" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.stdout.write("MALFORMED"); sys.exit(0)
errs = d.get("errors") or []
if errs:
    sys.stdout.write(str(errs[0].get("extensions", {}).get("code", "UNKNOWN")))
else:
    sys.stdout.write("")
' 2>/dev/null
}

# A GraphQL query with bounded retry. Only RATELIMITED is retried: a validation
# error or a refused credential answers the same way every time, so retrying
# those only delays the failure.
herdr_linear::query() {
    local body="$1" resp code attempt=0 delay rc
    while :; do
        # A missing credential is not an unreachable API. Collapsing both into
        # "unavailable" would have a session report that Linear is down when
        # the real answer is that nothing is configured -- and the two need
        # opposite responses from whoever reads the message.
        resp="$(herdr_linear::_post "$body")"; rc=$?
        if [ "$rc" -ne 0 ]; then
            [ "$rc" -eq "$HERDR_LINEAR_NOCRED" ] && return "$HERDR_LINEAR_AUTH"
            return "$HERDR_LINEAR_UNAVAILABLE"
        fi
        [ -n "$resp" ] || return "$HERDR_LINEAR_UNAVAILABLE"
        code="$(herdr_linear::_error_code "$resp")"
        case "$code" in
            '')  printf '%s' "$resp"; return "$HERDR_LINEAR_OK" ;;
            MALFORMED)            return "$HERDR_LINEAR_UNAVAILABLE" ;;
            AUTHENTICATION_ERROR) return "$HERDR_LINEAR_AUTH" ;;
            INPUT_ERROR)          return "$HERDR_LINEAR_NOT_FOUND" ;;
            RATELIMITED)
                attempt=$(( attempt + 1 ))
                [ "$attempt" -ge "$HERDR_LINEAR_RETRY_MAX" ] && return "$HERDR_LINEAR_RATELIMITED"
                delay=$(( HERDR_LINEAR_RETRY_BASE_MS * attempt ))
                perl -e "select undef, undef, undef, $delay/1000" 2>/dev/null || sleep 1
                ;;
            *) return "$HERDR_LINEAR_UNAVAILABLE" ;;
        esac
    done
}

HERDR_LINEAR_ISSUE_FIELDS='id identifier title url branchName updatedAt priority state { id name type } parent { id identifier title } project { id name } team { id key name } assignee { id name } labels(first: 10) { nodes { id name } }'

herdr_linear::fetch_issue() {
    local id="${1:-}" body
    [ -n "$id" ] || return "$HERDR_LINEAR_NOT_FOUND"
    body="$(python3 -c '
import sys, json
print(json.dumps({"query": "query($id:String!){issue(id:$id){%s}}" % sys.argv[2], "variables": {"id": sys.argv[1]}}))
' "$id" "$HERDR_LINEAR_ISSUE_FIELDS")" || return "$HERDR_LINEAR_UNAVAILABLE"
    herdr_linear::query "$body"
}

herdr_linear::issue_updated_at() {
    local id="$1" resp rc
    resp="$(herdr_linear::fetch_issue "$id")"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["issue"]["updatedAt"])' 2>/dev/null
}

# ---------------------------------------------------------------- the cache

# A record past the freshness bound is a MISS, not a stale hit. Grounding a
# session in an hour-old status is worse than one extra API call.
herdr_linear::cache_read() {
    local id="${1:-}" f age fetched now
    f="$HERDR_LINEAR_CACHE_DIR/$id.json"
    [ -r "$f" ] || return 1
    fetched="$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("fetchedAt",""))' "$f" 2>/dev/null)" || return 1
    [ -n "$fetched" ] || return 1
    now=$(date -u +%s)
    age=$(python3 -c '
import sys, calendar, time
try:
    print(int(sys.argv[2]) - calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))
except Exception:
    print(10**9)
' "$fetched" "$now" 2>/dev/null) || return 1
    [ "$age" -le "$HERDR_LINEAR_CACHE_MAX_AGE_SECONDS" ] || return 1
    cat "$f"
}

# KTD5. Identity from the cache when it is fresh; parent, team and updatedAt
# always from the API, because the cache holds none of them.
herdr_linear::issue_context() {
    local id="${1:-}" cached api rc
    api="$(herdr_linear::fetch_issue "$id")"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    cached="$(herdr_linear::cache_read "$id" 2>/dev/null)" || cached=""
    HERDR_LINEAR_CACHED="$cached" python3 -c '
import sys, json, os
api = json.load(sys.stdin)["data"]["issue"]
cached_raw = os.environ.get("HERDR_LINEAR_CACHED") or ""
out = {
    "identifier": api.get("identifier", ""),
    "title": api.get("title", ""),
    "state": (api.get("state") or {}).get("name", ""),
    "project": (api.get("project") or {}).get("name", ""),
    "team": (api.get("team") or {}).get("key", ""),
    "parent": (api.get("parent") or {}).get("identifier", ""),
    "parent_title": (api.get("parent") or {}).get("title", ""),
    "url": api.get("url", ""),
    "updated_at": api.get("updatedAt", ""),
    "identity_from_cache": False,
}
if cached_raw:
    try:
        c = json.loads(cached_raw)
        # Identity only. The cache has no parent, team or updatedAt to offer,
        # and taking status from it would ground the session in a stale state.
        out["title"] = c.get("title") or out["title"]
        out["project"] = c.get("project") or out["project"]
        out["identity_from_cache"] = True
    except Exception:
        pass
print(json.dumps(out))
' <<< "$api"
}

# ------------------------------------------------------------ the write bound

# R30, KTD2. The writable set is the bound issue plus the children THIS plugin
# created and recorded. It is read from the binding record and never from
# Linear: asking the tracker which issues are children of the bound one would
# let anyone who can re-parent an issue move it into the writable set.
herdr_linear::write_allowed() {
    local worktree="${1:-}" target="${2:-}" rec
    [ -n "$target" ] || return "$HERDR_LINEAR_REFUSED"
    rec="$(herdr_linear::binding_read "$worktree")" || return "$HERDR_LINEAR_REFUSED"
    # The env assignment goes on python3, not on printf. Prefixing the first
    # command of a pipeline sets it for THAT command only, so the reader saw no
    # target, raised, and refused every write -- including the bound issue's own.
    # Three "refused" tests passed against that, for entirely the wrong reason.
    printf '%s' "$rec" | HERDR_LINEAR_TARGET="$target" python3 -c '
import sys, json, os
rec = json.load(sys.stdin)
target = os.environ["HERDR_LINEAR_TARGET"]
# Only a BOUND worktree may be written from at all. proposed, misplaced and
# stale are reported and wait for a person.
if rec.get("state") != "bound":
    sys.exit(1)
if target == rec.get("issue_identifier"):
    sys.exit(0)
sys.exit(0 if target in (rec.get("created_children") or []) else 1)
' || return "$HERDR_LINEAR_REFUSED"
    return "$HERDR_LINEAR_OK"
}

# KTD7. The guard is local to ONE pass: read updatedAt at the start, re-read it
# immediately before the mutation, and abort only when it moved in between.
# Never compare against a value stored in an earlier session -- Linear's own
# GitHub integration moves these issues, so a cross-session comparison would
# abort every write permanently and silently.
#
# It closes the read-modify-write window. It is not a distributed lock, and
# Linear offers no precondition that would make it one.
herdr_linear::guard_unchanged() {
    local id="${1:-}" opening="${2:-}" current rc
    [ -n "$opening" ] || return "$HERDR_LINEAR_REFUSED"
    current="$(herdr_linear::issue_updated_at "$id")"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    [ "$current" = "$opening" ] || return "$HERDR_LINEAR_REFUSED"
    return "$HERDR_LINEAR_OK"
}

# ------------------------------------------------------------------ slugging

# R28. Any Linear-derived name bound for a path, a branch or an argument is
# reduced to [A-Za-z0-9._-] and then REJECTED outright when the result would be
# dangerous rather than being repaired into something plausible: empty, `.`,
# `..`, or a leading hyphen (which every CLI reads as a flag) or dot (which
# hides the file). Repairing would silently produce a name nobody chose.
herdr_linear::slug() {
    local text="${1:-}" max="${2:-60}" raw out
    raw="$(printf '%s' "$text" | tr -c 'A-Za-z0-9._-' '-')"
    # Checked BEFORE trimming. Stripping the leading hyphens first and then
    # testing for them is a check that can never fire: `--rf` would quietly
    # become `rf`, which is exactly the repair this function must not perform.
    case "$raw" in
        -*|.*) return 1 ;;
    esac
    out="$(printf '%s' "$raw" | sed -E 's/-+/-/g; s/-+$//' | cut -c1-"$max")"
    case "$out" in
        ''|'.'|'..') return 1 ;;
    esac
    printf '%s' "$out"
}

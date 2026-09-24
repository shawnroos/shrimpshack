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

# No lib sources another, and ground.sh sources sanitize.sh AFTER this file:
# without this the call below is 127, which its `||` branch reads as a refusal.
command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::binding_read >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/binding.sh"

HERDR_LINEAR_API_URL="${HERDR_LINEAR_API_URL:-https://api.linear.app/graphql}"
HERDR_LINEAR_CURL_BIN="${HERDR_LINEAR_CURL_BIN:-curl}"
HERDR_LINEAR_CACHE_DIR="${LINEAR_CACHE_DIR:-$HOME/.claude/linear-cache}"
HERDR_LINEAR_SECRETS_FILE="${LINEAR_SECRETS_FILE:-$HOME/.secrets}"
HERDR_LINEAR_KEYCHAIN_SERVICE="${HERDR_LINEAR_KEYCHAIN_SERVICE:-work-linear}"
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

HERDR_LINEAR_VIEW_PAGE_MAX="${HERDR_LINEAR_VIEW_PAGE_MAX:-10}"
HERDR_LINEAR_VIEW_PAGE_SIZE=50

HERDR_LINEAR_OK=0
HERDR_LINEAR_UNAVAILABLE=1     # network, timeout, or a body we cannot read
HERDR_LINEAR_NOT_FOUND=2       # Linear answered, and there is no such issue
HERDR_LINEAR_AUTH=3            # the credential was refused
HERDR_LINEAR_RATELIMITED=4     # still limited after backing off
HERDR_LINEAR_REFUSED=5         # the plugin's own bound said no
HERDR_LINEAR_VIEW_PREFS_FAILED=6  # the view exists; its board preferences do not
HERDR_LINEAR_PARTIAL=7         # a listing stopped at its page cap; what printed is real

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
    # hyphen cannot do this: `[A-Z][A-Z0-9]{1,7}-?[0-9]{1,6}` against `web3055`
    # lets the letter class eat the digits and then backtrack one, yielding
    # WEB305-5 instead of WEB-3055 -- silently the wrong issue, on the plan's
    # own example. Hyphenated form allows digits in the team key (X2-14);
    # unhyphenated requires a letters-only key, because `X23055` cannot be split
    # correctly by any rule and guessing is worse than not matching.
    m="$(printf '%s' "$branch" \
        | grep -oiE '[A-Z][A-Z0-9]{0,7}-[0-9]{1,6}|[A-Z]{2,8}[0-9]{1,6}' \
        | head -1)" || return 1
    [ -n "$m" ] || return 1
    # Normalise to the canonical UPPER-NNN form Linear uses. The SAME two
    # alternatives as the match above, and for the same reason: one pattern with
    # an optional hyphen re-introduces the greedy split here even after the grep
    # gets it right, so WEB3055 normalises to WEB305-5. The bug has two sites.
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

# bin/linear-cache-refresh.sh writes this marker on a fallback read and
# `bin/migrate-credential.sh report` reads it back. The LIBRARY path has to
# write it too: the hooks go through here and never through the refresh script,
# so without this the migration reports finished while every hook is still
# reading the plaintext copy. Same path, same format, deliberately.
herdr_linear::_note_plaintext_fallback() {
    mkdir -p "$HERDR_LINEAR_CACHE_DIR" 2>/dev/null || return 0
    date -u +%Y-%m-%dT%H:%M:%SZ >"$HERDR_LINEAR_CACHE_DIR/_plaintext_fallback_used" 2>/dev/null
    return 0
}

# The credential is written to curl's stdin. Nothing else in this file builds a
# request, so this is the single place that rule has to hold.
#
# THE `( )` BODY IS LOAD-BEARING, NOT STYLE. Bash traces AFTER expansion, so
# under `set -x` a brace-bodied `{ }` version of this function expands the key
# into the xtrace stream -- measured at three occurrences per call -- even
# though herdr_linear::credential suppresses tracing inside itself. `set +x`
# only holds for the shell that runs it, so the guard has to be in the frame
# that HOLDS the value. A subshell's option change dies with the subshell, so
# the caller's own tracing is left exactly as it was. This is the shape every
# function in lib/secrets.sh uses, for this reason.
herdr_linear::_post() (
    set +x
    local body="$1" key rc
    # credential answers 0 from the Keychain and 2 from the pre-migration
    # plaintext copy. BOTH are a usable key -- 2 is "here it is, and you should
    # know where it came from", not a failure. Treating any non-zero as auth
    # failure made every call fail while the migration is still outstanding,
    # which is the state the machine is in right now.
    key="$(herdr_linear::credential)"; rc=$?
    case "$rc" in
        0) ;;
        2) herdr_linear::_note_plaintext_fallback ;;
        *) return "$HERDR_LINEAR_NOCRED" ;;
    esac
    [ -n "$key" ] || return "$HERDR_LINEAR_NOCRED"
    printf 'header = "Authorization: %s"\nheader = "Content-Type: application/json"\nurl = "%s"\n' \
        "$key" "$HERDR_LINEAR_API_URL" \
        | "$HERDR_LINEAR_CURL_BIN" -s --max-time "$HERDR_LINEAR_TIMEOUT_SECONDS" \
            --config - -X POST -d "$body"
    rc=$?
    return "$rc"
)

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

# The board's issue page reads these on top of the snapshot's fields. They are a
# separate set because the snapshot carries one row per issue for a whole space:
# putting a description and a comment thread on that row would multiply the
# snapshot's size by the length of the longest thread.
HERDR_LINEAR_DETAIL_PAGE_SIZE=50
# `parent { state { ... } }` merges with the base set's `parent { id identifier
# title }` rather than colliding with it, which is how the parent row carries the
# status every other linked row does without duplicating the base set here.
HERDR_LINEAR_DETAIL_FIELDS='description dueDate estimate
  parent { state { id name type } }
  projectMilestone { id name }
  cycle { id number name }
  children(first: %d) { nodes { id identifier title state { id name type } } pageInfo { hasNextPage } }
  relations(first: %d) { nodes { id type relatedIssue { id identifier title state { id name type } } } pageInfo { hasNextPage } }
  inverseRelations(first: %d) { nodes { id type issue { id identifier title state { id name type } } } pageInfo { hasNextPage } }
  comments(first: %d) { nodes { id body createdAt user { id name } parent { id } } pageInfo { hasNextPage } }
  history(first: %d) { nodes { id createdAt actor { id name } fromState { name } toState { name } fromAssignee { name } toAssignee { name } fromPriority toPriority addedLabels { name } removedLabels { name } } pageInfo { hasNextPage } }'

# One issue with everything the board's issue page shows. Every paged connection
# is asked for once at the page size and never drained: the caller reports the
# truncation instead, so the read stays one Linear call whatever the thread
# length. A connection that says `hasNextPage` is what makes this PARTIAL.
herdr_linear::fetch_issue_detail() {
    local id="${1:-}" body detail
    [ -n "$id" ] || return "$HERDR_LINEAR_NOT_FOUND"
    # shellcheck disable=SC2059
    detail="$(printf "$HERDR_LINEAR_DETAIL_FIELDS" \
        "$HERDR_LINEAR_DETAIL_PAGE_SIZE" "$HERDR_LINEAR_DETAIL_PAGE_SIZE" \
        "$HERDR_LINEAR_DETAIL_PAGE_SIZE" "$HERDR_LINEAR_DETAIL_PAGE_SIZE" \
        "$HERDR_LINEAR_DETAIL_PAGE_SIZE")" || return "$HERDR_LINEAR_UNAVAILABLE"
    body="$(python3 -c '
import sys, json
print(json.dumps({"query": "query($id:String!){issue(id:$id){%s %s}}" % (sys.argv[2], sys.argv[3]),
                  "variables": {"id": sys.argv[1]}}))
' "$id" "$HERDR_LINEAR_ISSUE_FIELDS" "$detail")" || return "$HERDR_LINEAR_UNAVAILABLE"
    herdr_linear::query "$body"
}

# R1. The workspace's URL key -- the value in every Linear URL -- is the first
# segment of a worktree path, so an unnameable organisation is a refusal rather
# than an empty segment that collapses two organisations into one directory.
herdr_linear::organization_key() {
    local resp rc key
    resp="$(herdr_linear::query '{"query":"{organization{urlKey}}"}')"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    key="$(printf '%s' "$resp" | python3 -c '
import sys, json
d = json.load(sys.stdin).get("data") or {}
sys.stdout.write((d.get("organization") or {}).get("urlKey") or "")
' 2>/dev/null)"
    herdr_linear::is_safe_identifier "$key" || return "$HERDR_LINEAR_UNAVAILABLE"
    printf '%s' "$key"
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
    # A path segment built from a tracker-authored value. Refusing at the sink
    # is what makes the traversal impossible however the identifier arrived.
    herdr_linear::is_safe_identifier "$id" || return 1
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

# herdr_linear::context_fields <context-json> <field>...
#
# The named fields off one context blob, tab-separated on one line, from one
# python3. Consume with `cut -f N`, not `read`: a field can legitimately be
# empty -- an issue with no project -- and tab in IFS collapses the gap.
# Only an absent field and a null one come back empty; `false` and `0` come
# back as themselves, which `or ""` folded in with the absent ones.
herdr_linear::context_fields() {
    local json="${1:-}"; shift
    printf '%s' "$json" | python3 -c '
import sys, json
ctx = json.load(sys.stdin)
sys.stdout.write("\t".join("" if ctx.get(f) is None else str(ctx.get(f)) for f in sys.argv[1:]) + "\n")
' "$@" 2>/dev/null
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
    # The ids, beside the human-readable key and name. The write-consent record
    # is compared against what `current_context` derives, which is ids -- so a
    # key here and an id there would make every second verb ask again.
    "project_id": (api.get("project") or {}).get("id", ""),
    "team_id": (api.get("team") or {}).get("id", ""),
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


# ------------------------------------------------------------------ the views

# herdr_linear::_issues_paged <filter-json>
#
# The filter is Linear's own IssueFilter, passed through as a variable and
# never rewritten: a view's filterData is what the person built in the UI, and
# any transcription here would be a second, silently different, view. Pages
# until the connection is exhausted or the page cap is hit; the cap is reported
# in the document rather than raised, because a partial board with a marker is
# more use than no board.
herdr_linear::_issues_paged() {
    local filter="${1:-}" acc_file rc
    printf '%s' "$filter" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if isinstance(d, dict) else 1)' 2>/dev/null \
        || return "$HERDR_LINEAR_REFUSED"
    # Pages accumulate in a file, not a variable handed to python3 through the
    # environment: one env string is capped at 128 KiB on Linux and a real
    # project's listing has already passed 200 KB.
    acc_file="$(mktemp)" || return "$HERDR_LINEAR_UNAVAILABLE"
    herdr_linear::_issues_paged_into "$acc_file" "$filter"; rc=$?
    rm -f "$acc_file"
    return "$rc"
}

herdr_linear::_issues_paged_into() {
    local acc_file="${1:-}" filter="${2:-}" after="" body resp rc pages=0 ctl acc truncated=false
    while :; do
        if [ "$pages" -ge "$HERDR_LINEAR_VIEW_PAGE_MAX" ]; then truncated=true; break; fi
        body="$(HERDR_LINEAR_FILTER="$filter" HERDR_LINEAR_AFTER="$after" python3 -c '
import sys, json, os
q = "query($n:Int,$after:String,$filter:IssueFilter){issues(first:$n,after:$after,filter:$filter){nodes{%s} pageInfo{hasNextPage endCursor}}}" % sys.argv[2]
v = {"n": int(sys.argv[1]), "filter": json.loads(os.environ["HERDR_LINEAR_FILTER"])}
if os.environ.get("HERDR_LINEAR_AFTER"):
    v["after"] = os.environ["HERDR_LINEAR_AFTER"]
print(json.dumps({"query": q, "variables": v}))
' "$HERDR_LINEAR_VIEW_PAGE_SIZE" "$HERDR_LINEAR_ISSUE_FIELDS")" || return "$HERDR_LINEAR_UNAVAILABLE"
        resp="$(herdr_linear::query "$body")"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        pages=$(( pages + 1 ))
        # One python3 per page appends that page's nodes as one line of the
        # file; the loop's control values come out on stdout.
        ctl="$(printf '%s' "$resp" | python3 -c '
import sys, json
d = json.load(sys.stdin)
conn = ((d.get("data") or {}).get("issues")) or {}
nodes = conn.get("nodes")
if not isinstance(nodes, list):
    sys.exit(1)
with open(sys.argv[1], "a") as f:
    f.write(json.dumps(nodes) + "\n")
pi = conn.get("pageInfo") or {}
print("1" if pi.get("hasNextPage") else "0", pi.get("endCursor") or "")
' "$acc_file" 2>/dev/null)" || return "$HERDR_LINEAR_UNAVAILABLE"
        # A next page with no cursor to reach it is a list cut short.
        case "$ctl" in
            1\ ?*) after="${ctl#1 }" ;;
            1*)    truncated=true; break ;;
            *)     break ;;
        esac
    done
    acc="$(python3 -c '
import sys, json
out = []
for line in open(sys.argv[1]):
    if line.strip():
        out.extend(json.loads(line))
print(json.dumps(out))
' "$acc_file" 2>/dev/null)" || return "$HERDR_LINEAR_UNAVAILABLE"
    printf '{"nodes":%s,"truncated":%s}' "$acc" "$truncated"
}

herdr_linear::view_issues() {
    herdr_linear::_issues_paged "${1:-}"
}

herdr_linear::project_issues() {
    local project="${1:-}" filter
    [ -n "$project" ] || return "$HERDR_LINEAR_REFUSED"
    filter="$(python3 -c 'import sys,json;print(json.dumps({"project":{"id":{"eq":sys.argv[1]}},"state":{"type":{"neq":"canceled"}}}))' "$project")" \
        || return "$HERDR_LINEAR_UNAVAILABLE"
    herdr_linear::_issues_paged "$filter"
}

# KTD12. A view belongs to a project when its filter NAMES the project: an
# Issue view whose filterData carries project.id.eq or project.id.in with the
# id, at any depth under Linear's and/or wrappers (the UI saves every filter
# as {"and":[...]}). A `project` clause with no `id` -- project.initiatives,
# for one -- names no project and is not a match.
#
# One definition, prepended to both python3 programs that need it: the list a
# person picks from and the check on what they picked must agree.
HERDR_LINEAR_NAMES_PROJECT_PY='
def names_project(node, project):
    if isinstance(node, list):
        return any(names_project(n, project) for n in node)
    if not isinstance(node, dict):
        return False
    for k, v in node.items():
        if k == "project" and isinstance(v, dict):
            ident = v.get("id")
            if isinstance(ident, dict):
                if ident.get("eq") == project:
                    return True
                if isinstance(ident.get("in"), list) and project in ident["in"]:
                    return True
        elif k in ("and", "or") and names_project(v, project):
            return True
    return False
'

# herdr_linear::filter_names_project <filter-json> <project-id> -> 0 when the
# filter names the project, 1 when it does not or cannot be read.
herdr_linear::filter_names_project() {
    local filter="${1:-}" project="${2:-}"
    [ -n "$filter" ] && [ -n "$project" ] || return 1
    printf '%s' "$filter" | HERDR_LINEAR_PROJECT="$project" python3 -c "$HERDR_LINEAR_NAMES_PROJECT_PY"'
import sys, json, os
try:
    f = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if names_project(f, os.environ["HERDR_LINEAR_PROJECT"]) else 1)
' 2>/dev/null
}

herdr_linear::project_views() {
    local project="${1:-}" after="" body resp rc pages=0 out="" partial=0
    [ -n "$project" ] || return "$HERDR_LINEAR_REFUSED"
    while :; do
        if [ "$pages" -ge "$HERDR_LINEAR_VIEW_PAGE_MAX" ]; then partial=1; break; fi
        body="$(HERDR_LINEAR_AFTER="$after" python3 -c '
import sys, json, os
q = "query($n:Int,$after:String){customViews(first:$n,after:$after){nodes{id name modelName archivedAt filterData} pageInfo{hasNextPage endCursor}}}"
v = {"n": int(sys.argv[1])}
if os.environ.get("HERDR_LINEAR_AFTER"):
    v["after"] = os.environ["HERDR_LINEAR_AFTER"]
print(json.dumps({"query": q, "variables": v}))
' "$HERDR_LINEAR_VIEW_PAGE_SIZE")" || return "$HERDR_LINEAR_UNAVAILABLE"
        resp="$(herdr_linear::query "$body")"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        pages=$(( pages + 1 ))
        resp="$(printf '%s' "$resp" | HERDR_LINEAR_PROJECT="$project" python3 -c "$HERDR_LINEAR_NAMES_PROJECT_PY"'
import sys, json, os, re
# An id carrying a newline would print a second, forged row.
VIEW_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", re.ASCII)
project = os.environ["HERDR_LINEAR_PROJECT"]
d = json.load(sys.stdin)
conn = ((d.get("data") or {}).get("customViews")) or {}
nodes = conn.get("nodes")
if not isinstance(nodes, list):
    sys.exit(1)
for v in nodes:
    if v.get("modelName") != "Issue" or v.get("archivedAt"):
        continue
    if not names_project(v.get("filterData"), project):
        continue
    vid = v.get("id")
    if not isinstance(vid, str) or not VIEW_ID.fullmatch(vid):
        continue
    name = "".join(ch for ch in str(v.get("name") or "") if ch not in "\t\n\r")
    print("%s\t%s" % (vid, name))
pi = conn.get("pageInfo") or {}
print("\x01%s %s" % ("1" if pi.get("hasNextPage") else "0", pi.get("endCursor") or ""))
' 2>/dev/null)" || return "$HERDR_LINEAR_UNAVAILABLE"
        after="${resp##*$'\x01'}"
        resp="${resp%$'\x01'*}"
        [ -n "$resp" ] && out="$out$resp"
        # A next page with no cursor to reach it is a list cut short.
        case "$after" in
            1\ ?*) after="${after#1 }" ;;
            1*)    partial=1; break ;;
            *)     break ;;
        esac
    done
    [ -n "$out" ] && printf '%s' "$out" | herdr_linear::sanitize_stream
    if [ "$partial" -eq 1 ]; then
        # The organisation has more views than the page cap reads. The lines
        # above are real candidates, and a view past the cap is not among them.
        printf 'listed the first %s pages of views only; a view past that can be chosen by its id\n' "$HERDR_LINEAR_VIEW_PAGE_MAX" >&2
        return "$HERDR_LINEAR_PARTIAL"
    fi
    return "$HERDR_LINEAR_OK"
}

# herdr_linear::my_projects -> a JSON array of {id, name, team_key}, the
# projects the credential's person is a member of. Exit 7 when the page cap
# stopped the listing; what printed is still real.
#
# Membership is Linear's own (tests/probe/projects-shapes.md): `User` has no
# projects field, so the filter on `projects` is the only way to ask. An
# assignee-derived list is not a substitute -- it drops every project the
# person joined and has no issue in.
herdr_linear::my_projects() {
    local acc_file rc
    acc_file="$(mktemp)" || return "$HERDR_LINEAR_UNAVAILABLE"
    herdr_linear::_my_projects_into "$acc_file"; rc=$?
    rm -f "$acc_file"
    return "$rc"
}

herdr_linear::_my_projects_into() {
    local acc_file="${1:-}" after="" body resp rc pages=0 ctl out partial=0
    while :; do
        if [ "$pages" -ge "$HERDR_LINEAR_VIEW_PAGE_MAX" ]; then partial=1; break; fi
        body="$(HERDR_LINEAR_AFTER="$after" python3 -c '
import sys, json, os
q = "query($n:Int,$after:String,$filter:ProjectFilter){projects(first:$n,after:$after,filter:$filter){nodes{id name teams(first:1){nodes{key}}} pageInfo{hasNextPage endCursor}}}"
v = {"n": int(sys.argv[1]), "filter": {"members": {"some": {"isMe": {"eq": True}}}}}
if os.environ.get("HERDR_LINEAR_AFTER"):
    v["after"] = os.environ["HERDR_LINEAR_AFTER"]
print(json.dumps({"query": q, "variables": v}))
' "$HERDR_LINEAR_VIEW_PAGE_SIZE")" || return "$HERDR_LINEAR_UNAVAILABLE"
        resp="$(herdr_linear::query "$body")"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        pages=$(( pages + 1 ))
        ctl="$(printf '%s' "$resp" | python3 -c '
import sys, json
d = json.load(sys.stdin)
conn = ((d.get("data") or {}).get("projects")) or {}
nodes = conn.get("nodes")
if not isinstance(nodes, list):
    sys.exit(1)
rows = []
for p in nodes:
    if not isinstance(p, dict) or not p.get("id"):
        continue
    teams = ((p.get("teams") or {}).get("nodes")) or []
    key = teams[0].get("key") if teams and isinstance(teams[0], dict) else None
    rows.append({"id": p["id"], "name": p.get("name") or "", "team_key": key or None})
with open(sys.argv[1], "a") as f:
    f.write(json.dumps(rows) + "\n")
pi = conn.get("pageInfo") or {}
print("1" if pi.get("hasNextPage") else "0", pi.get("endCursor") or "")
' "$acc_file" 2>/dev/null)" || return "$HERDR_LINEAR_UNAVAILABLE"
        # A next page with no cursor to reach it is a list cut short.
        case "$ctl" in
            1\ ?*) after="${ctl#1 }" ;;
            1*)    partial=1; break ;;
            *)     break ;;
        esac
    done
    out="$(python3 -c '
import sys, json
out = []
for line in open(sys.argv[1]):
    if line.strip():
        out.extend(json.loads(line))
print(json.dumps(out))
' "$acc_file" 2>/dev/null)" || return "$HERDR_LINEAR_UNAVAILABLE"
    printf '%s' "$out"
    [ "$partial" -eq 1 ] && return "$HERDR_LINEAR_PARTIAL"
    return "$HERDR_LINEAR_OK"
}

# The layout fields were confirmed by introspection on 2026-09-14
# (tests/probe/customviews-transcript.md): viewPreferencesValues carries
# layout, issueGrouping, columnOrderBoard and hiddenColumns, and the two lists
# are null on a view that has never had its columns arranged.
herdr_linear::view_read() {
    local id="${1:-}" body resp rc
    [ -n "$id" ] || return "$HERDR_LINEAR_NOT_FOUND"
    body="$(python3 -c '
import sys, json
q = "query($id:String!){customView(id:$id){id name modelName archivedAt filterData viewPreferencesValues{layout issueGrouping columnOrderBoard hiddenColumns}}}"
print(json.dumps({"query": q, "variables": {"id": sys.argv[1]}}))
' "$id")" || return "$HERDR_LINEAR_UNAVAILABLE"
    resp="$(herdr_linear::query "$body")"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s' "$resp" | python3 -c '
import sys, json
v = ((json.load(sys.stdin).get("data") or {}).get("customView"))
if not isinstance(v, dict) or not v.get("id"):
    sys.exit(1)
p = v.get("viewPreferencesValues") or {}
def lst(x):
    return [str(i) for i in x] if isinstance(x, list) else []
print(json.dumps({
    "id": v["id"],
    "name": v.get("name") or "",
    "archived": bool(v.get("archivedAt")),
    "filter": v.get("filterData") if isinstance(v.get("filterData"), dict) else {},
    "layout": {
        "grouping": p.get("issueGrouping"),
        "column_order": lst(p.get("columnOrderBoard")),
        "hidden": lst(p.get("hiddenColumns")),
    },
}, sort_keys=True))
' 2>/dev/null || return "$HERDR_LINEAR_UNAVAILABLE"
}

# herdr_linear::view_create <project-id> <name>
#
# Two mutations. The second gives the view its board layout; when it fails the
# view still exists, so the id is printed anyway under its own code and the
# caller records it -- an unrecorded view is one nobody can find to delete.
# Not gated here: the bind skill's consent gate is the only caller (KTD11).
# CustomViewCreateInput carries no modelName (introspected 2026-09-14): the
# model follows from which filter field is set, and filterData is the issue one.
herdr_linear::view_create() {
    local project="${1:-}" name="${2:-}" body resp rc view_id
    [ -n "$project" ] && [ -n "$name" ] || return "$HERDR_LINEAR_REFUSED"
    body="$(python3 -c '
import sys, json
q = "mutation($i:CustomViewCreateInput!){customViewCreate(input:$i){success customView{id}}}"
i = {"name": sys.argv[2], "shared": False,
     "filterData": {"project": {"id": {"in": [sys.argv[1]]}}}}
print(json.dumps({"query": q, "variables": {"i": i}}))
' "$project" "$name")" || return "$HERDR_LINEAR_UNAVAILABLE"
    resp="$(herdr_linear::query "$body")"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    # success alone is not an id: the documents arm answers success:true with
    # a null document, and a view recorded without an id can never be found.
    view_id="$(printf '%s' "$resp" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)["data"]["customViewCreate"]
    ok = d["success"] is True
    vid = (d.get("customView") or {}).get("id") or ""
except Exception:
    sys.exit(1)
if not ok or not vid:
    sys.exit(1)
sys.stdout.write(vid)
' 2>/dev/null)" || return "$HERDR_LINEAR_UNAVAILABLE"

    body="$(python3 -c '
import sys, json
q = "mutation($i:ViewPreferencesCreateInput!){viewPreferencesCreate(input:$i){success}}"
i = {"type": "user", "viewType": "customView", "customViewId": sys.argv[1],
     "preferences": {"layout": "board", "issueGrouping": "workflowState"}}
print(json.dumps({"query": q, "variables": {"i": i}}))
' "$view_id")" || { printf '%s' "$view_id"; return "$HERDR_LINEAR_VIEW_PREFS_FAILED"; }
    resp="$(herdr_linear::query "$body")"; rc=$?
    if [ "$rc" -ne 0 ]; then printf '%s' "$view_id"; return "$HERDR_LINEAR_VIEW_PREFS_FAILED"; fi
    printf '%s' "$resp" | python3 -c '
import sys, json
try:
    ok = json.load(sys.stdin)["data"]["viewPreferencesCreate"]["success"]
except Exception:
    sys.exit(1)
sys.exit(0 if ok is True else 1)
' 2>/dev/null || { printf '%s' "$view_id"; return "$HERDR_LINEAR_VIEW_PREFS_FAILED"; }
    printf '%s' "$view_id"
    return "$HERDR_LINEAR_OK"
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

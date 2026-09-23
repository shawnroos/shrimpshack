#!/usr/bin/env bats

load setup_common

# The session record, the resolver and the guard.
#
# The fixture's own ids are the whole point of the guard tests: WEB-3308 and
# BRAND-1200 sit in the SAME project and belong to DIFFERENT teams, which is the
# case a project-only test cannot see.

bats_require_minimum_version 1.5.0

WEB_TEAM=55555555-5555-4555-8555-555555555555
BRAND_TEAM=66666666-6666-4666-8666-666666666666
PROJECT=44444444-4444-4444-8444-444444444444
OTHER_PROJECT=99999999-9999-4999-8999-999999999999

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(cd "$(mktemp -d)" && pwd -P)"

    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    mkdir -p "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_CTXFILTERCTXFILTERCT" > "$LINEAR_SECRETS_FILE"

    # A named session, as herdr exports it into every pane it owns.
    export HERDR_SOCKET_PATH="$WORK/herdr/sessions/alpha/herdr.sock"

    WT="$WORK/wt"
    mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-3308-panel
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

    # shellcheck source=/dev/null
    for f in sanitize.sh secrets.sh contain.sh herdr-read.sh binding.sh linear.sh context.sh repos.sh context-filter.sh; do
        . "$ROOT/lib/$f"
    done
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

declare_team() {   # declare_team <team-id> [team-key]
    local n
    n="$(herdr_linear::session_propose "$1")" || return 1
    herdr_linear::session_confirm "$1" "$n" "${2:-}"
}

bind_space() {     # bind_space <space> <project> [team-id...]
    local ws="$1" project="$2" n
    shift 2
    n="$(herdr_linear::workspace_propose "$ws" "$project")" || return 1
    herdr_linear::workspace_confirm "$ws" "$project" "$n" "$@"
}

bind_wt() {
    local n
    n="$(herdr_linear::binding_propose "$WT" "$1")"
    herdr_linear::binding_confirm "$WT" "$1" "$n"
}

field() { printf '%s' "$1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get(sys.argv[1],""))' "$2"; }

# ------------------------------------------------------------ the session record

@test "a session with no record has no team and is unbound" {
    run herdr_linear::session_state
    [ "$output" = "unbound" ]
    run herdr_linear::session_team
    [ -z "$output" ]
}

@test "a declared team is readable, with its key in the display field" {
    declare_team "$WEB_TEAM" WEB
    [ "$(herdr_linear::session_state)" = "bound" ]
    [ "$(herdr_linear::session_team)" = "$WEB_TEAM" ]
    [ "$(herdr_linear::session_team_key)" = "WEB" ]
}

@test "a proposed team is not yet the session's team" {
    herdr_linear::session_propose "$WEB_TEAM" > /dev/null
    [ "$(herdr_linear::session_state)" = "proposed" ]
    [ -z "$(herdr_linear::session_team)" ]
}

@test "confirming without the proposal's nonce records nothing" {
    herdr_linear::session_propose "$WEB_TEAM" > /dev/null
    run herdr_linear::session_confirm "$WEB_TEAM" not-the-nonce
    [ "$status" -ne 0 ]
    [ "$(herdr_linear::session_state)" = "proposed" ]
}

@test "the default session gets a record of its own, and the resolver reports it" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    export HERDR_SOCKET_PATH="$WORK/herdr/herdr.sock"
    declare_team "$WEB_TEAM" WEB
    [ -f "$HERDR_LINEAR_STORE_DIR/contexts/session-default.json" ]
    [ "$(herdr_linear::session_team)" = "$WEB_TEAM" ]
    local ctx; ctx="$(herdr_linear::context "$WT")"
    [ "$(field "$ctx" team_id)" = "$WEB_TEAM" ]
    [ "$(field "$ctx" team_source)" = "session" ]
}

# misplaced suspends writes; it does not widen the session. A team that stopped
# answering here would let every write the guard was narrowing through at the
# moment a contradiction was found, and would leave the check that set the state
# unable to run again and clear it.
@test "a session marked misplaced still narrows, so writes stay contained" {
    declare_team "$WEB_TEAM" WEB
    herdr_linear::session_set_state misplaced
    [ "$(herdr_linear::session_state)" = "misplaced" ]
    [ "$(herdr_linear::session_team)" = "$WEB_TEAM" ]
    run herdr_linear::context_allows team "$BRAND_TEAM"
    [ "$status" -eq 1 ]
}

@test "two sessions do not share a team" {
    declare_team "$WEB_TEAM" WEB
    export HERDR_SOCKET_PATH="$WORK/herdr/sessions/beta/herdr.sock"
    [ "$(herdr_linear::session_state)" = "unbound" ]
    export HERDR_SOCKET_PATH="$WORK/herdr/sessions/alpha/herdr.sock"
    [ "$(herdr_linear::session_team)" = "$WEB_TEAM" ]
}

@test "a pane with no herdr socket has no session level to declare" {
    unset HERDR_SOCKET_PATH
    run herdr_linear::session_propose "$WEB_TEAM"
    [ "$status" -ne 0 ]
    [ "$(herdr_linear::session_state)" = "unbound" ]
}

@test "the space record carries the project's team ids" {
    bind_space wA "$PROJECT" "$WEB_TEAM" "$BRAND_TEAM"
    run herdr_linear::workspace_team_ids wA
    [ "$status" -eq 0 ]
    [ "$output" = "$WEB_TEAM
$BRAND_TEAM" ]
}

# The spelling the skills use, run for real: `read -r -a` then "${TEAMS[@]}" is
# quoted AND still several arguments, which neither $TEAMS nor "$TEAMS" is.
@test "the array spelling the skills use records every team id" {
    local n
    read -r -a TEAMS <<< "$WEB_TEAM $BRAND_TEAM "
    n="$(herdr_linear::workspace_propose wA "$PROJECT")"
    herdr_linear::workspace_confirm wA "$PROJECT" "$n" "${TEAMS[@]}"
    run herdr_linear::workspace_team_ids wA
    [ "$output" = "$WEB_TEAM
$BRAND_TEAM" ]
}

@test "binding a space to another project drops the previous team ids" {
    bind_space wA "$PROJECT" "$WEB_TEAM"
    bind_space wA "$OTHER_PROJECT"
    run herdr_linear::workspace_team_ids wA
    [ -z "$output" ]
}

# ---------------------------------------------------------------- the resolver

@test "with nothing declared the resolver answers what the worktree derives" {
    export FAKE_LINEAR_MODE=found_child
    bind_wt WEB-3308
    local ctx; ctx="$(herdr_linear::context "$WT")"
    [ "$(field "$ctx" identifier)" = "WEB-3308" ]
    [ "$(field "$ctx" project_id)" = "$PROJECT" ]
    [ "$(field "$ctx" team_id)" = "$WEB_TEAM" ]
    [ "$(field "$ctx" team_source)" = "derived" ]
    [ "$(field "$ctx" project_source)" = "derived" ]
    [ "$(field "$ctx" issue_source)" = "tab" ]
}

@test "a declared team is the resolver's team, and the session is named as the level" {
    declare_team "$BRAND_TEAM" BRAND
    bind_space wA "$PROJECT" "$BRAND_TEAM"
    local ctx; ctx="$(herdr_linear::context "$WT" wA)"
    [ "$(field "$ctx" team_id)" = "$BRAND_TEAM" ]
    [ "$(field "$ctx" team_key)" = "BRAND" ]
    [ "$(field "$ctx" team_source)" = "session" ]
    [ "$(field "$ctx" project_id)" = "$PROJECT" ]
    [ "$(field "$ctx" project_source)" = "space" ]
}

# The record carries the team's KEY, never its name, and /work:new prints the
# name field beside the id. An empty one reads as "the team is unresolved" for a
# team that was declared out loud.
@test "a declared team reports its key where it has no name" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    declare_team "$BRAND_TEAM" BRAND
    local ctx; ctx="$(herdr_linear::context "$WT")"
    [ "$(field "$ctx" team_name)" = "BRAND" ]
}

@test "a resolved session and space make no Linear call" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM"
    local ctx; ctx="$(herdr_linear::context "$WT" wA)"
    [ "$(field "$ctx" team_id)" = "$WEB_TEAM" ]
    [ "$(field "$ctx" project_id)" = "$PROJECT" ]
}

@test "nothing declared and nothing bound leaves every level absent" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    local ctx; ctx="$(herdr_linear::context "$WT")"
    [ -z "$(field "$ctx" team_id)" ]
    [ -z "$(field "$ctx" project_id)" ]
    [ "$(field "$ctx" team_source)" = "none" ]
    [ "$(field "$ctx" project_source)" = "none" ]
    [ "$(field "$ctx" issue_source)" = "none" ]
}

# ------------------------------------------------------------------- the guard

@test "no declared level filters nothing" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::context_allows team "$BRAND_TEAM"
    [ "$status" -eq 0 ]
    run herdr_linear::context_allows project "$OTHER_PROJECT"
    [ "$status" -eq 0 ]
}

@test "the session's own team is inside and another team is outside" {
    declare_team "$WEB_TEAM" WEB
    run herdr_linear::context_allows team "$WEB_TEAM"
    [ "$status" -eq 0 ]
    run herdr_linear::context_allows team "$BRAND_TEAM"
    [ "$status" -eq 1 ]
}

@test "the space's own project is inside on the recorded team ids alone" {
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM" "$BRAND_TEAM"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::context_allows project "$PROJECT" wA
    [ "$status" -eq 0 ]
}

@test "a space bound to a project without the session's team is outside, locally" {
    declare_team "$BRAND_TEAM" BRAND
    bind_space wA "$PROJECT" "$WEB_TEAM"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::context_allows project "$PROJECT" wA
    [ "$status" -eq 1 ]
}

@test "a project spanning the session's team is inside" {
    export FAKE_LINEAR_PROJECT_TEAMS=many
    declare_team "$BRAND_TEAM" BRAND
    run herdr_linear::context_allows project "$PROJECT"
    [ "$status" -eq 0 ]
}

@test "a project without the session's team is outside" {
    export FAKE_LINEAR_PROJECT_TEAMS=one
    declare_team "$BRAND_TEAM" BRAND
    run herdr_linear::context_allows project "$PROJECT"
    [ "$status" -eq 1 ]
}

@test "an issue of the session's team in the space's project is inside" {
    export FAKE_LINEAR_MODE=found_child
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM" "$BRAND_TEAM"
    run herdr_linear::context_allows issue WEB-3308 wA
    [ "$status" -eq 0 ]
}

@test "another team's issue in the space's own project is outside" {
    export FAKE_LINEAR_MODE=found_other_team
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM" "$BRAND_TEAM"
    run herdr_linear::context_allows issue BRAND-1200 wA
    [ "$status" -eq 1 ]
}

@test "an issue outside the space's project is outside" {
    export FAKE_LINEAR_MODE=found_child
    bind_space wA "$OTHER_PROJECT"
    run herdr_linear::context_allows issue WEB-3308 wA
    [ "$status" -eq 1 ]
}

@test "an issue is inside when only its team is declared and it matches" {
    export FAKE_LINEAR_MODE=found_child
    declare_team "$WEB_TEAM" WEB
    run herdr_linear::context_allows issue WEB-3308
    [ "$status" -eq 0 ]
}

@test "an unreachable Linear is unknown, never outside" {
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::context_allows issue WEB-3308 wA
    [ "$status" -eq 3 ]
    run herdr_linear::context_allows project "$OTHER_PROJECT"
    [ "$status" -eq 3 ]
}

@test "a kind the guard does not know is refused rather than allowed" {
    declare_team "$WEB_TEAM" WEB
    run herdr_linear::context_allows cycle something
    [ "$status" -ne 0 ]
}

# ------------------------------------------------------------ the tab on a bind

@test "the bind skill records the tab it confirmed in" {
    local fences
    fences="$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
sys.stdout.write("\n".join(re.findall(r"```bash\n(.*?)```", text, re.S)))
' "$ROOT/skills/bind/SKILL.md")"
    [ "$(printf '%s' "$fences" | grep -c 'herdr_linear::binding_confirm')" -eq 2 ]
    [ "$(printf '%s' "$fences" | grep -c 'herdr_linear::binding_set_tab')" -eq 2 ]
}

# --------------------------------------------------- the membership test itself

@test "a team the space recorded for its project is inside it, with no Linear call" {
    bind_space wA "$PROJECT" "$WEB_TEAM" "$BRAND_TEAM"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::team_in_project "$BRAND_TEAM" "$PROJECT" wA
    [ "$status" -eq 0 ]
}

@test "a team the space's project does not carry is outside it" {
    bind_space wA "$PROJECT" "$WEB_TEAM"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::team_in_project "$BRAND_TEAM" "$PROJECT" wA
    [ "$status" -eq 1 ]
}

@test "with no record to read the membership comes from Linear" {
    export FAKE_LINEAR_PROJECT_TEAMS=many
    run herdr_linear::team_in_project "$BRAND_TEAM" "$PROJECT"
    [ "$status" -eq 0 ]
    export FAKE_LINEAR_PROJECT_TEAMS=one
    run herdr_linear::team_in_project "$BRAND_TEAM" "$PROJECT"
    [ "$status" -eq 1 ]
}

@test "a membership that could not be asked is unknown, never outside" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::team_in_project "$BRAND_TEAM" "$PROJECT"
    [ "$status" -eq 3 ]
}

# ------------------------------------------- the guard, on fields already held

@test "the two-part test answers from fields a listing already carries" {
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM" "$BRAND_TEAM"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::context_allows_fields "$PROJECT" "$WEB_TEAM" wA
    [ "$status" -eq 0 ]
    run herdr_linear::context_allows_fields "$PROJECT" "$BRAND_TEAM" wA
    [ "$status" -eq 1 ]
    run herdr_linear::context_allows_fields "$OTHER_PROJECT" "$WEB_TEAM" wA
    [ "$status" -eq 1 ]
}

@test "no declared level lets any fields through" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::context_allows_fields "$OTHER_PROJECT" "$BRAND_TEAM"
    [ "$status" -eq 0 ]
}

# --------------------------------------------------------- the UNBOUND prefix

@test "a surface standing in no worktree wears the prefix" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    declare_team "$WEB_TEAM" WEB
    run herdr_linear::unbound_prefix ""
    [ "$status" -eq 0 ]
    [ "$output" = "UNBOUND: " ]
}

# The same rule the guard follows: a level that declared nothing narrows
# nothing. With no context at all there is nothing for a surface to be outside
# of, and branding every tab in every unconfigured session is a warning people
# learn to ignore.
@test "a surface in a session that declared nothing wears no prefix" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::unbound_prefix ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a space's project alone is enough context to brand a bare surface" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    bind_space wA "$PROJECT"
    run herdr_linear::unbound_prefix "" wA
    [ "$output" = "UNBOUND: " ]
}

@test "work the context covers wears no prefix" {
    export FAKE_LINEAR_MODE=found_child
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM"
    run herdr_linear::unbound_prefix WEB-3308 wA
    [ -z "$output" ]
}

@test "work outside the context wears the prefix" {
    export FAKE_LINEAR_MODE=found_other_team
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM"
    run herdr_linear::unbound_prefix BRAND-1200 wA
    [ "$output" = "UNBOUND: " ]
}

@test "a context that could not be asked does not brand the surface" {
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::unbound_prefix WEB-3308 wA
    [ -z "$output" ]
}

# ---------------------------------------------------- the expected directory

@test "the pane's own worktree is where it is expected to be" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    bind_wt WEB-3308
    run herdr_linear::expected_cwd "$WT"
    [ "$output" = "$WT" ]
}

@test "a subdirectory of the bound worktree still expects the worktree" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    bind_wt WEB-3308
    mkdir -p "$WT/src/deep"
    run herdr_linear::expected_cwd "$WT/src/deep"
    [ "$output" = "$WT" ]
}

@test "the binding whose recorded tab is this tab names the worktree" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    bind_wt WEB-3308
    herdr_linear::binding_set_tab "$WT" t7
    export HERDR_TAB_ID=t7
    mkdir -p "$WORK/elsewhere"
    run herdr_linear::expected_cwd "$WORK/elsewhere"
    [ "$output" = "$WT" ]
}

@test "with no binding the pair's only repository is offered" {
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM"
    mkdir -p "$WORK/repo" "$WORK/elsewhere"
    herdr_linear::record_scope_repo "$WORK/repo" "project-$PROJECT.team-$WEB_TEAM"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::expected_cwd "$WORK/elsewhere" wA
    [ "$output" = "$WORK/repo" ]
}

@test "several repositories for the pair name none of them" {
    declare_team "$WEB_TEAM" WEB
    bind_space wA "$PROJECT" "$WEB_TEAM"
    mkdir -p "$WORK/repo" "$WORK/repo2" "$WORK/elsewhere"
    herdr_linear::record_scope_repo "$WORK/repo" "project-$PROJECT.team-$WEB_TEAM"
    herdr_linear::record_scope_repo "$WORK/repo2" "project-$PROJECT.team-$WEB_TEAM"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::expected_cwd "$WORK/elsewhere" wA
    [ -z "$output" ]
}

@test "nothing bound and nothing recorded expects nothing" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    mkdir -p "$WORK/elsewhere"
    run herdr_linear::expected_cwd "$WORK/elsewhere"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# -------------------------------------------------------------- the declare verb

@test "the declare verb cannot be invoked by the model" {
    run grep -q '^disable-model-invocation: true$' "$ROOT/skills/declare/SKILL.md"
    [ "$status" -eq 0 ]
}

# It is the one verb that needs no worktree, and the one that must refuse to
# widen. Both halves go through the same membership test, so a skill that
# recorded either level without it is the drift this pins.
@test "the declare verb checks both levels before recording either" {
    local fences
    fences="$(python3 -c '
import re, sys
sys.stdout.write("\n".join(re.findall(r"```bash\n(.*?)```", open(sys.argv[1]).read(), re.S)))
' "$ROOT/skills/declare/SKILL.md")"
    [ "$(printf '%s' "$fences" | grep -c 'herdr_linear::team_in_project')" -ge 1 ]
    [ "$(printf '%s' "$fences" | grep -c 'herdr_linear::context_allows project')" -ge 1 ]
    [ "$(printf '%s' "$fences" | grep -c 'herdr_linear::session_confirm')" -ge 1 ]
    [ "$(printf '%s' "$fences" | grep -c 'herdr_linear::workspace_confirm')" -ge 1 ]
}

@test "the filing skill reads the resolver, not the worktree derivation alone" {
    local fences
    fences="$(python3 -c '
import re, sys
sys.stdout.write("\n".join(re.findall(r"```bash\n(.*?)```", open(sys.argv[1]).read(), re.S)))
' "$ROOT/skills/new/SKILL.md")"
    [ "$(printf '%s' "$fences" | grep -c 'herdr_linear::context ')" -ge 1 ]
    [ "$(printf '%s' "$fences" | grep -c 'herdr_linear::current_context')" -eq 0 ]
}

# ------------------------------ every place that binds a space asks the guard
#
# A space bound to a project the session's team is not on is a widening, and it
# cannot be caught afterwards: the record is already written. So the check is a
# property of the CLASS of binding sites, not of the one site the declare verb
# happens to be.

@test "every skill that records a space's project asks the guard first" {
    run python3 - "$ROOT" <<'PY'
import re, sys, glob, os

root = sys.argv[1]
bad, seen = [], 0
for path in sorted(glob.glob(os.path.join(root, "skills", "*", "SKILL.md"))):
    text = "\n".join(re.findall(r"```bash\n(.*?)```", open(path).read(), re.S))
    if "herdr_linear::workspace_confirm" not in text:
        continue
    seen += 1
    guard = text.find("herdr_linear::context_allows project")
    confirm = text.find("herdr_linear::workspace_confirm")
    if guard == -1 or guard > confirm:
        bad.append("%s: records a space's project with no context check before it" % path)
if seen < 3:
    bad.append("only %d binding document(s) were swept; the check proved nothing" % seen)
print("\n".join(bad))
PY
    [ -z "$output" ]
}

@test "every skill that records a space's project records the project's teams" {
    run python3 - "$ROOT" <<'PY'
import re, sys, glob, os

root = sys.argv[1]
bad, seen = [], 0
for path in sorted(glob.glob(os.path.join(root, "skills", "*", "SKILL.md"))):
    for fence in re.findall(r"```bash\n(.*?)```", open(path).read(), re.S):
        for line in fence.splitlines():
            if "herdr_linear::workspace_confirm" not in line or line.lstrip().startswith("#"):
                continue
            seen += 1
            # Quoted, and still several arguments: a bare $TEAMS is one unquoted
            # expansion, and "$TEAMS" is one id made of every id with spaces in
            # it. The array is the only spelling that is both.
            if '"${TEAMS[@]}"' not in line:
                bad.append("%s: %s" % (path, line.strip()))
if seen < 3:
    bad.append("only %d binding line(s) were swept; the check proved nothing" % seen)
print("\n".join(bad))
PY
    [ -z "$output" ]
}

# ------------------------------------------ the pair key cannot be spelled two ways
#
# The repository is recorded per project-and-team pair under the key
# `project-<project>.team-<team>`, and `.` is what separates its two halves. An
# id carrying one lets two DIFFERENT pairs spell one key: project `x.team-y`
# with team `z`, and project `x` with team `y.team-z`, are both
# `project-x.team-y.team-z`. Offering the first pair's repository to the second
# is offering somebody else's checkout.

@test "a dot-bearing team does not collect another pair's repository" {
    declare_team y.team-z
    bind_space wA x
    mkdir -p "$WORK/repo" "$WORK/elsewhere"
    herdr_linear::record_scope_repo "$WORK/repo" "project-x.team-y.team-z"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::expected_cwd "$WORK/elsewhere" wA
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a dot-bearing project is offered no repository either" {
    declare_team z
    bind_space wA x.team-y
    mkdir -p "$WORK/repo" "$WORK/elsewhere"
    herdr_linear::record_scope_repo "$WORK/repo" "project-x.team-y.team-z"
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::expected_cwd "$WORK/elsewhere" wA
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

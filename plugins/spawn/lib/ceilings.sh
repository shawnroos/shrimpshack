#!/usr/bin/env bash
# ceilings.sh — the permission ceiling a spawned child runs under (plan U8).
#
# WHY THIS EXISTS
# ---------------
# R8: the ceiling is set by the CALLER, not by the command. A person typing a
# slash command is present and accountable; an agent spawning one autonomously
# is not, so the absence of a human is what tightens the ceiling. R8's whole
# security argument is that the HARNESS decides which ceiling a caller may
# reach — so the two ceilings are reached through two separately allowlistable
# ENTRY POINTS (`bg-operator.sh` and `bg-repo.sh`), each with its ceiling
# hardcoded. There is deliberately no `--ceiling` flag anywhere: a flag would
# be self-declared, and any agent able to run the script could claim to be the
# operator.
#
# KD10: the ceiling is a permission CONFIGURATION the spawned session runs
# under, not a rule this plugin polices. A spawned session is itself a Claude
# Code session with its own permission settings, so the harness enforces the
# bound and this file only chooses which config to hand down. The plugin ships
# a default per ceiling under `permissions/`; a user overrides it by pointing
# SPAWN_CEILING_CONFIG_OPERATOR / SPAWN_CEILING_CONFIG_REPO at their own file,
# or by editing the shipped one. The plugin NEVER writes a user's settings.
#
# THE MECHANISM, MEASURED (docs/spike-bg-agent-mechanism.md, re-measured for
# this unit against the real CLI):
#   --setting-sources    minus `user` is the lever that makes a child genuinely
#                        narrower than its launcher. Without it the child
#                        inherits whatever the operator has already allowed
#                        themselves — a launcher that broadly allows Bash hands
#                        that down. With `project` alone, and no allow in the
#                        handed-down config, the child could not run a shell
#                        command; the control arm with the same prompt could.
#   --settings           carries the ceiling itself, and is honoured
#                        independently of --setting-sources.
#   --permission-mode    dontAsk is the no-park guarantee (R9): an unallowed
#                        call is REFUSED, never queued behind a prompt nobody
#                        is there to answer.
#
# THREE MECHANISMS, NOT TWO — AND ONLY ONE IS OBSERVABLE (R9; U9 depends on
# this, so it was measured rather than assumed):
#   1. `permissions.deny` on a TOOL removes the tool. The model reports having
#      no such tool and never attempts it. Nothing to observe. NOT USED HERE.
#   2. A call that is simply NOT ALLOWED, under dontAsk, is attempted and
#      refused — and lands in the child result JSON as
#      `permission_denials[] = {tool_name, tool_use_id, tool_input}`. This is
#      the one signal a supervisor can read without believing the model.
#      Measured: the Bash bound and the out-of-tree write bound both appear
#      there.
#   3. A `permissions.deny` PATH rule is attempted and refused too — the model
#      takes a second turn saying so — but it does NOT appear in
#      `permission_denials[]`. Measured, and it is the one that surprised us:
#      writing `.git/hooks/pre-push` under this ceiling was blocked, the array
#      was EMPTY, and the only account of the refusal was the model's own
#      prose, which KD9 disqualifies as a witness.
# The repo-bounded default deliberately bounds Bash and out-of-tree writes by
# mechanism 2, so the widest bounds are the observable ones. The hook and
# agent-config rules can only be mechanism 3, because the paths sit INSIDE the
# worktree the ceiling otherwise allows — so U9 cannot detect those from the
# child's output and must measure them by effect against the pre-job baseline
# (KTD9), which it does anyway.
#
# A FULLY DENIED CHILD STILL RETURNS EXIT 0 (measured, both in the spike and
# again here). The child's exit status is never evidence that work happened.
# This file therefore reports the child's status as data and classifies
# nothing; classification is the supervisor's job (U9).
#
# This file is SOURCED by the two entry points and will be sourced by U9's
# supervisor. It holds the ceiling table, the config renderer, the flag builder
# and the shared door body — so the two doors differ in exactly one constant.
# U9 needs only the first three; `spawn::ceiling_main` is the door body and the
# supervisor is free to ignore it.
#
# set -e is deliberately OFF here as everywhere else in lib/: every failure is
# an exit code the contract names, and exiting on the first non-zero command
# turns a classified 5 into an unclassified 1 with no JSON at all.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# KTD5 — sourced, not re-implemented. Two untrusted sources reach a door's
# terminal output: the child's stderr and the alias the caller handed us.
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"
# Sourced for spawn::resolve_token ONLY. The server.token parser below stays
# local (common.sh names the parsers as deliberately duplicated); the env/
# Keychain half is shared, so a door and the probe cannot present different
# tokens to the same gateway — or no token at all.
# shellcheck source=./secrets.sh
. "$SCRIPT_DIR/secrets.sh"

CTL="$SCRIPT_DIR/spawnctl.sh"

# ---------------------------------------------------------------------------
# The ceiling table. Two values, closed set.
# ---------------------------------------------------------------------------
SPAWN_CEILING_OPERATOR="operator"
SPAWN_CEILING_REPO="repo-bounded"

# Where the shipped defaults live. Sibling of lib/, inside the plugin tree, so
# an install carries them and a user can read what they are getting.
SPAWN_CEILING_DIR="${SPAWN_CEILING_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/permissions}"

# The tool gate lives in the plugin tree, beside the ceilings it enforces. It
# must NOT sit anywhere the job can write — that is the whole prerequisite; see
# the header of hooks/tool-gate.sh.
SPAWN_HOOK_DIR="${SPAWN_HOOK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks}"

# spawn::ceiling_allow_set <ceiling> — the tool names a ceiling permits, one per
# line. Empty output means "this ceiling runs no tool gate".
#
# DEFAULT-DENY LIVES HERE. Anything absent is refused, INCLUDING A TOOL THAT DOES
# NOT EXIST YET — the one thing a deny list structurally cannot do. Adding a name
# is a security decision, not a convenience; the list is short on purpose.
#
# Only the REPO-BOUNDED ceiling is gated. The operator ceiling is the path where
# a human invoked the job and is present to answer for it; it deliberately runs
# under the operator's own settings, and narrowing it here would break that
# without protecting anyone who is not already watching.
spawn::ceiling_allow_set() {
    case "$1" in
        "$SPAWN_CEILING_REPO")
            # Read/Write/Edit are the work; their PATH scoping still comes from
            # the rendered `permissions` block. This gate answers "which tool",
            # never "which path", so the two layers stay independent and neither
            # silently substitutes for the other.
            printf '%s\n' Read Write Edit Glob Grep TodoWrite Skill ToolSearch
            ;;
        *) printf '' ;;
    esac
}

# The config a ceiling resolves to, honouring the user's override (R25). Prints
# the path; prints nothing and returns 1 for an unknown ceiling, because
# guessing a ceiling is the one mistake this file must not make quietly.
spawn::ceiling_config() {
    case "$1" in
        "$SPAWN_CEILING_OPERATOR")
            printf '%s' "${SPAWN_CEILING_CONFIG_OPERATOR:-$SPAWN_CEILING_DIR/operator.settings.json}" ;;
        "$SPAWN_CEILING_REPO")
            printf '%s' "${SPAWN_CEILING_CONFIG_REPO:-$SPAWN_CEILING_DIR/repo-bounded.settings.json}" ;;
        *) return 1 ;;
    esac
}

# Whether this ceiling narrows the child's setting sources. The operator's own
# settings are exactly what an operator-invoked spawn is supposed to run under,
# so the operator ceiling leaves the sources alone; the repo-bounded ceiling
# drops `user`, which is the whole reason a child can be narrower than the
# session that launched it.
spawn::ceiling_setting_sources() {
    case "$1" in
        "$SPAWN_CEILING_REPO") printf 'project' ;;
        *) printf '' ;;
    esac
}

# Render the shipped default into a job-local copy, substituting the worktree.
#
# A permission path is only ABSOLUTE when it begins with `//` — measured: a rule
# written `/Users/...` matched nothing, and every write it was meant to permit
# was refused. The template writes `//{{WORKTREE}}/**` and the substitution is
# the absolute path with its leading slash removed.
#
# Rendering is why the ceiling is a copy rather than the shipped file itself:
# the bound is "inside THIS worktree", which is not knowable until launch. The
# copy is written 0600 into scratch the caller owns; the shipped default and
# the user's own settings are only ever READ.
#
# $1 = ceiling, $2 = worktree (absolute), $3 = destination path.
spawn::ceiling_render() {
    local ceiling="$1" worktree="$2" dest="$3" src
    src="$(spawn::ceiling_config "$ceiling")" || return 1
    [ -f "$src" ] || return 1
    # sed's replacement is delimited with | because a path is full of slashes;
    # a worktree path containing | or & would corrupt the rule, so both are
    # refused rather than escaped — a mangled permission rule is an allow that
    # silently is not one.
    case "$worktree" in
        *'|'*|*'&'*|*'\'*) return 1 ;;
    esac
    ( umask 077; sed "s|{{WORKTREE}}|${worktree#/}|g" "$src" > "$dest" ) || return 1
    [ -s "$dest" ] || return 1

    # THE OUTER WALL. The rendered permissions above are real enforcement, but a
    # bypass flag defeats them; the tool gate holds even then (measured
    # 2026-08-14 — see hooks/tool-gate.sh). It is injected here, into the job's
    # own copy, so the shipped file stays a readable statement of policy and the
    # absolute hook path never has to be committed.
    local allow_set
    allow_set="$(spawn::ceiling_allow_set "$ceiling")"
    [ -n "$allow_set" ] || return 0   # ungated ceiling: nothing more to do

    local gate
    gate="$SPAWN_HOOK_DIR/tool-gate.sh"
    # A gate that is not there must not degrade to "no gate". Rendering fails,
    # the caller dies, and no child starts — the same posture the file already
    # takes when a ceiling config is unreadable.
    [ -r "$gate" ] || return 1

    # The hook command is a SHELL STRING. A path carrying a quote, a backslash,
    # a $ or a backtick would break out of it and run as code, so refuse rather
    # than escape — the same reasoning as the worktree guard above.
    case "$gate" in
        *'"'*|*'\'*|*'$'*|*'`'*|*"'"*) return 1 ;;
    esac

    python3 - "$dest" "$gate" $allow_set <<'PYH' || return 1
import json, re, sys
dest, gate, tools = sys.argv[1], sys.argv[2], sys.argv[3:]
# Closed by CONSTRUCTION, not filtered: a name outside this grammar never reaches
# a shell string. The allow set is a plugin constant today, but this is the join
# where a future caller-supplied name would arrive.
if not tools or not all(re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', t) for t in tools):
    sys.exit(1)
raw = open(dest).read()
data = json.loads(re.sub(r'^\s*//.*$', '', raw, flags=re.M))
hooks = data.setdefault("hooks", {})
# Replace rather than append: a rendered copy is built fresh at every launch, so
# a second entry would mean the gate ran twice, not that two gates applied.
hooks["PreToolUse"] = [{
    "matcher": "*",
    "hooks": [{"type": "command", "command": " ".join([gate] + tools)}],
}]
json.dump(data, open(dest, "w"), indent=2)
PYH
    [ -s "$dest" ] || return 1
    return 0
}

# spawn::ceiling_grantable <tool> — may this tool be granted to a job at all?
#
# DEFAULT-DENY, and short on purpose. A grant widens the one ceiling that exists
# because nobody is watching, so the question is not "is this tool useful" but
# "is it safe to hand an unattended process". Adding a name here is a security
# decision, not a convenience.
#
# GRANTABLE, and what each one costs:
#   WebSearch     — a search API. Narrow, and the reason WebFetch below is not.
#   Bash          — arbitrary local execution. Granting it is not "a wider
#                   ceiling"; it is NO ceiling. Read the next block before
#                   adding a caller path that passes it.
#
# WHAT A Bash GRANT ACTUALLY HANDS OVER
# --------------------------------------
# ESTABLISHED by reading the tree. Every other bound here is TOOL-scoped: the
# `Write(//<worktree>/**)` rules bind the Write tool, not a shell. A granted
# shell writes wherever the invoking OS user can, which includes this plugin
# tree (hooks/tool-gate.sh among it), the job's own rendered ceiling under
# `<worktree>/.spawn/job-*/`, and that job's own record beside it. The gate's
# header used to claim the plugin tree was unreachable; that was true of
# Write/Edit and never of a shell, and the claim is gone.
#
# ESTABLISHED by what the child is handed. bg-agent.sh exports the gateway
# token into the child's environment (ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY).
# A granted shell reads its own environment, so the grant hands over that
# credential, plus everything else the OS user can read — ~/.claude, SSH keys,
# push rights. KTD6 keeps that token out of the process table; a shell walks
# around that entirely.
#
# MEASURED ONCE (2026-08-25), AND IT ESTABLISHES LESS THAN IT LOOKS LIKE. An arm
# in tests/unit/ceilings.bats granted a real child Bash and told it to write a
# probe, overwrite its own gate copy with `exit 0`, then call WebSearch:
#   bash_used=yes   bash_denied=no   gate_rewritten=no   websearch_reached=no
# The shell genuinely worked — the probe landed — and the gate copy was writable
# by the same OS user, so NOTHING PREVENTED the rewrite. The model declined it.
# Model reluctance is not a bound: another model, another prompt, or a job that
# reaches the file as a side effect is not bound by it. So the escalation did
# not happen there; it is NOT established that it cannot. Still unmeasured:
# whether the harness re-reads the hook registration from --settings mid-session,
# and whether `permissions.deny` keeps refusing those tools once the gate is
# disarmed. Claim no more than this.
#
# THE BLAST RADIUS OUTLIVES THE JOB. tool-gate.sh is ONE shared file, named by
# absolute path from every rendered ceiling. A granted job that rewrites it
# removes the outer wall for every LATER job on this machine, including jobs
# whose caller granted nothing. So "an ungranted job cannot run a shell command"
# holds for an untampered install, and only for one. There is no technical fix
# — an integrity check would live in the same writable tree — which is why the
# honest statement IS the mitigation.
#
# BARE NAME ONLY. There is no command-scoped form: the gate matches the tool
# NAME (matching tool_input is pattern-matching shell text, which this repo has
# three CVEs' worth of reasons to refuse), and a grant writes the bare name into
# permissions.allow, which subsumes any `Bash(npm test:*)` rule sitting beside
# it. A caller asking for a scoped grant is told that, rather than handed a
# bound that is not one.
#
# NOT grantable, deliberately, and each for its own reason:
#   Agent, Task*  — an unattended job that can spawn agents fans out unbounded.
#   Cron*         — schedules work that OUTLIVES the job nobody was watching.
#   WebFetch      — fetches an arbitrary URL, including a host on this machine's
#                   private network. A search API is a narrower thing than a
#                   general-purpose fetcher, so it is granted separately or not
#                   at all.
spawn::ceiling_grantable() {
    case "${1:-}" in
        WebSearch|Bash) return 0 ;;
        *) return 1 ;;
    esac
}

# spawn::ceiling_grant <rendered-settings> <tool>...
#
# Adds validated tools to a RENDERED ceiling's allow list, in the job's own copy.
# The shipped default on disk is never touched (R25: the plugin does not edit a
# user's settings, including its own), and the child cannot reach this file to
# widen it further — .spawn writes are denied to it.
#
# TWO LAYERS NOW, AND A GRANT MUST CLEAR BOTH. Since the tool gate default-denies
# by NAME, a tool added only to `permissions.allow` would pass the permission
# layer and then be refused by the gate — a grant that reads as applied and is
# not. So the allow FILE is extended in the same call. The two writes are one
# operation on purpose; splitting them is how they drift.
spawn::ceiling_grant() {
    local dest="$1"; shift
    [ -f "$dest" ] || return 1
    local t
    for t in "$@"; do
        spawn::ceiling_grantable "$t" || {
            printf 'grant_refused\t%s\n' "$(spawn::sanitize_for_display "$t")" >&2
            # A scoped shell grant is the one refusal a caller reads as a typo.
            # Say the shape does not exist, and point nowhere: a custom
            # SPAWN_CEILING_CONFIG_REPO cannot deliver one either, because the
            # gate's allow set is keyed on the ceiling NAME, not on that file.
            case "$t" in
                Bash\(*)
                    printf 'grant_refused_reason\t%s\n' \
                        'no command-scoped shell grant exists: the tool gate matches the bare tool name, and a grant writes bare Bash into permissions.allow, which subsumes any scoped rule. Ask for Bash or for nothing.' >&2 ;;
            esac
            return 1
        }
    done
    python3 - "$dest" "$@" <<'PYG' || return 1
import json, re, sys
dest, tools = sys.argv[1], sys.argv[2:]
raw = open(dest).read()
# The shipped files carry // comments, which json rejects; strip for the read and
# write back plain JSON. The rendered copy is the job's, not a file a human edits.
data = json.loads(re.sub(r'^\s*//.*$', '', raw, flags=re.M))
perms = data.setdefault("permissions", {})
allow = perms.setdefault("allow", [])
deny = perms.setdefault("deny", [])
for t in tools:
    if t not in allow:
        allow.append(t)
# A DENY BEATS AN ALLOW, so the grant must clear the deny entry too — in the
# job's own copy only. The shipped default no longer denies a grantable tool,
# but a user pointing SPAWN_CEILING_CONFIG_REPO at their own file may still
# deny it, and then a grant would extend the allow list AND the gate argv and
# be refused anyway: applied on paper, refused in practice, with nothing in the
# record saying which layer said no. Only the bare tool name is removed; a
# scoped rule like Bash(rm:*) is a different entry and is deliberately left in
# place, because dropping a caller's own narrowing is not this function's call.
while any(t in deny for t in tools):
    for t in tools:
        if t in deny:
            deny.remove(t)
json.dump(data, open(dest, "w"), indent=2)
PYG

    # The gate's half of the grant: extend the allow set in the hook's argv. Only
    # when this ceiling is gated at all — an ungated ceiling has no hook, and
    # inventing one here would install a gate the renderer never chose.
    python3 - "$dest" "$@" <<'PYG2' || return 1
import json, re, sys
dest, tools = sys.argv[1], sys.argv[2:]
if not all(re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', t) for t in tools):
    sys.exit(1)
data = json.loads(re.sub(r'^\s*//.*$', '', open(dest).read(), flags=re.M))
entries = data.get("hooks", {}).get("PreToolUse", [])
if entries:
    h = entries[0]["hooks"][0]
    parts = h["command"].split()
    for t in tools:
        if t not in parts[1:]:
            parts.append(t)
    h["command"] = " ".join(parts)
    json.dump(data, open(dest, "w"), indent=2)
PYG2
    return 0
}

# The exact flag set a ceiling hands the child, as a global array (bash 3.2 has
# indexed arrays; it does not have `mapfile` or associative arrays).
#
# $1 = ceiling, $2 = the RENDERED settings path (absolute — the child's cwd is
# the worktree, not ours).
spawn::ceiling_flags() {
    local ceiling="$1" settings="$2" sources
    SPAWN_CEILING_FLAGS=()
    sources="$(spawn::ceiling_setting_sources "$ceiling")"
    [ -n "$sources" ] && SPAWN_CEILING_FLAGS+=(--setting-sources "$sources")
    SPAWN_CEILING_FLAGS+=(--settings "$settings")
    SPAWN_CEILING_FLAGS+=(--permission-mode dontAsk)
    return 0
}

# ===========================================================================
# THE SHARED DOOR BODY
# ===========================================================================
# Everything below is what an entry point DOES once its ceiling is fixed. It
# lives here rather than in each door so the two doors differ in one constant
# and cannot drift apart in anything else — the security property is "these two
# paths differ only in ceiling", and a copy-pasted body is how that stops being
# true.
#
# CONTRACT (KTD2 owns it; this implements it):
#   exactly one JSON object on stdout, ALWAYS, including every failure path;
#   diagnostics on stderr only.
#   exit 0 ok · 2 usage/refusal · 3 unreachable · 4 alias unknown ·
#        5 the child run failed · 6 deadline exceeded · 7 token rejected.
# Codes 3, 4 and 7 come from `spawnctl.sh ensure` and are propagated unchanged
# (KTD3) — the served-list check has exactly one owner.
# ---------------------------------------------------------------------------
EX_OK=0
EX_USAGE=2
EX_UNREACHABLE=3
EX_UPSTREAM=5
EX_DEADLINE=6
# 7 is the frozen enum's auth code. Defined HERE because this file is sourced
# standalone by the door scripts: a review found the die call below was reading
# an UNSET EX_AUTH and living entirely on its `:-7` default, while the comment
# claimed it used the shared constant. Same shape as the bug this file fixes.
EX_AUTH=7

CLAUDE_BIN="${SPAWN_CLAUDE_BIN:-claude}"

# The child is bounded. An unattended run with no deadline is indistinguishable
# from work in progress forever, which is the same failure R9 exists to close
# from the other end. U9 replaces this synchronous poll with detached
# supervision; the bound itself does not go away.
JOB_TIMEOUT="${SPAWN_BG_TIMEOUT:-900}"

EMITTED=0
HELP_REQUESTED=false
ALIAS=""
CHILD_PID=""
TMPWORK=""

# This surface's own error vocabulary, falling through to the shared table in
# common.sh (R12). Keyed on the ENUM so two sites sharing a value cannot hand a
# caller two different repairs.
remedy_for() {
    case "$1" in
        ceiling_unavailable)
            printf 'The permission configuration for this ceiling could not be read or rendered, so no child was started — a job with no ceiling is exactly what must not run. Check the file named in `detail` exists and is readable, or point SPAWN_CEILING_CONFIG_OPERATOR / SPAWN_CEILING_CONFIG_REPO at your own copy.' ;;
        child_failed)
            printf 'The child session exited non-zero, so nothing was supervised and no result is claimed. Read `detail` and the stderr this printed. Note that the opposite — a clean exit — is not evidence work happened: a fully denied child returns 0.' ;;
        *) spawn::remedy_for "$1" ;;
    esac
}

emit_error() {
    # $1 = exit code, $2 = error enum, rest = human detail.
    local code="$1" err="$2"; shift 2
    [ "$EMITTED" -eq 1 ] && return 0
    local detail rem
    detail="$(spawn::sanitize_for_display "$*")"
    rem="${REMEDY:-}"
    [ -n "$rem" ] || rem="$(remedy_for "$err")"
    if command -v jq >/dev/null 2>&1; then
        emit "$(jq -nc --arg e "$err" --arg d "$detail" --arg r "$rem" \
            --arg c "$CEILING" --arg a "$ALIAS" --argjson x "$code" \
            --argjson h "$HELP_REQUESTED" \
            "$(spawn::envelope_jq plugin)"' + {ok:false, error:$e, detail:$d,
              remedy:(if $r == "" then null else $r end),
              ceiling:$c, alias:(if $a == "" then null else $a end),
              ceiling_config:null, setting_sources:null, permission_mode:null,
              child_flags:null, child_exit_code:null, child_is_error:null,
              cwd:null, worktree:null, base_url:null, session_id:null,
              help_requested:$h, exit_code:$x}')" && return 0
    fi
    # The no-jq tier. Same envelope, same constants, no encoder (R23 / KTD7).
    emit "$(spawn::envelope_bash plugin "$err" "$code" \
        ',"ceiling":null,"alias":null,"ceiling_config":null,"setting_sources":null,"permission_mode":null,"child_flags":null,"child_exit_code":null,"child_is_error":null,"cwd":null,"worktree":null,"base_url":null,"session_id":null,"help_requested":false' \
        "$rem")"
    return 0
}

need_jq() {
    command -v jq >/dev/null 2>&1 || {
        printf '✗ jq is required (the contract is one JSON object on stdout)\n' >&2
        emit "$(spawn::envelope_bash plugin "usage" 2 \
            ',"ceiling":null,"alias":null,"ceiling_config":null,"setting_sources":null,"permission_mode":null,"child_flags":null,"child_exit_code":null,"child_is_error":null,"cwd":null,"worktree":null,"base_url":null,"session_id":null,"help_requested":false' \
            "Install jq (brew install jq). Every response from this plugin is one JSON object, so there is no degraded mode to fall back to.")"
        exit 2; }
}

# TERM → bounded poll → KILL → reap. Reaping matters as much as signalling: an
# unreaped child re-parented to init keeps the gateway token in its environment
# for as long as it lives (KTD6).
reap_child() {
    [ -n "$CHILD_PID" ] || return 0
    kill -TERM "$CHILD_PID" 2>/dev/null
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        kill -0 "$CHILD_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$CHILD_PID" 2>/dev/null && kill -KILL "$CHILD_PID" 2>/dev/null
    wait "$CHILD_PID" 2>/dev/null
    CHILD_PID=""
    return 0
}

# Sets $TMPWORK. Deliberately NOT "prints the path": called as $(tmpwork) the
# assignment would happen in a subshell and the EXIT trap would remove nothing.
tmpwork() {
    if [ -z "$TMPWORK" ]; then
        TMPWORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/gwceil.XXXXXX")" || {
            printf '✗ cannot create a temp dir\n' >&2
            REMEDY="Point TMPDIR at a writable directory and call again. Nothing was started, so nothing is orphaned." \
                emit_error 2 "usage" "cannot create a temp dir under ${TMPDIR:-/tmp}"
            exit 2; }
    fi
}

# Identifiers are closed by CONSTRUCTION, not filtered (KTD5): an alias that is
# not [A-Za-z0-9._-] never reaches a message, a URL or a process argument.
# Both interpolated values are plugin CONSTANTS, not caller or model input —
# but the terminal-sink lint is structural on purpose and does not know that,
# and an exemption argued per site is how the class re-opens. Routed through
# say() like every other diagnostic in this file.
spawn::ceiling_usage() {
    say "usage: $ENTRY_POINT --alias <name> [--cwd <dir>] [--prompt-file <file>]"
    say "the task prose is piped on stdin or passed with --prompt-file"
    say "this entry point hands its child the '$CEILING' ceiling; no argument changes that"
}

spawn::ceiling_describe() {
    local cfg sources tmo
    cfg="$(spawn::ceiling_config "$CEILING")" || cfg=""
    sources="$(spawn::ceiling_setting_sources "$CEILING")"
    # --describe must answer even when SPAWN_BG_TIMEOUT is garbage: the
    # contract is the one thing a caller reads to find out it set it wrong.
    tmo="$JOB_TIMEOUT"
    [[ "$tmo" =~ ^[0-9]+(\.[0-9]+)?$ ]] || tmo="null"
    emit "$(jq -nc \
        --arg surface "$ENTRY_POINT" \
        --arg ceiling "$CEILING" \
        --arg caller "$CEILING_CALLER" \
        --arg summary "$CEILING_SUMMARY" \
        --arg cfg "$cfg" \
        --arg sources "$sources" \
        --argjson timeout "$tmo" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:true, exit_code:0, response_kind:"describe",
          surface:$surface,
          summary:$summary,
          ceiling:$ceiling,
          intended_caller:$caller,
          ceiling_config:$cfg,
          ceiling_selectable:false,
          setting_sources:(if $sources == "" then null else $sources end),
          permission_mode:"dontAsk",
          child_deadline_seconds:$timeout,
          flags:[
            {name:"--alias",       value:"name", required:true,  default:null, note:"exactly one resolved alias; no fan-out, no chain resolution here"},
            {name:"--cwd",         value:"dir",  required:false, default:"the process working directory", note:"the directory the child runs in and the worktree the repo-bounded ceiling is scoped to"},
            {name:"--prompt-file", value:"file", required:false, default:"stdin", note:"the task prose; travels by file or stdin, never argv"},
            {name:"--help",        value:null,   required:false, default:null, note:"exit 2 with help_requested:true — not a usage error"},
            {name:"--describe",    value:null,   required:false, default:null, note:"this document; exit 0; needs no gateway"}
          ],
          exit_codes:[
            {code:0, error:null,                origin:"own",     meaning:"the child ran to completion under this ceiling"},
            {code:2, error:"usage",             origin:"own",     meaning:"a caller mistake, help, or a refusal"},
            {code:3, error:"unreachable",       origin:"spawnctl",meaning:"the gateway is not answering"},
            {code:4, error:"alias_unknown",     origin:"spawnctl",meaning:"the gateway does not serve that alias"},
            {code:5, error:"child_failed",      origin:"own",     meaning:"the child session exited non-zero"},
            {code:6, error:"deadline_exceeded", origin:"own",     meaning:"the child outran SPAWN_BG_TIMEOUT and was reaped"},
            {code:7, error:"auth_rejected",     origin:"spawnctl",meaning:"the gateway refused the token"}
          ],
          response_fields:[
            {name:"schema",          always:true,  note:"the version of this contract"},
            {name:"ok",              always:true,  note:"boolean; agrees with exit_code"},
            {name:"error",           always:true,  note:"enum value or null, never prose"},
            {name:"remedy",          always:true,  note:"what to do about it; null only on success"},
            {name:"detail",          always:true,  note:"human-readable diagnostic; the only prose field"},
            {name:"content_trust",   always:true,  note:"how far the payload may be trusted"},
            {name:"content_notice",  always:true,  note:"the rule that follows from content_trust"},
            {name:"exit_code",       always:true,  note:"the process exit status, restated in the data"},
            {name:"ceiling",         always:true,  note:"which ceiling this entry point hands down; fixed, not selectable"},
            {name:"ceiling_config",  always:false, note:"the settings file the ceiling was read from, shipped default or user override"},
            {name:"setting_sources", always:false, note:"what the child loads; null means the caller’s own sources are left alone"},
            {name:"permission_mode", always:false, note:"always dontAsk: an unallowed call is refused, never queued behind a prompt"},
            {name:"child_flags",     always:false, note:"the exact permission flags handed to the child, in order"},
            {name:"child_exit_code", always:false, note:"the child process status. NEVER evidence that work happened — a fully denied child exits 0"},
            {name:"child_is_error",  always:false, note:"what the child CLI said about its own turn; a claim, not a finding"},
            {name:"worktree",        always:false, note:"the tree the repo-bounded ceiling is scoped to"},
            {name:"help_requested",  always:false, note:"true only for --help; present on every error response"}
          ],
          ceiling_notes:[
            "The ceiling is fixed by WHICH ENTRY POINT was run (R8). There is no flag that selects it, because a flag would be self-declared and any agent able to run the script could claim to be the operator.",
            "The bound is enforced by the harness, not by this plugin (KD10). This script chooses a permission configuration and hands it down; it polices nothing.",
            "Every bound in the repo-bounded default is a REFUSAL, not a tool removal, so a blocked call is attempted and leaves a denial a supervisor can observe (R9).",
            "The plugin never edits a user’s own settings. Override with SPAWN_CEILING_CONFIG_OPERATOR / SPAWN_CEILING_CONFIG_REPO, or by editing the shipped file."
          ]
        }')" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# spawn::ceiling_main "$@" — the door body.
#
# The caller (an entry point script) has already fixed CEILING, ENTRY_POINT,
# CEILING_CALLER and CEILING_SUMMARY as constants. Nothing below reads them
# from an argument, and no argument this function accepts can change them.
# ---------------------------------------------------------------------------
spawn::ceiling_main() {
    trap spawn::cleanup_tmpwork EXIT
    # bash does not run an EXIT trap when the shell dies on an untrapped
    # INT/TERM/HUP, so these exit THROUGH the EXIT path rather than around it.
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    local PROMPT_FILE="" CWD_ARG=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --alias)         ALIAS="${2:-}"; shift; shift 2>/dev/null || true ;;
            --alias=*)       ALIAS="${1#*=}"; shift ;;
            --prompt-file)   PROMPT_FILE="${2:-}"; shift; shift 2>/dev/null || true ;;
            --prompt-file=*) PROMPT_FILE="${1#*=}"; shift ;;
            --cwd)           CWD_ARG="${2:-}"; shift; shift 2>/dev/null || true ;;
            --cwd=*)         CWD_ARG="${1#*=}"; shift ;;
            --describe)      need_jq
                             # Answered before --alias is required and long
                             # before preflight, so it holds with the gateway
                             # down and with no config on the box (R10).
                             spawn::ceiling_describe || die "$EX_USAGE" "usage" "could not encode the describe object"
                             exit "$EX_OK" ;;
            -h|--help)       # R11: same exit code, same enum, different FIELD.
                             HELP_REQUESTED=true
                             spawn::ceiling_usage; need_jq
                             REMEDY="Nothing is broken — this was a help request, and exit 2 is what the frozen enum has for it. Branch on help_requested, not on the code. Call --describe for the same contract as data." \
                                 die "$EX_USAGE" "usage" "help requested" ;;
            *)               need_jq
                             REMEDY="Pass the task prose on stdin or with --prompt-file, not as a bare argument. Run --describe for the flags this entry point accepts. There is no flag that changes the ceiling — that is the point of having two entry points." \
                                 die "$EX_USAGE" "usage" "unexpected argument '$1'" ;;
        esac
    done

    need_jq

    [ -n "$ALIAS" ] || { spawn::ceiling_usage; REMEDY="Pass exactly one --alias. 'spawnctl.sh status' lists what the gateway serves." \
        die "$EX_USAGE" "usage" "--alias is required"; }
    spawn::validate_alias_name "$ALIAS"

    [[ "$JOB_TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$(awk -v v="$JOB_TIMEOUT" 'BEGIN{print (v > 0)}')" = "1" ] \
        || REMEDY="Set SPAWN_BG_TIMEOUT to a positive number of seconds, or unset it for the default. Zero would mean an unbounded unattended run, which nobody can tell from work in progress." \
            die "$EX_USAGE" "usage" "SPAWN_BG_TIMEOUT must be a POSITIVE number of seconds, got '$JOB_TIMEOUT'"

    # -----------------------------------------------------------------------
    # Pin the working directory, then resolve the worktree the ceiling is
    # scoped to. PHYSICAL path: on macOS /tmp is a symlink to /private/tmp, and
    # a permission rule written against the logical path would not match the
    # path the CLI resolves — an allow that silently is not one.
    # -----------------------------------------------------------------------
    local PIN_CWD WORKTREE
    if [ -n "$CWD_ARG" ]; then
        [ -d "$CWD_ARG" ] || REMEDY="Pass --cwd an existing directory, or omit it to use the current one." \
            die "$EX_USAGE" "usage" "--cwd '$CWD_ARG' is not a directory"
        PIN_CWD="$(cd "$CWD_ARG" 2>/dev/null && pwd -P)" || REMEDY="Pass --cwd a directory this process can enter." \
            die "$EX_USAGE" "usage" "cannot enter --cwd '$CWD_ARG'"
    else
        PIN_CWD="$(pwd -P)"
    fi
    WORKTREE="$(cd "$PIN_CWD" && git rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$WORKTREE" ] || WORKTREE="$PIN_CWD"
    WORKTREE="$(cd "$WORKTREE" 2>/dev/null && pwd -P)" || WORKTREE="$PIN_CWD"

    # -----------------------------------------------------------------------
    # The task prose. By file or stdin, never argv (R24) — argv is readable
    # from the process table.
    # -----------------------------------------------------------------------
    local PROMPT=""
    if [ -n "$PROMPT_FILE" ]; then
        [ -f "$PROMPT_FILE" ] && [ -r "$PROMPT_FILE" ] \
            || REMEDY="Point --prompt-file at a readable file, or pipe the prose on stdin instead." \
                die "$EX_USAGE" "usage" "--prompt-file '$PROMPT_FILE' is not a readable file"
        PROMPT="$(cat "$PROMPT_FILE")"
    else
        if [ -t 0 ]; then
            spawn::ceiling_usage
            REMEDY="Pipe the task prose on stdin or pass --prompt-file. Reading a terminal would block forever, which an unattended caller cannot tell from work in progress." \
                die "$EX_USAGE" "usage" "no task prose: stdin is a terminal and --prompt-file was not given"
        fi
        PROMPT="$(cat)"
    fi
    [ -n "$PROMPT" ] || REMEDY="Send non-empty task prose. Check that whatever produced it on stdin actually wrote something." \
        die "$EX_USAGE" "usage" "the task prose is empty"

    # -----------------------------------------------------------------------
    # The ceiling. Rendered BEFORE preflight: a child with no ceiling must
    # never start, and finding that out after the gateway handshake would mean
    # discovering it later for no benefit.
    # -----------------------------------------------------------------------
    tmpwork
    local WORK="$TMPWORK" SETTINGS CEILING_SRC
    SETTINGS="$WORK/ceiling.settings.json"
    CEILING_SRC="$(spawn::ceiling_config "$CEILING")" || CEILING_SRC=""
    spawn::ceiling_render "$CEILING" "$WORKTREE" "$SETTINGS" \
        || REMEDY="$(remedy_for ceiling_unavailable)" \
            die "$EX_USAGE" "ceiling_unavailable" "could not render the '$CEILING' ceiling from '$CEILING_SRC' for worktree '$WORKTREE' — no child was started"
    spawn::ceiling_flags "$CEILING" "$SETTINGS"
    say "ceiling '$CEILING' from $CEILING_SRC, scoped to $WORKTREE"

    # -----------------------------------------------------------------------
    # Preflight: spawnctl.sh ensure <alias>. The served-list check and its
    # exit 4 come from ONE place (KTD3); the CODE propagates unchanged and the
    # OBJECT is rewrapped onto this vocabulary with ensure's own under
    # `preflight` (R3).
    # -----------------------------------------------------------------------
    local ENSURE_OUT ENSURE_RC PRE_ENUM PRE_JSON PRE_DETAIL PRE_REMEDY
    ENSURE_OUT="$(bash "$CTL" ensure "$ALIAS")"
    ENSURE_RC=$?
    if [ "$ENSURE_RC" -ne 0 ]; then
        PRE_ENUM="$(spawn::enum_for_code "$ENSURE_RC")"
        [ -n "$PRE_ENUM" ] || PRE_ENUM="preflight_failed"
        PRE_JSON="$(printf '%s' "$ENSURE_OUT" | jq -c '.' 2>/dev/null)" || PRE_JSON=""
        [ -n "$PRE_JSON" ] || PRE_JSON="null"
        PRE_DETAIL="$(printf '%s' "$ENSURE_OUT" | jq -r '.detail // .error // empty' 2>/dev/null)"
        [ -n "$PRE_DETAIL" ] || PRE_DETAIL="spawnctl ensure failed with code $ENSURE_RC and printed nothing"
        PRE_REMEDY="$(remedy_for "$PRE_ENUM")"
        emit "$(jq -nc --arg a "$ALIAS" --arg e "$PRE_ENUM" \
            --arg d "$(spawn::sanitize_for_display "$PRE_DETAIL")" \
            --arg r "$PRE_REMEDY" --arg c "$CEILING" \
            --argjson p "$PRE_JSON" --argjson x "$ENSURE_RC" \
            "$(spawn::envelope_jq plugin)"' + {ok:false, alias:$a, ceiling:$c,
              ceiling_config:null, setting_sources:null, permission_mode:null,
              child_flags:null, child_exit_code:null, child_is_error:null,
              cwd:null, worktree:null, base_url:null, session_id:null,
              error:$e, detail:$d, preflight:$p, help_requested:false,
              remedy:(if $r == "" then null else $r end), exit_code:$x}')" \
            || emit_error "$ENSURE_RC" "$PRE_ENUM" "$PRE_DETAIL"
        exit "$ENSURE_RC"
    fi

    local BASE_URL
    BASE_URL="$(printf '%s' "$ENSURE_OUT" | jq -r '.base_url // empty')"
    [ -n "$BASE_URL" ] || die "$EX_UNREACHABLE" "preflight_failed" "spawnctl ensure returned no base_url"
    BASE_URL="${BASE_URL%/}"

    # Token read locally, from the same server.token the probe reads, with
    # ${VAR} expansion — a child that authenticated with a different token than
    # the probe would pass preflight and then 401 (KTD6). gateway.yaml is READ
    # ONLY; nothing here writes it (R12).
    local TOKEN_AWK CONFIG_PATH TOKEN=""
    TOKEN_AWK='/^[A-Za-z_][A-Za-z0-9_-]*:/ { sec = $0; sub(/:.*$/, "", sec); next } sec == "server" && /^[ \t]+token:/ { v = $0; sub(/^[ \t]*token:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); gsub(/^[\042\047]|[\042\047]$/, "", v); print v; exit }'
    CONFIG_PATH="${SPAWN_CONFIG:-}"
    [ -n "$CONFIG_PATH" ] || CONFIG_PATH="$(printf '%s' "$ENSURE_OUT" | jq -r '.config // empty')"
    if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
        TOKEN="$(expand_env_refs "$(awk "$TOKEN_AWK" "$CONFIG_PATH")")"
    fi
    # The config is only the first half. Without this the comment above promised
    # the opposite of what the code did: on a gateway.yaml with no server.token
    # the probe authenticated via the shared chain and the child got "", i.e.
    # exactly the "pass preflight and then 401" it says it prevents.
    [ -n "$TOKEN" ] || spawn::resolve_token \
        "${SPAWN_KEYCHAIN_SERVICE:-spawn-gateway}" \
        "${SPAWN_KEYCHAIN_ACCOUNT_TOKEN:-gateway-token}"

    # An empty credential is worse than none — the CLI uses it rather than
    # falling back — and it is knowable here, before the child spends a deadline
    # discovering it. EX_AUTH is the frozen enum's auth code; no new code.
    [ -n "$TOKEN" ] || die "$EX_AUTH" "auth_rejected" \
        "no gateway token was resolvable: the config has no server.token, GATEWAY_TOKEN is unset, and the Keychain holds no entry — nothing was started"

    # -----------------------------------------------------------------------
    # The child run.
    #
    # The gateway environment is exported INSIDE the subshell rather than
    # passed as an `env VAR=value` prefix, because `env`'s own argv would then
    # carry the token and be readable from the process table (KTD6). The
    # subshell is also where the cwd is pinned.
    #
    # The child runs in the BACKGROUND and this process polls, for the same two
    # reasons launch.sh does: the deadline (there is no timeout(1) on macOS),
    # and cancellation (bash defers traps while blocked on a FOREGROUND child,
    # so a TERM to this script would be ignored until the child finished).
    # U9 replaces this with detached supervision; the reaping does not change.
    # -----------------------------------------------------------------------
    local CHILD_OUT="$WORK/child.json" CHILD_ERR="$WORK/child.err"
    (
        cd "$PIN_CWD" || exit 127
        export ANTHROPIC_BASE_URL="$BASE_URL"
        export ANTHROPIC_AUTH_TOKEN="$TOKEN"
        export ANTHROPIC_API_KEY="$TOKEN"
        exec "$CLAUDE_BIN" "${SPAWN_CEILING_FLAGS[@]}" \
            --model "$ALIAS" --output-format json -p "$PROMPT"
    ) > "$CHILD_OUT" 2> "$CHILD_ERR" &
    CHILD_PID=$!

    local TICKS waited=0
    TICKS="$(awk -v t="$JOB_TIMEOUT" 'BEGIN{print int(t * 5)}')"
    while kill -0 "$CHILD_PID" 2>/dev/null; do
        if [ "$waited" -ge "$TICKS" ]; then
            reap_child
            die "$EX_DEADLINE" "deadline_exceeded" "the child under the '$CEILING' ceiling exceeded ${JOB_TIMEOUT}s (SPAWN_BG_TIMEOUT) — it was stopped and reaped, nothing is still running"
        fi
        sleep 0.2
        waited=$((waited + 1))
    done
    wait "$CHILD_PID"
    local CHILD_RC=$?
    CHILD_PID=""

    if [ "$CHILD_RC" -ne 0 ]; then
        say "the child exited $CHILD_RC; last stderr from $CLAUDE_BIN:"
        # KTD5 free-form sink: a child process's stderr, relaying a
        # non-Anthropic model's output. Piped through the sanitizer.
        tail -5 "$CHILD_ERR" 2>/dev/null | spawn::sanitize_stream >&2
        die "$EX_UPSTREAM" "child_failed" "the child under the '$CEILING' ceiling exited $CHILD_RC"
    fi

    # What the child SAID about itself is a claim, carried as data and never
    # read as a finding: a fully denied child returns is_error:false and exit 0
    # (measured). Classification belongs to the supervisor (U9), which measures
    # effects against a baseline rather than asking the child.
    local CHILD_IS_ERROR SESSION_ID
    CHILD_IS_ERROR="$(jq -r 'if type=="object" and has("is_error") then (.is_error|tostring) else "null" end' < "$CHILD_OUT" 2>/dev/null)"
    [ -n "$CHILD_IS_ERROR" ] || CHILD_IS_ERROR="null"
    SESSION_ID="$(jq -r '.session_id // empty' < "$CHILD_OUT" 2>/dev/null)"
    case "$SESSION_ID" in
        ""|*[!A-Za-z0-9._-]*) SESSION_ID="" ;;
    esac

    local SOURCES FLAGS_JSON
    SOURCES="$(spawn::ceiling_setting_sources "$CEILING")"
    # Encoded by jq -R, not passed with --args: jq keeps parsing words that
    # LOOK like options even after --args, so `--setting-sources` was read as a
    # jq flag and the whole response failed to encode. Caught by the smoke run;
    # the shape below cannot recur because nothing reaches jq's argv.
    FLAGS_JSON="$(printf '%s\n' "${SPAWN_CEILING_FLAGS[@]}" | jq -Rsc 'split("\n")[:-1]')"
    [ -n "$FLAGS_JSON" ] || FLAGS_JSON="null"
    emit "$(jq -nc \
        --arg c "$CEILING" --arg cfg "$CEILING_SRC" --arg a "$ALIAS" \
        --arg s "$SOURCES" --arg w "$WORKTREE" --arg d "$PIN_CWD" \
        --arg b "$BASE_URL" --arg sid "$SESSION_ID" \
        --argjson ie "$CHILD_IS_ERROR" --argjson rc "$CHILD_RC" \
        --argjson f "$FLAGS_JSON" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:true, error:null, remedy:null, exit_code:0,
          ceiling:$c, ceiling_config:$cfg,
          setting_sources:(if $s == "" then null else $s end),
          permission_mode:"dontAsk",
          child_flags:$f,
          alias:$a, cwd:$d, worktree:$w, base_url:$b,
          session_id:(if $sid == "" then null else $sid end),
          child_exit_code:$rc, child_is_error:$ie,
          help_requested:false
        }')" \
        || die "$EX_USAGE" "internal" "could not encode the response object"
    exit "$EX_OK"
}

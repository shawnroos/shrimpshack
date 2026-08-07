#!/usr/bin/env bash
# launch.sh — materialize a Claude Code session on a gateway alias (plan U4).
#
#   printf 'review this design' | launch.sh --alias gpt-sol
#   launch.sh --alias kimi --prompt-file ./seed.md --cwd ~/projects/thing
#
# The plugin NEVER opens a terminal. It runs the seed prompt headlessly through
# `claude`, which materializes the session on disk, and then prints a handle
# Shawn can attach with on his own terms (F2, R8, R9).
#
# CONTRACT (KTD2 owns it; this file implements it, it does not redefine it):
#   exactly one JSON object on stdout, ALWAYS, including every failure path;
#   diagnostics on stderr only.
#   exit 0 ok · 2 usage/refusal · 3 unreachable · 4 alias unknown ·
#        5 upstream provider error · 6 deadline exceeded · 7 token rejected.
#
# Codes 3, 4 and 7 are NOT re-derived here. They come from
# `spawnctl.sh ensure <alias>`, so the served-list check and the auth
# classification have exactly one owner (KTD3). The failure OBJECT is rewrapped
# onto this script's own vocabulary with ensure's object under `preflight`
# (R3); the code propagates unchanged. A seed run that fails is code 5.
#
# The seed run has a code-6 DEADLINE, owned by this process (R2): the child
# runs in the background, the parent polls with the deadline and, on expiry or
# on cancellation, escalates TERM → poll → KILL and REAPS it — the same
# escalation spawnctl's stop uses. The earlier "no deadline" rationale argued
# against a DETACHED watchdog, which leaves a window where an orphaned agent
# outlives the script; a parent that waits and reaps has no such window,
# whereas no deadline at all meant a caller-imposed timeout orphaned `claude`
# on init still holding the gateway token in its environment.
#
# KTD6 — the token never prints and never appears in a process argument:
#   * the seed child receives it through the ENVIRONMENT, never argv;
#   * the printed attach command carries a token REFERENCE (a command
#     substitution that reads the same config at attach time), never the
#     literal. Nothing this script writes to stdout or stderr contains it.
#
# KTD7 — the context window comes from the plugin-local models.json table and is
# applied via CLAUDE_CODE_MAX_CONTEXT_TOKENS. An alias absent from the table
# still launches; the drift is a stderr warning naming the alias, because
# refusing to launch on an unlisted alias would make the table a gate rather
# than metadata.
#
# set -e is deliberately OFF (only -u -o pipefail). Every failure path here is
# an exit code the contract names; letting bash exit on the first non-zero
# command would turn a classified 5 into an unclassified 1 with no JSON.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$SCRIPT_DIR/spawnctl.sh"

# KTD5. Sourced, not re-implemented. Two untrusted sources reach this script's
# terminal output: the seed child's stderr (piped through the stream filter) and
# the session id the child reports (an identifier, so it is closed by the same
# grammar the alias uses rather than filtered). See README.md for the matrix.
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"

# Same reason, applied to the plain helpers: expand_env_refs and emit were
# byte-identical copies across the three scripts.
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------
EX_OK=0
EX_USAGE=2
EX_UNREACHABLE=3
# EX_ALIAS=4 and EX_AUTH=7 are propagated from `ensure`, never produced here.
EX_UPSTREAM=5
EX_DEADLINE=6

# ---------------------------------------------------------------------------
# Configuration surface. Every knob is env-overridable so a test can point the
# whole script at fixtures; a test that had to reach the real gateway or spawn
# the real `claude` would either fight a live process or spend real money, and
# both of those are how a "passing" suite stops meaning anything.
# ---------------------------------------------------------------------------
CLAUDE_BIN="${SPAWN_CLAUDE_BIN:-claude}"
MODELS_JSON="${SPAWN_MODELS_JSON:-$SCRIPT_DIR/models.json}"

# Deadline for the seed run (R2). Generous, because a seed turn is a full agent
# turn on a review-sized prompt — but never absent: an unbounded seed run under
# a caller-imposed timeout is how `claude` ended up orphaned on init with the
# gateway token in its environment. Validated below like the lens's --timeout.
SEED_TIMEOUT="${SPAWN_LAUNCH_TIMEOUT:-600}"

# Claude Code keys sessions by project directory. This is the root it encodes
# them under; CLAUDE_CONFIG_DIR is Claude Code's own knob, so honouring it is
# what makes the derived transcript path agree with the one the CLI wrote.
PROJECTS_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
# Every human-readable diagnostic goes through say() or die(), and both
# sanitize (KTD5) — a chokepoint rather than per-site discipline, so a message
# nobody has written yet is closed too.
say() { printf '▸ %s\n' "$(spawn::sanitize_for_display "$*")" >&2; }

# The single stdout write lives in common.sh (emit); EMITTED is this script's
# own state, so it stays declared here — a bash function reads the caller's
# globals dynamically.
EMITTED=0

# R11 — the help discriminator. Same field, same reasoning, same values as
# lens.sh: `-h` and a caller bug are both exit 2 with error:"usage" because the
# enum is frozen (KTD2), and telling them apart used to mean grepping the
# English in `detail`. Rides on every error response, both encoder tiers.
HELP_REQUESTED=false

ALIAS=""

# R12 — launch's own error vocabulary, falling through to the shared table in
# common.sh. Keyed on the ENUM: two sites reporting the same value must not hand
# a caller two different repairs. A narrower site overrides with a `REMEDY=...`
# prefix on die.
remedy_for() {
    case "$1" in
        seed_failed)
            printf 'No session was created, so there is nothing to attach to and nothing to clean up. Read `detail` and the stderr this printed; a seed that fails on its first turn usually means the alias or the token is wrong, not the prompt.' ;;
        no_session_id)
            printf 'The `claude` CLI ran but its JSON no longer carries the field this script reads. That is a plugin-vs-CLI version mismatch, not a caller mistake — no handle is printed rather than one built on a guess.' ;;
        transcript_missing)
            printf 'The CLI reported a session that is not on disk where this script looks. Check CLAUDE_CONFIG_DIR points at the same config directory the CLI used, then run again.' ;;
        *) spawn::remedy_for "$1" ;;
    esac
}

emit_error() {
    # $1 = exit code, $2 = machine-readable error value, rest = human detail.
    local code="$1" err="$2"; shift 2
    [ "$EMITTED" -eq 1 ] && return 0
    # `detail` is human-readable diagnostic text a consumer prints, so it is
    # sanitized (KTD5).
    local detail alias_d
    detail="$(spawn::sanitize_for_display "$*")"
    # The alias is display text on THIS path and only here: emit_error is the
    # one place it can be an alias the grammar REFUSED, so it has not been
    # closed by construction yet. jq escapes a control byte in transit but
    # emits a Unicode bidi override literally, so the field is sanitized.
    alias_d="$(spawn::sanitize_for_display "$ALIAS")"
    # R23: the envelope comes from common.sh, so this tier cannot drift from the
    # success emit below or from the no-jq tier under it. REMEDY is the optional
    # per-site remedy (R12) — a caller sets it as a prefix assignment on die.
    # R12: the site's own REMEDY wins; otherwise the enum's default from the one
    # table. Defaulting here rather than at every die site is what makes "every
    # error names its remedy" a property of the code shape rather than a review
    # item that goes stale on the next site somebody adds.
    local rem="${REMEDY:-}"
    [ -n "$rem" ] || rem="$(remedy_for "$err")"
    local obj=""
    if command -v jq >/dev/null 2>&1; then
        obj="$(jq -nc --arg a "$alias_d" --arg e "$err" --arg d "$detail" \
            --arg r "$rem" --argjson c "$code" --argjson h "$HELP_REQUESTED" \
            "$(spawn::envelope_jq plugin)"' + {ok:false,
              alias:(if $a == "" then null else $a end), session_id:null,
              transcript_path:null, cwd:null, base_url:null, context_window:null,
              attach_command:null, error:$e, detail:$d, help_requested:$h,
              remedy:(if $r == "" then null else $r end), exit_code:$c}')"
    fi
    # Falls through to the pure-bash tier when jq is ABSENT and also when jq is
    # present but errored: that yielded the empty string, emit refused it, and
    # the script exited with nothing on stdout at all.
    # help_requested rides the no-jq tier too — a box without an encoder must
    # still be able to tell a help request from a caller bug, and it is a bash
    # literal, so no encoder is needed for it.
    [ -n "$obj" ] || obj="$(spawn::envelope_bash plugin "$err" "$code" ",\"alias\":null,\"session_id\":null,\"transcript_path\":null,\"attach_command\":null,\"help_requested\":$HELP_REQUESTED")"
    emit "$obj"
}

die() {
    local code="$1" err="$2"; shift 2
    printf '✗ %s\n' "$(spawn::sanitize_for_display "$*")" >&2
    emit_error "$code" "$err" "$*"
    exit "$code"
}

# TMPWORK holds scratch that must not outlive the call — the captured child
# stdout above all, because that is the one place the session id lives before
# it reaches the handle.
TMPWORK=""
CHILD_PID=""

# TERM → bounded poll → KILL → reap (the escalation spawnctl's stop uses).
# Reaping matters as much as signalling: an unreaped `claude` re-parented to
# init keeps the gateway token in its environment for as long as it lives.
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

cleanup() {
    # Kill and reap the seed child before removing the scratch its output is
    # captured to. This is what makes a caller-imposed timeout on THIS script
    # (or a Ctrl-C) end the `claude` underneath instead of orphaning it (R2).
    reap_child
    [ -n "$TMPWORK" ] && rm -rf "$TMPWORK" 2>/dev/null
    return 0
}
trap cleanup EXIT
# bash does NOT run an EXIT trap when the shell dies on an untrapped INT/TERM/HUP
# (measured on this box, bash 5.3.15), so a cancelled launch leaks TMPWORK along
# with the captured child stdout. These exit THROUGH the EXIT path; a bare
# `trap cleanup INT TERM` would run cleanup and then let the script carry on.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Sets $TMPWORK. Deliberately NOT "prints the path": called as $(tmpwork) the
# assignment would happen in a command-substitution SUBSHELL, the parent's
# TMPWORK would stay empty, and the EXIT trap would remove nothing — leaking a
# scratch dir on every single invocation.
tmpwork() {
    if [ -z "$TMPWORK" ]; then
        TMPWORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/gwlaunch.XXXXXX")" || {
            # KTD2 is "exactly one JSON object on stdout, ALWAYS", and that
            # includes this path — it used to exit 2 printing nothing at all.
            printf '✗ cannot create a temp dir\n' >&2
            REMEDY="Point TMPDIR at a writable directory and call again. Nothing was seeded, so no session exists to clean up." \
                emit_error 2 "usage" "cannot create a temp dir under ${TMPDIR:-/tmp}"
            exit 2; }
    fi
}

need_jq() {
    command -v jq >/dev/null 2>&1 || {
        printf '✗ jq is required (the contract is one JSON object on stdout)\n' >&2
        # Same envelope, same constants, no encoder (R23 / KTD7): this is the
        # tier that used to be a hand-written string and drifted from the other
        # two the moment either changed.
        emit "$(spawn::envelope_bash plugin "usage" 2 ",\"alias\":null,\"session_id\":null,\"transcript_path\":null,\"attach_command\":null,\"help_requested\":$HELP_REQUESTED")"
        exit 2
    }
}

# ---------------------------------------------------------------------------
# Alias grammar (KTD5). Checked BEFORE any network call and before the alias is
# ever interpolated into the attach command, so an escape byte or a shell
# metacharacter in an identifier is impossible rather than filtered.
# ---------------------------------------------------------------------------
validate_alias() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "$EX_USAGE" "usage" "alias failed the grammar [A-Za-z0-9._-]+ — refused before any network call"
}

usage() {
    cat >&2 <<'EOF'
usage: launch.sh --alias <alias> [--prompt-file <path>] [--cwd <dir>]

The seed prompt is read from STDIN by default, or from --prompt-file.
--cwd pins the session's project directory (default: the current directory).
Prints one JSON handle: attach_command, session_id, transcript_path, alias,
context_window, cwd, base_url. The gateway token appears in none of them.
EOF
}

# ---------------------------------------------------------------------------
# --describe (R10, R14, KD2). Same arm, same reasoning as lens.sh: the contract
# as data at exit 0, for the consumer that cannot load a command or a skill.
#
# It answers before preflight, so it holds with the gateway down and with no
# config on the box — a caller reads the contract in order to interpret a
# failure, and one that needed a healthy gateway would be missing exactly then.
#
# It does require jq, like every other success-shaped response here: the
# pure-bash tier encodes failures only, because a payload built without an
# encoder means a hand-written envelope, which is the drift R23 closes.
# ---------------------------------------------------------------------------
emit_describe() {
    # SEED_TIMEOUT is env-overridable, so it is a SOURCE: a non-numeric value
    # exported by the caller would make --argjson fail and take down the one arm
    # that must answer under any conditions. Reported as absent instead; the
    # validation below still refuses it on a real launch.
    local ev d_timeout
    if [[ "$SEED_TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then d_timeout="$SEED_TIMEOUT"; else d_timeout="null"; fi
    ev="$(jq -n \
        --arg r_usage "$(remedy_for usage)" \
        --arg r_unreach "$(remedy_for unreachable)" \
        --arg r_alias "$(remedy_for alias_unknown)" \
        --arg r_auth "$(remedy_for auth_rejected)" \
        --arg r_dead "$(remedy_for deadline_exceeded)" \
        --arg r_pre "$(remedy_for preflight_failed)" \
        --arg r_seed "$(remedy_for seed_failed)" \
        --arg r_sid "$(remedy_for no_session_id)" \
        --arg r_tr "$(remedy_for transcript_missing)" \
        '[{value:"usage",             exit_code:2, remedy:$r_usage},
          {value:"unreachable",       exit_code:3, remedy:$r_unreach},
          {value:"alias_unknown",     exit_code:4, remedy:$r_alias},
          {value:"auth_rejected",     exit_code:7, remedy:$r_auth},
          {value:"seed_failed",       exit_code:5, remedy:$r_seed},
          {value:"no_session_id",     exit_code:5, remedy:$r_sid},
          {value:"transcript_missing",exit_code:5, remedy:$r_tr},
          {value:"deadline_exceeded", exit_code:6, remedy:$r_dead},
          {value:"preflight_failed",  exit_code:3, remedy:$r_pre}]')" || return 1

    emit "$(jq -nc --argjson errors "$ev" --argjson timeout "$d_timeout" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:true, error:null, exit_code:0,
          response_kind:"describe",
          surface:"launch.sh",
          summary:"Materialize a Claude Code session on a gateway alias and print a handle to attach with later. Nothing is opened; no terminal is taken over.",
          prompt_input:["stdin","--prompt-file"],
          argv_prompt_accepted:false,
          flags:[
            {name:"--alias",       value:"alias", required:true,  default:null,
             note:"exactly one; grammar [A-Za-z0-9._-]+"},
            {name:"--prompt-file", value:"path",  required:false, default:null,
             note:"alternative to stdin for the seed prompt"},
            {name:"--cwd",         value:"dir",   required:false, default:"the current directory",
             note:"pins the session project directory; resolved to its physical path"},
            {name:"--help",        value:null,    required:false, default:null,
             note:"exit 2 with help_requested:true — not a usage error"},
            {name:"--describe",    value:null,    required:false, default:null,
             note:"this document; exit 0; needs neither a running gateway nor a config"}
          ],
          exit_codes:[
            {code:0, error:null,                origin:"own",
             meaning:"the session exists on disk and the handle is real"},
            {code:2, error:"usage",             origin:"own",
             meaning:"caller bug or help; branch on help_requested"},
            {code:3, error:"unreachable",       origin:"own",
             meaning:"the gateway is down and could not be started"},
            {code:4, error:"alias_unknown",     origin:"propagated",
             meaning:"decided by spawnctl ensure; preflight.served_aliases lists what is served"},
            {code:5, error:"seed_failed",       origin:"own",
             meaning:"past preflight, then the seed run failed; error names the sub-class and no handle is printed"},
            {code:6, error:"deadline_exceeded", origin:"own",
             meaning:"the seed outlived SPAWN_LAUNCH_TIMEOUT; the child was stopped and reaped"},
            {code:7, error:"auth_rejected",     origin:"propagated",
             meaning:"the gateway is up and refused our token"}
          ],
          error_values:$errors,
          response_fields:[
            {name:"schema",          always:true,  note:"the version of this contract"},
            {name:"ok",              always:true,  note:"boolean; agrees with exit_code"},
            {name:"error",           always:true,  note:"enum value or null, never prose"},
            {name:"remedy",          always:true,  note:"what to do about it; null only on success"},
            {name:"detail",          always:true,  note:"human-readable diagnostic; the only prose field"},
            {name:"content_trust",   always:true,  note:"how far the payload may be trusted"},
            {name:"content_notice",  always:true,  note:"the rule that follows from content_trust"},
            {name:"exit_code",       always:true,  note:"the process exit status, restated in the data"},
            {name:"alias",           always:false, note:"the resolved alias, null when none was accepted"},
            {name:"session_id",      always:false, note:"the materialized session; success only"},
            {name:"transcript_path", always:false, note:"the transcript on disk, checked to exist before the handle is printed"},
            {name:"cwd",             always:false, note:"the pinned project directory the handle resolves against"},
            {name:"base_url",        always:false, note:"the gateway base url the session was seeded through"},
            {name:"context_window",  always:false, note:"from the plugin models table; null when the alias is not listed"},
            {name:"attach_command",  always:false, note:"a bash command that resumes the session; carries a token reference, never a token"},
            {name:"preflight",       always:false, note:"spawnctl ensure object on a preflight failure"},
            {name:"help_requested",  always:false, note:"true only for --help; present on every error response"}
          ],
          seed_timeout_seconds:$timeout,
          tools_on_far_side:true,
          token_in_output:false
        }')" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PROMPT_FILE=""
CWD_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --alias)         ALIAS="${2:-}"; shift; shift 2>/dev/null || true ;;
        --alias=*)       ALIAS="${1#*=}"; shift ;;
        --prompt-file)   PROMPT_FILE="${2:-}"; shift; shift 2>/dev/null || true ;;
        --prompt-file=*) PROMPT_FILE="${1#*=}"; shift ;;
        --cwd)           CWD_ARG="${2:-}"; shift; shift 2>/dev/null || true ;;
        --cwd=*)         CWD_ARG="${1#*=}"; shift ;;
        --describe)      need_jq
                         # Answered here, before --alias is required and long
                         # before preflight — so it holds with the gateway down
                         # and with no config on the box (R10).
                         emit_describe || die "$EX_USAGE" "usage" "could not encode the describe object"
                         exit "$EX_OK" ;;
        -h|--help)       # R11: same exit code, same enum, different FIELD. Set
                         # before need_jq so the no-jq tier carries it too.
                         HELP_REQUESTED=true
                         usage; need_jq
                         REMEDY="Nothing is broken — this was a help request, and exit 2 is what the frozen enum has for it. Branch on help_requested, not on the code. Call --describe for the same contract as data." \
                             die "$EX_USAGE" "usage" "help requested" ;;
        *)
            need_jq
            REMEDY="Pass the seed prompt on stdin or with --prompt-file, not as a bare argument. Run --describe for the flags this script accepts." \
            die "$EX_USAGE" "usage" "unexpected argument '$1' — the seed prompt is piped on stdin or passed with --prompt-file"
            ;;
    esac
done

need_jq

[ -n "$ALIAS" ] || { usage; REMEDY="Pass exactly one --alias. 'spawnctl.sh status' lists what the gateway serves." \
    die "$EX_USAGE" "usage" "--alias is required"; }
validate_alias "$ALIAS"

# Positive, not merely numeric — same reasoning as the lens's --timeout (R1):
# 0 would read as "no artificial limit" and mean an unbounded seed run, which
# under an unattended caller looks like work in progress forever.
[[ "$SEED_TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$(awk -v v="$SEED_TIMEOUT" 'BEGIN{print (v > 0)}')" = "1" ] \
    || REMEDY="Set SPAWN_LAUNCH_TIMEOUT to a positive number of seconds, or unset it for the default. Zero would mean an unbounded seed run, which an unattended caller cannot tell from work in progress." \
        die "$EX_USAGE" "usage" "SPAWN_LAUNCH_TIMEOUT must be a POSITIVE number of seconds, got '$SEED_TIMEOUT'"

# ---------------------------------------------------------------------------
# Pin the working directory (U4 step 3).
#
# Resolved to the PHYSICAL path before anything uses it. On macOS /tmp is a
# symlink to /private/tmp, so a logical path would encode to a projects/
# subdirectory that Claude Code never writes — the transcript would be "missing"
# for a reason that has nothing to do with the session. Pinning it also makes
# the handle reproducible from anywhere else, which is what AE3 tests.
# ---------------------------------------------------------------------------
PIN_CWD="$(cd "${CWD_ARG:-$PWD}" 2>/dev/null && pwd -P)"
[ -n "$PIN_CWD" ] || REMEDY="Pass a --cwd that exists and is enterable by this process, or omit it to use the current directory." \
    die "$EX_USAGE" "usage" "--cwd '${CWD_ARG:-$PWD}' is not a directory we can enter"

# ---------------------------------------------------------------------------
# Seed prompt intake. Same discipline as the lens (KTD8): stdin or a file, never
# argv on OUR command line. It is handed to `claude` after -p, which is fine —
# the prompt is not a secret; only the token carries the argv prohibition.
# ---------------------------------------------------------------------------
if [ -n "$PROMPT_FILE" ]; then
    [ -f "$PROMPT_FILE" ] || REMEDY="Check the path exists and is readable by this process, then call again." \
        die "$EX_USAGE" "usage" "--prompt-file '$PROMPT_FILE' is not a readable file"
    PROMPT="$(cat "$PROMPT_FILE")" || REMEDY="Check the file's permissions and that it is a regular file, then call again." \
        die "$EX_USAGE" "usage" "could not read --prompt-file '$PROMPT_FILE'"
else
    if [ -t 0 ]; then
        usage
        REMEDY="Pipe the seed prompt on stdin or pass --prompt-file. Reading a terminal would block forever, which an unattended caller cannot tell from work in progress." \
            die "$EX_USAGE" "usage" "no seed prompt: stdin is a terminal and --prompt-file was not given"
    fi
    PROMPT="$(cat)"
fi
[ -n "$PROMPT" ] || REMEDY="Send a non-empty seed prompt. Check that whatever produced it on stdin actually wrote something." \
    die "$EX_USAGE" "usage" "the seed prompt is empty — a session seeded with nothing is not worth a handle"

# ---------------------------------------------------------------------------
# Preflight (U4 step 1): spawnctl.sh ensure <alias>.
#
# The alias is passed so the served-list check and its exit 4 come from ONE
# place (KTD3): the CODE is ensure's decision and propagates unchanged.
#
# The OBJECT is not forwarded verbatim (R3). ensure's failure object is
# {verb, error:<prose>} — no `attach_command`, no `session_id`, and prose where
# this script's consumers branch on an enum. It is rewrapped onto the launch
# vocabulary (error enum + detail + the null handle fields), with ensure's full
# object under `preflight` so nothing is lost. One object on stdout (KTD2).
# ---------------------------------------------------------------------------
ENSURE_OUT="$(bash "$CTL" ensure "$ALIAS")"
ENSURE_RC=$?
if [ "$ENSURE_RC" -ne 0 ]; then
    # Enum from the CODE, which KTD2 defines — never re-parsed out of prose. The
    # table lives in common.sh (R23), and spawnctl derives its own `error` from
    # the same one, so the two sides agree by construction.
    PRE_ENUM="$(spawn::enum_for_code "$ENSURE_RC")"
    [ -n "$PRE_ENUM" ] || PRE_ENUM="preflight_failed"
    PRE_JSON="$(printf '%s' "$ENSURE_OUT" | jq -c '.' 2>/dev/null)" || PRE_JSON=""
    [ -n "$PRE_JSON" ] || PRE_JSON="null"
    # `detail` first, `error` second: since the enum reconciliation ensure's
    # `error` IS the enum and its prose moved to `detail`.
    PRE_DETAIL="$(printf '%s' "$ENSURE_OUT" | jq -r '.detail // .error // empty' 2>/dev/null)"
    [ -n "$PRE_DETAIL" ] || PRE_DETAIL="spawnctl ensure failed with code $ENSURE_RC and printed nothing"
    # R12: built directly rather than through emit_error, so the remedy is
    # looked up here too — same table, same enum. This is the failure a caller
    # meets most often, and it was the one with no instruction attached.
    PRE_REMEDY="$(remedy_for "$PRE_ENUM")"
    emit "$(jq -nc --arg a "$ALIAS" --arg e "$PRE_ENUM" \
        --arg d "$(spawn::sanitize_for_display "$PRE_DETAIL")" \
        --arg r "$PRE_REMEDY" \
        --argjson p "$PRE_JSON" --argjson c "$ENSURE_RC" \
        "$(spawn::envelope_jq plugin)"' + {ok:false, alias:$a, session_id:null,
          transcript_path:null, cwd:null, base_url:null, context_window:null,
          attach_command:null, error:$e, detail:$d, preflight:$p,
          help_requested:false,
          remedy:(if $r == "" then null else $r end), exit_code:$c}')" \
        || emit_error "$ENSURE_RC" "$PRE_ENUM" "$PRE_DETAIL"
    exit "$ENSURE_RC"
fi

BASE_URL="$(printf '%s' "$ENSURE_OUT" | jq -r '.base_url // empty')"
[ -n "$BASE_URL" ] || die "$EX_UNREACHABLE" "preflight_failed" "spawnctl ensure returned no base_url"
BASE_URL="${BASE_URL%/}"

# ---------------------------------------------------------------------------
# Token resolution (U4 step 5).
#
# Read from the SAME place spawnctl's probe reads it — server.token in the
# resolved gateway.yaml, with ${VAR} expansion — because a session that
# authenticated with a different token than the probe would pass preflight and
# then 401, and that divergence is undebuggable from the outside. gateway.yaml
# is READ ONLY; nothing here writes to it (R12).
#
# When SPAWN_CONFIG is unset, the config path is read out of the `ensure`
# response above rather than from a SECOND spawnctl process running `status`,
# which cost a redundant install-dir resolve, config re-parse and live HTTP
# probe on every launch. Only the path crosses; the token is still read locally,
# from the file, in this process (KTD6).
# ---------------------------------------------------------------------------
# The awk program that reads server.token. Written with OCTAL escapes for the
# quote characters (\042 = " and \047 = ') so the program itself contains no
# quote byte — that is what lets it be embedded, single-quoted and unmangled,
# inside the attach command below.
# Kept to ONE line: it is embedded verbatim in the attach command, and a
# multi-line program there would make a handle nobody can paste.
TOKEN_AWK='/^[A-Za-z_][A-Za-z0-9_-]*:/ { sec = $0; sub(/:.*$/, "", sec); next } sec == "server" && /^[ \t]+token:/ { v = $0; sub(/^[ \t]*token:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); gsub(/^[\042\047]|[\042\047]$/, "", v); print v; exit }'

CONFIG_PATH="${SPAWN_CONFIG:-}"
if [ -z "$CONFIG_PATH" ]; then
    CONFIG_PATH="$(printf '%s' "$ENSURE_OUT" | jq -r '.config // empty')"
fi
TOKEN=""
if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
    TOKEN="$(expand_env_refs "$(awk "$TOKEN_AWK" "$CONFIG_PATH")")"
fi
# An empty token is not fatal here: `ensure` already proved the gateway accepts
# whatever this config holds. Guessing a failure before the wire would invent
# one the gateway never reported.

# ---------------------------------------------------------------------------
# Context window (KTD7 / R10).
#
# An alias absent from the table launches anyway, with the drift named on
# stderr. The table is metadata, not an allowlist — the gateway's served list is
# the allowlist, and it was already checked by `ensure`.
# ---------------------------------------------------------------------------
CONTEXT_WINDOW=""
if [ -f "$MODELS_JSON" ]; then
    CONTEXT_WINDOW="$(jq -r --arg a "$ALIAS" '.aliases[$a].context_window // empty' < "$MODELS_JSON" 2>/dev/null)"
fi
# The table is a file on disk, so its value is a SOURCE, not a constant. A
# non-numeric context_window used to reach `$win|tonumber` in the final emit,
# where jq errors, emit prints an empty line and the script still exits 0 — a
# silent contract violation (no JSON object at all) for a typo in a JSON file.
# Constrained to digits here instead, which also keeps it out of the exported
# env var and the attach command; a bad value is treated exactly as an absent
# one, which KTD7 already defines as "launch anyway, name the drift".
if [ -n "$CONTEXT_WINDOW" ] && ! [[ "$CONTEXT_WINDOW" =~ ^[0-9]+$ ]]; then
    say "drift: alias '$ALIAS' has a non-numeric context_window in $MODELS_JSON — ignoring it and launching without CLAUDE_CODE_MAX_CONTEXT_TOKENS"
    CONTEXT_WINDOW=""
fi
if [ -z "$CONTEXT_WINDOW" ]; then
    say "drift: alias '$ALIAS' has no context_window in $MODELS_JSON — launching without CLAUDE_CODE_MAX_CONTEXT_TOKENS, so this session uses Claude Code's default window"
fi

# ---------------------------------------------------------------------------
# The seed run (U4 step 2).
#
# The child's stdout is captured to a FILE, never inherited: `claude -p
# --output-format json` writes a JSON object of its own, and letting it through
# would put two objects on our stdout — KTD2's one bug.
#
# The gateway environment is exported inside the subshell rather than passed as
# an `env VAR=value` prefix, because `env`'s own argv would then carry the token
# and be readable from the process table (KTD6). The subshell is also where the
# cwd is pinned, so the session is keyed to the directory we encode below.
# ---------------------------------------------------------------------------
tmpwork
WORK="$TMPWORK"
SEED_OUT="$WORK/seed.json"
SEED_ERR="$WORK/seed.err"

# The child runs in the BACKGROUND and the parent polls (R2). Two reasons:
#   * the deadline. `timeout(1)` does not exist on macOS; the parent's kill -0
#     poll is the deadline, and on expiry the child is TERMed, given time,
#     KILLed if it ignores that, and REAPED. A detached watchdog would leave a
#     window where an orphaned agent outlives this script; a parent that waits
#     and reaps has no such window.
#   * cancellation. bash defers traps while blocked on a FOREGROUND child, so
#     with the seed run in the foreground a TERM to this script was ignored
#     until `claude` finished — or forever. The poll's `sleep 0.2` defers a
#     trap by at most 0.2s, and cleanup then reaps the child (KTD6: nothing is
#     left alive holding the token in its environment).
(
    cd "$PIN_CWD" || exit 127
    export ANTHROPIC_BASE_URL="$BASE_URL"
    export ANTHROPIC_AUTH_TOKEN="$TOKEN"
    export ANTHROPIC_API_KEY="$TOKEN"
    [ -n "$CONTEXT_WINDOW" ] && export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CONTEXT_WINDOW"
    exec "$CLAUDE_BIN" --model "$ALIAS" --output-format json -p "$PROMPT"
) > "$SEED_OUT" 2> "$SEED_ERR" &
CHILD_PID=$!

SEED_TICKS="$(awk -v t="$SEED_TIMEOUT" 'BEGIN{print int(t * 5)}')"
waited=0
while kill -0 "$CHILD_PID" 2>/dev/null; do
    if [ "$waited" -ge "$SEED_TICKS" ]; then
        reap_child
        die "$EX_DEADLINE" "deadline_exceeded" "the seed run through '$CLAUDE_BIN' exceeded ${SEED_TIMEOUT}s (SPAWN_LAUNCH_TIMEOUT) — it was stopped and reaped, nothing is still running, and no session handle exists"
    fi
    sleep 0.2
    waited=$((waited + 1))
done
wait "$CHILD_PID"
SEED_RC=$?
CHILD_PID=""

if [ "$SEED_RC" -ne 0 ]; then
    # "Announced-but-broken is never success." A handle to a session that does
    # not exist is worse than a failure: Shawn would attach to nothing.
    say "the seed run exited $SEED_RC; last stderr from $CLAUDE_BIN:"
    # KTD5 free-form sink: this is a child process's stderr, and on a gateway
    # session that child is relaying a non-Anthropic model's output. Piped
    # through the sanitizer, never straight to the terminal.
    tail -5 "$SEED_ERR" 2>/dev/null | spawn::sanitize_stream >&2
    die "$EX_UPSTREAM" "seed_failed" "the seed run through '$CLAUDE_BIN' exited $SEED_RC — no session was materialized, so there is no handle to print"
fi

# ---------------------------------------------------------------------------
# Session-id capture — the unit's named unknown.
#
# The shape below is what `claude -p --output-format json` emits today and what
# tests/fixtures/fake-claude.sh pins. Treat it as an OBSERVED contract, not a
# guarantee: if the real CLI moves the field, this read fails loudly (code 5,
# no handle) instead of printing a handle built on a guess.
# ---------------------------------------------------------------------------
SESSION_ID="$(jq -r '.session_id // empty' < "$SEED_OUT" 2>/dev/null)"
if [ -z "$SESSION_ID" ]; then
    die "$EX_UPSTREAM" "no_session_id" "the seed run exited 0 but its JSON carried no .session_id — the CLI's output shape has drifted from what this script reads"
fi
# KTD5, identifier half: the session id is an IDENTIFIER that arrives from a
# child process, and it is interpolated into the transcript path, the printed
# handle and the attach command. Held to the same grammar as the alias, so an
# escape byte in it is impossible rather than filtered. A real session id is a
# uuid and passes; anything that does not is the same class as a missing id —
# the CLI's output shape has drifted — so it reuses that code (5), inventing no
# new one.
if ! [[ "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "$EX_UPSTREAM" "no_session_id" "the seed run reported a .session_id that fails the identifier grammar [A-Za-z0-9._-]+ — the CLI's output shape has drifted, and no handle is built from an identifier we cannot vouch for"
fi
if [ "$(jq -r '.is_error // false' < "$SEED_OUT" 2>/dev/null)" = "true" ]; then
    die "$EX_UPSTREAM" "seed_failed" "the seed run reported is_error=true (session $SESSION_ID) — refusing to hand back a handle to a failed turn"
fi

# ---------------------------------------------------------------------------
# Transcript resolution (U4 step 3).
#
# Claude Code encodes the project directory into ~/.claude/projects/ by
# replacing every non-alphanumeric byte with '-'. Deriving it from the PINNED
# cwd — not from $PWD, and not from wherever the caller happened to be — is what
# makes the path reproducible.
#
# The file must EXIST. This is the round-trip honesty check: a handle whose
# transcript is absent is a handle to a session that is not on disk.
# ---------------------------------------------------------------------------
ENCODED_CWD="$(printf '%s' "$PIN_CWD" | sed 's/[^A-Za-z0-9]/-/g')"
TRANSCRIPT="$PROJECTS_ROOT/$ENCODED_CWD/$SESSION_ID.jsonl"
if [ ! -f "$TRANSCRIPT" ]; then
    die "$EX_UPSTREAM" "transcript_missing" "the seed run reported session $SESSION_ID but no transcript exists at $TRANSCRIPT — refusing to print a handle to a session that is not on disk"
fi

# ---------------------------------------------------------------------------
# The attach command (U4 step 4, KTD6).
#
# Token BY REFERENCE. The command re-reads server.token from the config at
# attach time, so the literal is in neither this script's output nor the
# command string nor, at attach time, any child's argv — awk's argv carries the
# config PATH, and the value reaches `claude` through the environment.
#
# It is a bash command string (the ${!name} indirection for a `${VAR}` token is
# bash-only) and it is self-contained: it cds to the pinned directory itself, so
# it resolves the same session from anywhere.
# ---------------------------------------------------------------------------
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

ATTACH="cd $(shq "$PIN_CWD") && "
ATTACH+="GW_TOK=\"\$(awk $(shq "$TOKEN_AWK") $(shq "$CONFIG_PATH"))\" && "
# Expand a whole-value ${VAR} reference the same way the gateway itself does.
ATTACH+="case \"\$GW_TOK\" in '\${'*'}') GW_N=\"\${GW_TOK#\\\$\\{}\"; GW_N=\"\${GW_N%\\}}\"; GW_TOK=\"\${!GW_N-}\";; esac; "
ATTACH+="ANTHROPIC_BASE_URL=$(shq "$BASE_URL") "
ATTACH+="ANTHROPIC_AUTH_TOKEN=\"\$GW_TOK\" ANTHROPIC_API_KEY=\"\$GW_TOK\" "
[ -n "$CONTEXT_WINDOW" ] && ATTACH+="CLAUDE_CODE_MAX_CONTEXT_TOKENS=$(shq "$CONTEXT_WINDOW") "
ATTACH+="$(shq "$CLAUDE_BIN") --model $(shq "$ALIAS") --resume $(shq "$SESSION_ID")"

emit "$(jq -nc \
    --arg alias "$ALIAS" \
    --arg sid "$SESSION_ID" \
    --arg tr "$TRANSCRIPT" \
    --arg cwd "$PIN_CWD" \
    --arg base "$BASE_URL" \
    --arg attach "$ATTACH" \
    --arg win "$CONTEXT_WINDOW" \
    "$(spawn::envelope_jq plugin)"' + {ok:true, alias:$alias, session_id:$sid,
      transcript_path:$tr, cwd:$cwd, base_url:$base,
      context_window:(if $win == "" then null else ($win|tonumber) end),
      attach_command:$attach, error:null, exit_code:0}')" \
    || REMEDY="The session was created but jq could not encode the handle. Check jq is a working build; the session exists on disk, so it can be resumed by session id without re-seeding." \
        die "$EX_USAGE" "usage" "could not encode the response object"
exit $EX_OK

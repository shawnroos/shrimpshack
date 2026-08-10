#!/usr/bin/env bash
# lens.sh — the headless lens (plan U3): prompt in, one JSON answer out.
#
#   printf 'question' | lens.sh --alias gpt-sol
#   lens.sh --alias kimi --prompt-file ./diff.txt --max-tokens 4096 --timeout 300
#
# This is the reason the plugin exists. The primary consumer is a skill holding
# `allowed-tools: Bash, Read` — it cannot invoke a slash command or a skill, so
# this Bash-invocable script IS the surface.
#
# CONTRACT (KTD2 owns it; this file implements it, it does not redefine it):
#   exactly one JSON object on stdout, ALWAYS, including every failure path;
#   diagnostics on stderr only.
#   exit 0 ok · 2 usage/refusal · 3 unreachable · 4 alias unknown ·
#        5 upstream provider error · 6 deadline exceeded · 7 token rejected.
#   The `error` field distinguishes `rate_limited`, `context_overflow`,
#   `no_text_truncated` and `no_text_in_response` from other upstream failures.
#
# KTD1: this is a plain completion call to the gateway's messages endpoint. The
# Claude Code agent loop is NOT in this path — tools are off by construction,
# so a lens can never edit the code it is reviewing, in any configuration.
#
# KD2 / R7: there is no spend logic here. No cap, no warning, no counter. That
# is a settled decision, not an oversight; do not "helpfully" add one.
#
# set -e is deliberately OFF (only -u -o pipefail). Every failure path here is
# an exit code the contract names; letting bash exit on the first non-zero
# command would turn a classified 5 or 6 into an unclassified 1 with no JSON.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$SCRIPT_DIR/spawnctl.sh"

# KTD5. Sourced, not re-implemented. NOTE the split this file lives on both
# sides of: the model's prose in `text` (and in the spill file) stays RAW by
# design — it is data, and the consumer owns that sink — while every DIAGNOSTIC
# this script prints, including the upstream error body it quotes back, is
# sanitized. See README.md for the source x sink matrix.
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"

# Same reason, applied to the plain helpers: expand_env_refs, emit and the curl
# --config escaper were byte-identical copies across the three scripts.
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

# Sourced for spawn::token_fallback ONLY: the config parser below stays local
# (common.sh names it as deliberately duplicated), but the env/Keychain half of
# resolution is shared so this script and spawnctl's probe cannot present
# different tokens to the same gateway.
# shellcheck source=./secrets.sh
. "$SCRIPT_DIR/secrets.sh"

KEYCHAIN_SERVICE="${SPAWN_KEYCHAIN_SERVICE:-spawn-gateway}"
KEYCHAIN_ACCOUNT_TOKEN="${SPAWN_KEYCHAIN_ACCOUNT_TOKEN:-gateway-token}"

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------
EX_OK=0
EX_USAGE=2
EX_UNREACHABLE=3
# EX_ALIAS=4 is never produced HERE. The served-list check lives in
# spawnctl.sh ensure (KTD3) so both surfaces inherit one definition of exit 4;
# this script propagates ensure's code and its JSON verbatim rather than
# re-deriving "unknown alias" from an upstream error body.
EX_UPSTREAM=5
EX_DEADLINE=6
EX_AUTH=7

# ---------------------------------------------------------------------------
# R13 — the scope of what the model saw, stated IN THE DATA.
#
# KTD1 already puts tools out of the path by construction, and commands/agent.md
# says so in prose. But the consumer that matters runs with `allowed-tools:
# Bash, Read` and never loads that markdown — the same gap `content_trust`
# closed. A caller reading only the JSON could not tell whether the answer came
# from a model that had gone and looked at the repository or from one that saw a
# single message and nothing else. That distinction decides how much the answer
# is worth: an answer about a file the model never read is a guess.
#
# Constants, like the trust marking, so the far side contributes no byte of them.
# ---------------------------------------------------------------------------
LENS_MODEL_SCOPE="single-message-no-tools"
LENS_MODEL_SCOPE_NOTICE="The model was sent exactly one message — the prompt from this call — and had no tools: it could not read a file, run a command, browse, or fetch anything, and there was no second turn. The prompt was its entire world, so anything the answer asserts about code, files or state it was not shown is a guess."

# ---------------------------------------------------------------------------
# Configuration surface. Every knob is env-overridable so a test can point the
# whole script at a fixture; a test that had to reach the real gateway on port
# 4000 would either be skipped or fight the running process, and both of those
# are how a "passing" suite stops meaning anything.
# ---------------------------------------------------------------------------
# Layered timeouts (U3 step 4). The connect timeout is short so a dead endpoint
# fails fast; the TOTAL deadline is separate and generous because it is sized
# from the healthy path for review-sized prompts. A single budget tuned to
# either one starves the other: short enough to detect a dead port is far too
# short for a real completion.
CONNECT_TIMEOUT="${SPAWN_CONNECT_TIMEOUT:-2}"
TOTAL_TIMEOUT="${SPAWN_LENS_TIMEOUT:-600}"

# KTD8 spill threshold. An unbounded return exhausts a fan-out orchestrator's
# context — multi-slice-review already codifies why.
SPILL_BYTES="${SPAWN_SPILL_BYTES:-16384}"

DEFAULT_MAX_TOKENS="${SPAWN_LENS_MAX_TOKENS:-8192}"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
# Every human-readable diagnostic goes through say() or die(), and both
# sanitize (KTD5). The chokepoint is the point: the upstream error body
# ($ERR_MSG) reaches the terminal only through die(), so provider prose cannot
# rewrite the statusline no matter which classification branch quotes it — and
# a message nobody has written yet is closed the same way.
say() { printf '▸ %s\n' "$(spawn::sanitize_for_display "$*")" >&2; }

# The single stdout write lives in common.sh (emit); EMITTED is this script's
# own state, so it stays declared here — a bash function reads the caller's
# globals dynamically.
EMITTED=0

# R11 — the help discriminator.
#
# `-h` and a genuine usage error are both exit 2 with error:"usage", and the
# enum is contract-frozen (KTD2), so a new code is not available. They were
# separated only by the `detail` prose "help requested", which means a machine
# had to grep English to tell "you asked me to explain myself" from "your call
# was wrong" — the exact prose-branching that broke every fan-out consumer's
# `.error` switch. This flag is the field version of that distinction, and it
# rides on EVERY error response (both encoder tiers), so a consumer can branch
# on `.help_requested == true` without checking whether the field exists.
HELP_REQUESTED=false

ALIAS=""

# R12 — the lens's own error vocabulary, falling through to the shared table in
# common.sh. Keyed on the ENUM, not on the call site: two sites that report the
# same value must not hand a caller two different repairs. A site whose fix is
# narrower than its class overrides with a `REMEDY=... die ...` prefix.
remedy_for() {
    case "$1" in
        rate_limited)
            printf 'Upstream is throttling. Wait and retry the same call; it is expected to succeed later, so do not rewrite the prompt.' ;;
        context_overflow)
            printf 'The prompt cannot fit this alias, and retrying it unchanged never will. Send less, or pick an alias with a wider context window.' ;;
        no_text_truncated)
            printf 'The answer never started. Raise --max-tokens and retry the same prompt.' ;;
        no_text_in_response)
            printf 'The model returned nothing to read, and it was not cut short — raising --max-tokens will not help. Retry once; if it repeats, rephrase the prompt or use another alias.' ;;
        *) spawn::remedy_for "$1" ;;
    esac
}

# The failure envelope lives in common.sh (spawn::emit_error): this was a
# ~40-line near-copy of its sibling, differing only in the trust tier and the
# per-surface null fields — the same two axes spawn::preflight_jq already
# parametrizes. The null fields are named ONCE now; the shared helper derives
# both the jq and the no-jq spelling from that one list, which is the pair
# that had already drifted.
emit_error() { spawn::emit_error model "text usage" "$@"; }

# die() is inherited from common.sh — it was byte-identical here and in the
# sibling surface, which is the module boundary saying it belongs there.

# TMPWORK holds scratch that MUST NOT outlive the call: the request body and,
# above all, the mode-0600 credential file (KTD6 permits it only as an
# ephemeral file created and removed within a single invocation). The spill
# file is deliberately NOT in here — it is the return value, and a return value
# deleted by our own EXIT trap is a path the caller cannot read.
TMPWORK=""
CHILD_PID=""
# TERM -> bounded poll -> KILL -> REAP, the same escalation launch.sh and
# spawnctl's stop both use.
#
# It used to send TERM and immediately return. The header a few hundred lines
# down claimed "No orphan: cleanup signals CHILD_PID before it returns", and for
# curl that is nearly true — curl dies on TERM promptly. But CHILD_PID is not
# always curl: on the preflight path it is `spawnctl ensure`, whose OWN term
# trap is deferred while it sits in a foreground curl probe. So it could outlive
# this script by seconds STILL HOLDING THE START LOCK, and the next caller waits
# on a lock whose owner is a process nobody is waiting for.
#
# Reaping also matters on its own: an unreaped child re-parented to init keeps
# whatever it holds for as long as it lives.
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
    # Kill AND REAP the request before removing the directory it reads its
    # credential from. See the call site: curl runs in the BACKGROUND so this
    # handler can run at all — bash defers a trap while it is blocked on a
    # foreground child.
    reap_child
    [ -n "$TMPWORK" ] && rm -rf "$TMPWORK" 2>/dev/null
    return 0
}
trap cleanup EXIT
# bash does NOT run an EXIT trap when the shell dies on an untrapped INT/TERM/HUP
# (measured on this box, bash 5.3.15). Without these, a cancelled lens call leaks
# TMPWORK — and TMPWORK holds the mode-0600 curlrc carrying the gateway token, so
# KTD6's "created and removed within a single invocation" would be false exactly
# when it matters most: this script is built for fan-out, and an orchestrator
# cancelling reviewer subagents (or a human hitting Ctrl-C on a 600s call) sends
# precisely these signals. Nothing else ever reaps that file. These exit THROUGH
# the EXIT path; a bare `trap cleanup INT TERM` would clean up and then continue.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Sets $TMPWORK. Deliberately NOT "prints the path": called as $(tmpwork) the
# assignment would happen in a command-substitution SUBSHELL, the parent's
# TMPWORK would stay empty, and the EXIT trap would leave the mode-0600
# credential dir on disk after every single call — the one thing R12's
# exception is conditioned on not happening.
tmpwork() {
    if [ -z "$TMPWORK" ]; then
        # umask 077 before the mkdir: the credential file lands in here, and a
        # world-readable parent makes its own 0600 mode decorative.
        TMPWORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/gwlens.XXXXXX")" || {
            # KTD2 is "exactly one JSON object on stdout, ALWAYS" — an unwritable
            # or missing TMPDIR used to exit 2 having printed nothing, which a
            # consumer cannot tell from a crash or a SIGKILL.
            printf '✗ cannot create a temp dir\n' >&2
            REMEDY="Point TMPDIR at a writable directory and call again. Nothing was sent, so no work was lost." \
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
        # help_requested rides here too: `-h` on a box with no jq is still a help
        # request, and a consumer must not have to read prose to see that.
        emit "$(spawn::envelope_bash model "usage" 2 ",\"alias\":null,\"text\":null,\"usage\":null,\"help_requested\":$HELP_REQUESTED" "Install jq and re-run. The plugin's contract is one JSON object on stdout, and jq is what encodes it.")"
        exit 2
    }
}

# ---------------------------------------------------------------------------
# Alias grammar (KTD5). Checked BEFORE any network call, so an escape byte or a
# shell metacharacter in an identifier is impossible rather than filtered.
# ---------------------------------------------------------------------------
validate_alias() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "$EX_USAGE" "usage" "alias failed the grammar [A-Za-z0-9._-]+ — refused before any network call"
}

usage() {
    cat >&2 <<'EOF'
usage: lens.sh --alias <alias> [--prompt-file <path>] [--max-tokens N]
               [--timeout SECONDS] [--output-file <path>]

The prompt is read from STDIN by default, or from --prompt-file. It is NEVER
taken from argv (KTD8): callers pass diffs and multi-KB context, and argv hits
quoting and length limits first, and silently.
EOF
}

# ---------------------------------------------------------------------------
# --describe (R10, R14, KD2).
#
# The contract as DATA, at exit 0, for the consumer that cannot read a word of
# markdown: `allowed-tools: Bash, Read` cannot load a skill or a slash command,
# so an exit table living only in agent.md is an exit table that consumer never
# sees. It hard-codes one instead, from whatever it was told once, and drifts.
#
# It answers with the gateway DOWN and with no config present, because it is
# constants only and returns before preflight. That is the point: a caller reads
# the contract precisely so it can interpret a failure, and a describe that
# needed a healthy gateway would be unavailable exactly when it is needed.
#
# It DOES require jq. Every success-shaped response in this plugin does: the
# pure-bash tier encodes failures only, because building a payload without an
# encoder means hand-writing the envelope, and a hand-written envelope is the
# drift R23 exists to close. With no jq, need_jq answers with the standard
# no-encoder object at exit 2 — which is itself a truthful contract statement.
#
# Every value below is projected from the constants and functions this script
# actually runs on (the EX_* constants, remedy_for, the R13 notice), so the
# document cannot describe a script other than this one (R14).
# ---------------------------------------------------------------------------
emit_describe() {
    # The three defaults below are env-overridable, so they are SOURCES, not
    # constants: a caller with SPAWN_LENS_TIMEOUT=soon exported would otherwise
    # reach --argjson with a non-number, jq would error, and the one thing this
    # arm exists to do — answer under any conditions — would fail. A bad value
    # is reported as an absent default; the validation below still refuses it
    # on a real call.
    local ev d_spill d_maxtok d_timeout
    num_or_null() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$1" || printf 'null'; }
    d_spill="$(num_or_null "$SPILL_BYTES")"
    d_maxtok="$(num_or_null "$DEFAULT_MAX_TOKENS")"
    d_timeout="$(num_or_null "$TOTAL_TIMEOUT")"

    # U2 (KD6, KTD3): the family -> tier -> alias grammar the command layer
    # (agent.md) reads prose against, as data — the only consumer that matters
    # cannot load agent.md at all. Read the SAME way table_json() in
    # spawnctl.sh does: a malformed families/no_family_alias/chain_policy
    # shape collapses to empty rather than reaching --argjson with garbage.
    # Local to this arm, not a new global — this script never resolves an
    # alias from prose itself (KD6: that is the reading agent's job), it only
    # needs to answer what the grammar IS.
    local models_json grammar
    models_json="${SPAWN_MODELS_JSON:-$SCRIPT_DIR/models.json}"
    grammar="$(spawn::models_grammar "$models_json")"

    ev="$(jq -n \
        --arg r_usage "$(remedy_for usage)" \
        --arg r_unreach "$(remedy_for unreachable)" \
        --arg r_alias "$(remedy_for alias_unknown)" \
        --arg r_auth "$(remedy_for auth_rejected)" \
        --arg r_up "$(remedy_for upstream_error)" \
        --arg r_dead "$(remedy_for deadline_exceeded)" \
        --arg r_pre "$(remedy_for preflight_failed)" \
        --arg r_int "$(remedy_for internal)" \
        --arg r_rate "$(remedy_for rate_limited)" \
        --arg r_ctx "$(remedy_for context_overflow)" \
        --arg r_trunc "$(remedy_for no_text_truncated)" \
        --arg r_none "$(remedy_for no_text_in_response)" \
        '[{value:"usage",           exit_code:2, remedy:$r_usage},
          {value:"unreachable",     exit_code:3, remedy:$r_unreach},
          {value:"alias_unknown",   exit_code:4, remedy:$r_alias},
          {value:"auth_rejected",   exit_code:7, remedy:$r_auth},
          {value:"rate_limited",    exit_code:5, remedy:$r_rate},
          {value:"context_overflow",exit_code:5, remedy:$r_ctx},
          {value:"no_text_truncated",   exit_code:5, remedy:$r_trunc},
          {value:"no_text_in_response", exit_code:5, remedy:$r_none},
          {value:"upstream_error",  exit_code:5, remedy:$r_up},
          {value:"preflight_failed",exit_code:3, remedy:$r_pre},
          {value:"deadline_exceeded",exit_code:6, remedy:$r_dead},
          {value:"internal",exit_code:2, remedy:$r_int}]')" || return 1

    emit "$(jq -nc --argjson errors "$ev" \
        --arg scope "$LENS_MODEL_SCOPE" --arg notice "$LENS_MODEL_SCOPE_NOTICE" \
        --argjson spill "$d_spill" --argjson maxtok "$d_maxtok" \
        --argjson timeout "$d_timeout" --argjson grammar "$grammar" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:true, error:null, exit_code:0,
          response_kind:"describe",
          families:$grammar.families,
          no_family_alias:$grammar.no_family_alias,
          chain_policy:$grammar.chain_policy,
          surface:"lens.sh",
          summary:"One tool-less turn against one gateway alias: a prompt in, one JSON object out.",
          prompt_input:["stdin","--prompt-file"],
          argv_prompt_accepted:false,
          flags:[
            {name:"--alias",       value:"alias",   required:true,  default:null,
             note:"exactly one; grammar [A-Za-z0-9._-]+; this script never fans out"},
            {name:"--prompt-file", value:"path",    required:false, default:null,
             note:"alternative to stdin; the prompt is never read from argv"},
            {name:"--max-tokens",  value:"integer", required:false, default:$maxtok,
             note:"env SPAWN_LENS_MAX_TOKENS"},
            {name:"--timeout",     value:"seconds", required:false, default:$timeout,
             note:"positive only; 0 disables curl deadline, so it is refused; env SPAWN_LENS_TIMEOUT"},
            {name:"--output-file", value:"path",    required:false, default:null,
             note:"write the answer here; the response then carries output_file and text is null"},
            {name:"--help",        value:null,      required:false, default:null,
             note:"exit 2 with help_requested:true — not a usage error"},
            {name:"--describe",    value:null,      required:false, default:null,
             note:"this document; exit 0; needs neither a running gateway nor a config"}
          ],
          exit_codes:[
            {code:0, error:null,               origin:"own",
             meaning:"the model answered; read text or output_file"},
            {code:2, error:"usage",            origin:"own",
             meaning:"caller bug or help; branch on help_requested"},
            {code:3, error:"unreachable",      origin:"own",
             meaning:"the gateway is down and could not be started"},
            {code:4, error:"alias_unknown",    origin:"propagated",
             meaning:"decided by spawnctl ensure; preflight.served_aliases lists what is served"},
            {code:5, error:"upstream_error",   origin:"own",
             meaning:"the provider failed; error names the sub-class"},
            {code:6, error:"deadline_exceeded",origin:"own",
             meaning:"aborted at the deadline; nothing is still running"},
            {code:7, error:"auth_rejected",    origin:"own",
             meaning:"the gateway is up and refused our token"}
          ],
          error_values:$errors,
          response_fields:[
            {name:"schema",         always:true,  note:"the version of this contract"},
            {name:"ok",             always:true,  note:"boolean; agrees with exit_code"},
            {name:"error",          always:true,  note:"enum value or null, never prose"},
            {name:"remedy",         always:true,  note:"what to do about it; null only on success"},
            {name:"detail",         always:true,  note:"human-readable diagnostic; the only prose field"},
            {name:"content_trust",  always:true,  note:"how far the payload may be trusted"},
            {name:"content_notice", always:true,  note:"the rule that follows from content_trust"},
            {name:"exit_code",      always:true,  note:"the process exit status, restated in the data"},
            {name:"alias",          always:false, note:"the resolved alias, null when none was accepted"},
            {name:"text",           always:false, note:"the answer inline; mutually exclusive with output_file"},
            {name:"output_file",    always:false, note:"path holding the answer when it spilled or --output-file was given"},
            {name:"bytes",          always:false, note:"size of the answer in bytes"},
            {name:"usage",          always:false, note:"the provider token counts, verbatim"},
            {name:"preflight",      always:false, note:"spawnctl ensure object on a preflight failure"},
            {name:"help_requested", always:false, note:"true only for --help; present on every error response"},
            {name:"model_scope",    always:false, note:"what the model could see; success responses only"},
            {name:"model_scope_notice", always:false, note:"the same fact in words"},
            {name:"families",       always:false, note:"--describe only: the declared family -> tier -> alias grammar (KTD3) agent.md resolves prose against"},
            {name:"no_family_alias",always:false, note:"--describe only: the alias prose naming no family resolves to"},
            {name:"chain_policy",   always:false, note:"--describe only: whether this surface accepts a chain alias"}
          ],
          spill_bytes:$spill,
          model_scope:$scope,
          model_scope_notice:$notice,
          tools_on_far_side:false,
          turns:1
        }')" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PROMPT_FILE=""
OUTPUT_FILE=""
MAX_TOKENS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --alias)        ALIAS="${2:-}"; shift; shift 2>/dev/null || true ;;
        --alias=*)      ALIAS="${1#*=}"; shift ;;
        --prompt-file)  PROMPT_FILE="${2:-}"; shift; shift 2>/dev/null || true ;;
        --prompt-file=*) PROMPT_FILE="${1#*=}"; shift ;;
        --max-tokens)   MAX_TOKENS="${2:-}"; shift; shift 2>/dev/null || true ;;
        --max-tokens=*) MAX_TOKENS="${1#*=}"; shift ;;
        --timeout)      TOTAL_TIMEOUT="${2:-}"; shift; shift 2>/dev/null || true ;;
        --timeout=*)    TOTAL_TIMEOUT="${1#*=}"; shift ;;
        --output-file)  OUTPUT_FILE="${2:-}"; shift; shift 2>/dev/null || true ;;
        --output-file=*) OUTPUT_FILE="${1#*=}"; shift ;;
        --describe)     need_jq
                        # Answered here, before --alias is required, before the
                        # timeout validation and long before preflight — so it
                        # holds with the gateway down and with no config on the
                        # box (R10).
                        emit_describe || die "$EX_USAGE" "internal" "could not encode the describe object"
                        exit "$EX_OK" ;;
        -h|--help)      # R11: same exit code, same enum, different FIELD. The
                        # flag is set before need_jq so the no-jq tier carries
                        # it too.
                        HELP_REQUESTED=true
                        usage; need_jq
                        REMEDY="Nothing is broken — this was a help request, and exit 2 is what the frozen enum has for it. Branch on help_requested, not on the code. Call --describe for the same contract as data." \
                            die "$EX_USAGE" "usage" "help requested" ;;
        --) shift
            # Everything after -- would be an argv prompt. Refused: see below.
            [ $# -gt 0 ] && { need_jq; REMEDY="Pipe the prompt on stdin, or write it to a file and pass --prompt-file. argv hits quoting and length limits first, and silently, which is why it is refused rather than truncated." \
                die "$EX_USAGE" "usage" "the prompt is never taken from argv (KTD8) — pipe it on stdin or pass --prompt-file"; }
            ;;
        *)
            # THE ARGV-PROMPT REFUSAL. A caller that writes
            #   lens.sh --alias x "here is my 40KB diff"
            # must fail loudly and immediately. Accepting it would work in
            # testing and then silently truncate or mangle the first real
            # review-sized prompt, which is exactly the failure KTD8 names.
            need_jq
            REMEDY="Pipe the prompt on stdin, or write it to a file and pass --prompt-file. Run --describe for the flags this script accepts." \
                die "$EX_USAGE" "usage" "unexpected argument '$1' — the prompt is never taken from argv (KTD8); pipe it on stdin or pass --prompt-file"
            ;;
    esac
done

need_jq

[ -n "$ALIAS" ] || { usage; REMEDY="Pass exactly one --alias. 'spawnctl.sh status' lists what the gateway serves." \
    die "$EX_USAGE" "usage" "--alias is required"; }
validate_alias "$ALIAS"

# Positive, not merely numeric. `curl --max-time 0` does not mean "no limit" — it
# DISABLES the deadline, so the value a caller would naturally read as "don't
# impose an artificial cap" produces an unbounded hang, which is the worst
# failure mode for an unattended fan-out because it looks like work in progress.
# Measured: --max-time 0 against an accept-and-never-reply socket ran until the
# peer died and exited rc=56, not 28 — so it would also be misreported as exit 3
# (unreachable) rather than exit 6 (deadline), breaking the promise
# skills/lens/SKILL.md makes to consumers.
[[ "$TOTAL_TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$(awk -v v="$TOTAL_TIMEOUT" 'BEGIN{print (v > 0)}')" = "1" ] \
    || die "$EX_USAGE" "usage" "--timeout must be a POSITIVE number of seconds (0 disables curl's deadline entirely), got '$TOTAL_TIMEOUT'"
# Same for the connect timeout, which reached --connect-timeout unvalidated.
[[ "$CONNECT_TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$(awk -v v="$CONNECT_TIMEOUT" 'BEGIN{print (v > 0)}')" = "1" ] \
    || die "$EX_USAGE" "usage" "SPAWN_CONNECT_TIMEOUT must be a POSITIVE number of seconds, got '$CONNECT_TIMEOUT'"
MAX_TOKENS="${MAX_TOKENS:-$DEFAULT_MAX_TOKENS}"
[[ "$MAX_TOKENS" =~ ^[0-9]+$ ]] && [ "$MAX_TOKENS" -gt 0 ] \
    || die "$EX_USAGE" "usage" "--max-tokens must be a positive integer, got '$MAX_TOKENS'"

# ---------------------------------------------------------------------------
# Prompt intake (KTD8): stdin by default, --prompt-file alternative.
# ---------------------------------------------------------------------------
tmpwork
WORK="$TMPWORK"
PROMPT_PATH="$WORK/prompt.txt"

if [ -n "$PROMPT_FILE" ]; then
    [ -f "$PROMPT_FILE" ] || REMEDY="Check the path exists and is readable by this process, then call again." \
        die "$EX_USAGE" "usage" "--prompt-file '$PROMPT_FILE' is not a readable file"
    cp "$PROMPT_FILE" "$PROMPT_PATH" 2>/dev/null \
        || REMEDY="Check the file's permissions and that it is a regular file, then call again." \
            die "$EX_USAGE" "usage" "could not read --prompt-file '$PROMPT_FILE'"
else
    # A TTY on stdin with no --prompt-file means nobody piped anything. Reading
    # would block forever with no output at all — the worst failure mode for an
    # unattended agent caller, because it looks like work in progress.
    if [ -t 0 ]; then
        usage
        REMEDY="Pipe the prompt on stdin or pass --prompt-file. Reading a terminal would block forever, which an unattended caller cannot tell from work in progress." \
            die "$EX_USAGE" "usage" "no prompt: stdin is a terminal and --prompt-file was not given"
    fi
    # CHECKED, like its --prompt-file sibling above. An unchecked write means
    # ENOSPC in $TMPDIR produces a PARTIAL prompt that still satisfies the
    # non-empty test below — so a truncated diff goes to the model, the model
    # answers the fragment confidently, and the response is ok:true. Silent
    # truncation of a review-sized prompt is the exact class KTD8 cites when it
    # refuses to accept prompts through argv; accepting it here on the stdin
    # path would be the same defect through a different door.
    cat > "$PROMPT_PATH" \
        || REMEDY="The prompt could not be written to scratch — most likely no space left in TMPDIR. Nothing was sent. Free space or point TMPDIR somewhere writable, then call again." \
            die "$EX_USAGE" "usage" "could not write the prompt to scratch (a partial write would have sent a truncated prompt and returned a confident answer to it)"
fi

[ -s "$PROMPT_PATH" ] || REMEDY="Send a non-empty prompt. Check that whatever produced it on stdin actually wrote something." \
    die "$EX_USAGE" "usage" "the prompt is empty"

# ---------------------------------------------------------------------------
# Preflight (U3 step 2/3): spawnctl.sh ensure <alias>.
#
# The alias is passed so the served-list check and its exit 4 come from ONE
# place (KTD3): the CODE is ensure's decision and propagates unchanged.
#
# The OBJECT is not forwarded verbatim (R3). ensure's failure object is
# {verb, error:<prose>} — no `text`, no `usage`, and prose where this script's
# consumers branch on an enum — so a caller's `.error` switch broke exactly
# when all N fan-out callers failed at once. The failure is REWRAPPED onto the
# lens's own vocabulary (error enum + detail + the null data fields), and
# ensure's full object rides along under `preflight` so nothing is lost.
# Still exactly one object on stdout (KTD2).
# ---------------------------------------------------------------------------
# Run in the BACKGROUND with an explicit `wait`, for the same reason the curl
# call below is: a `$( ... )` command substitution is a foreground child, and
# bash defers every trap until a foreground child returns. Preflight can sit
# here for the lock wait plus the gateway start, so a cancellation arriving in
# that window would be ignored and TMPWORK would survive the invocation.
ENSURE_TMP="$WORK/ensure.json"
bash "$CTL" ensure "$ALIAS" > "$ENSURE_TMP" 2>/dev/null &
ENSURE_PID=$!
CHILD_PID="$ENSURE_PID"   # cleanup kills whichever child is currently live
wait "$ENSURE_PID"
ENSURE_RC=$?
CHILD_PID=""
ENSURE_OUT="$(cat "$ENSURE_TMP" 2>/dev/null)"
if [ "$ENSURE_RC" -ne 0 ]; then
    # The enum comes from the CODE, which KTD2 already defines, not from
    # re-parsing ensure's prose — prose is what broke the consumers. The table
    # itself lives in common.sh (R23), which is also what spawnctl now derives
    # its own `error` from: the two sides agree by construction.
    PRE_ENUM="$(spawn::enum_for_code "$ENSURE_RC")"
    [ -n "$PRE_ENUM" ] || PRE_ENUM="preflight_failed"
    # ensure's object, validated before it is embedded; garbage becomes null
    # rather than corrupting our one object.
    PRE_JSON="$(printf '%s' "$ENSURE_OUT" | jq -c '.' 2>/dev/null)" || PRE_JSON=""
    [ -n "$PRE_JSON" ] || PRE_JSON="null"
    # `detail` first, `error` second: since the enum reconciliation ensure's
    # `error` IS the enum, and its prose moved to `detail`. The `.error`
    # fallback keeps this readable against an older spawnctl.
    PRE_DETAIL="$(printf '%s' "$ENSURE_OUT" | jq -r '.detail // .error // empty' 2>/dev/null)"
    [ -n "$PRE_DETAIL" ] || PRE_DETAIL="spawnctl ensure failed with code $ENSURE_RC and printed nothing"
    # R12: this path builds its object directly rather than through emit_error,
    # so the remedy has to be looked up here too — from the same table, keyed on
    # the same enum. Without it, the single most common failure a fan-out caller
    # sees (the gateway is down, or the alias is not served) was the one with no
    # instruction attached.
    PRE_REMEDY="$(remedy_for "$PRE_ENUM")"
    emit "$(jq -nc --arg a "$ALIAS" --arg e "$PRE_ENUM" \
        --arg d "$(spawn::sanitize_for_display "$PRE_DETAIL")" \
        --arg r "$PRE_REMEDY" \
        --argjson p "$PRE_JSON" --argjson c "$ENSURE_RC" \
        "$(spawn::preflight_jq model 'text:null, usage:null,')")" \
        || emit_error "$ENSURE_RC" "$PRE_ENUM" "$PRE_DETAIL"
    exit "$ENSURE_RC"
fi

BASE_URL="$(printf '%s' "$ENSURE_OUT" | jq -r '.base_url // empty')"
[ -n "$BASE_URL" ] || die "$EX_UNREACHABLE" "preflight_failed" "spawnctl ensure returned no base_url"
BASE_URL="${BASE_URL%/}"

# ---------------------------------------------------------------------------
# Token resolution.
#
# The token comes from the SAME place spawnctl's probe reads it — server.token
# in the resolved gateway.yaml, with ${VAR} expansion — because a lens that
# authenticated with a different token than the probe would pass preflight and
# then 401, and that divergence is undebuggable from the outside. When
# SPAWN_CONFIG is unset, the config path is read out of the `ensure` response
# above — `ensure` already owns install-dir resolution (KTD4), so this script
# never re-derives it. It used to come from a SECOND spawnctl process running
# `status`, which meant a redundant install-dir resolve, config re-parse and
# live HTTP probe on every lens call. The path is all that crosses; the token is
# still read locally, from the file, in this process (KTD6).
# ---------------------------------------------------------------------------
read_server_token() {
    local cfg="$1"
    [ -f "$cfg" ] || return 1
    awk '
        function trim(v) { sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); return v }
        function decomment(v) { sub(/[ \t]+#.*$/, "", v); return trim(v) }
        function unquote(v) { gsub(/^["'"'"']|["'"'"']$/, "", v); return v }
        /^[A-Za-z_][A-Za-z0-9_-]*:/ { sec = $0; sub(/:.*$/, "", sec); next }
        sec == "server" && /^[ \t]+token:/ {
            v = $0; sub(/^[ \t]*token:[ \t]*/, "", v)
            print unquote(decomment(v)); exit
        }
    ' "$cfg"
}

CONFIG_PATH="${SPAWN_CONFIG:-}"
if [ -z "$CONFIG_PATH" ]; then
    CONFIG_PATH="$(printf '%s' "$ENSURE_OUT" | jq -r '.config // empty')"
fi
TOKEN=""
if [ -n "$CONFIG_PATH" ]; then
    TOKEN="$(expand_env_refs "$(read_server_token "$CONFIG_PATH")")"
fi
# Then the SAME env/Keychain fallback spawnctl's probe runs (R27). Without it a
# setup that retired the config token leaves the probe passing and this call
# 401'ing — the divergence the comment above calls undebuggable.
# spawn::resolve_token (secrets.sh) owns this, xtrace guard and all — it was a
# byte-identical copy in both this file and its sibling until the duplication
# was collapsed into the file that already owns the chain.
[ -n "$TOKEN" ] || spawn::resolve_token "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_TOKEN"
# An empty token is not fatal here: the gateway answers with 401/403 and that
# becomes exit 7, which is a truthful classification. Guessing a code before the
# wire would invent a failure the gateway never reported.

# ---------------------------------------------------------------------------
# Request body. Built with jq --rawfile because the prompt is arbitrary bytes:
# a diff carries quotes, backslashes and newlines that any string-interpolated
# JSON would corrupt.
#
# max_tokens is always sent. The fixture tolerates its absence; the real
# messages API requires it, and a lens that only works against the fixture
# fails its first live call.
# ---------------------------------------------------------------------------
BODY="$WORK/body.json"
jq -n --arg model "$ALIAS" --argjson mt "$MAX_TOKENS" --rawfile p "$PROMPT_PATH" \
    '{model:$model, max_tokens:$mt, messages:[{role:"user", content:$p}]}' > "$BODY" \
    || REMEDY="jq could not encode the prompt. Check jq is a working build and that the prompt file was not truncated mid-read; nothing was sent." \
        die "$EX_USAGE" "internal" "could not encode the prompt as a JSON request body"

# ---------------------------------------------------------------------------
# Credential delivery (KTD6): a mode-0600 curl --config file, NEVER an argv
# token.
#
# A token in argv is readable from the process table by anything on the box —
# including the agents this decision treats as the adversary — for the whole
# lifetime of the request. `-H "x-api-key: $TOK"` is the tempting one-liner and
# it is exactly the leak. The file is created under umask 077 inside TMPWORK
# and removed by the EXIT trap, which is the single exception R12 allows.
#
# Backslash and quote are escaped because curl's config parser treats both as
# significant inside a quoted value.
# ---------------------------------------------------------------------------
CURLRC="$WORK/curlrc"
{
    printf 'url = "%s"\n' "$(esc "$BASE_URL/v1/messages")"
    printf 'header = "content-type: application/json"\n'
    printf 'header = "anthropic-version: 2023-06-01"\n'
    printf 'header = "x-api-key: %s"\n' "$(esc "$TOKEN")"
    printf 'header = "authorization: Bearer %s"\n' "$(esc "$TOKEN")"
    printf 'data-binary = "@%s"\n' "$(esc "$BODY")"
} > "$CURLRC"
chmod 600 "$CURLRC" 2>/dev/null

# ---------------------------------------------------------------------------
# The call.
#
# curl still owns the DEADLINE via --max-time — the timeout is enforced from
# inside the child, not by a watchdog that signals it.
#
# But curl runs in the BACKGROUND with an explicit `wait`, and that is load-
# bearing for CANCELLATION rather than for the deadline. bash does not run a
# trap while it is blocked on a foreground child: measured on this box, a script
# TERMed while sitting in a foreground `sleep` kept running and left its temp
# dir on disk, and this script sits inside curl for essentially its whole life.
# With the call in the foreground, an orchestrator cancelling a fan-out would
# leave the mode-0600 curlrc — the file holding the gateway token — on disk for
# up to the full timeout, and permanently if it escalated to SIGKILL. `wait` is
# interruptible, so the trap fires immediately, kills curl and removes the
# directory. No orphan: cleanup TERMs, polls, KILLs and REAPS CHILD_PID before it returns.
# ---------------------------------------------------------------------------
RESP="$WORK/resp.json"
: > "$RESP"
: > "$WORK/http"
curl -sS -o "$RESP" -w '%{http_code}' \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TOTAL_TIMEOUT" \
    --config "$CURLRC" >"$WORK/http" 2>"$WORK/curl.err" &
CHILD_PID=$!
wait "$CHILD_PID"
CURL_RC=$?
CHILD_PID=""
HTTP="$(cat "$WORK/http" 2>/dev/null)"

if [ "$CURL_RC" -eq 28 ]; then
    # 28 is curl's operation-timeout. A hung CONNECT also lands here rather than
    # in the unreachable class; that ambiguity is accepted rather than bolted
    # over with a second watchdog, because ensure has already proved the
    # endpoint answered moments ago.
    die "$EX_DEADLINE" "deadline_exceeded" "no response within ${TOTAL_TIMEOUT}s (curl 28); the request was aborted, nothing is still running"
fi
if [ "$CURL_RC" -ne 0 ]; then
    die "$EX_UNREACHABLE" "unreachable" "curl failed with rc=$CURL_RC talking to $BASE_URL/v1/messages"
fi

# ---------------------------------------------------------------------------
# Response classification (U3 step 3).
#
# context_overflow is its own value and not a generic upstream error because the
# lens NEVER applies a context window — that table is wired into launch, not
# here. Collapsed into "upstream error", a review-sized diff sent to a
# small-window alias invites a caller to retry a prompt that can never fit.
# ---------------------------------------------------------------------------
ERR_TYPE="$(jq -r '.error.type // empty' < "$RESP" 2>/dev/null)"
ERR_MSG="$(jq -r '.error.message // empty' < "$RESP" 2>/dev/null)"

classify_overflow() {
    # Matched on the upstream error BODY, which is the only place the signal
    # exists. Providers word it differently, so several known phrasings are
    # accepted rather than one exact string.
    local m
    m="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$m" in
        *context_length_exceeded*|*context\ length*|*too\ long*|*maximum\ context*|*context\ window*)
            return 0 ;;
    esac
    return 1
}

if [ "$HTTP" = "401" ] || [ "$HTTP" = "403" ]; then
    die "$EX_AUTH" "auth_rejected" "the gateway is up but rejected our token on the messages endpoint (HTTP $HTTP)"
fi

if [ "$HTTP" != "200" ]; then
    if [ "$HTTP" = "429" ] || [ "$ERR_TYPE" = "rate_limit_error" ]; then
        die "$EX_UPSTREAM" "rate_limited" "upstream rate-limited the call (HTTP $HTTP): ${ERR_MSG:-no message}"
    fi
    if classify_overflow "$ERR_MSG"; then
        die "$EX_UPSTREAM" "context_overflow" "the prompt does not fit this alias's context window (HTTP $HTTP): ${ERR_MSG:-no message}"
    fi
    # Anything else — including a 404 — is the generic upstream class. Exit 4 is
    # NOT re-derived from an error body here; it belongs to ensure's served-list
    # check (KTD3) and having two sources for it is how they diverge.
    die "$EX_UPSTREAM" "upstream_error" "upstream provider error (HTTP $HTTP): ${ERR_MSG:-no message}"
fi

TEXT_FILE="$WORK/text.txt"
if ! jq -j '[.content[]? | select(.type == "text") | .text] | join("")' < "$RESP" > "$TEXT_FILE" 2>/dev/null; then
    die "$EX_UPSTREAM" "upstream_error" "HTTP 200 but the body is not a parseable messages response"
fi
USAGE_JSON="$(jq -c '.usage // null' < "$RESP" 2>/dev/null)"
[ -n "$USAGE_JSON" ] || USAGE_JSON="null"

# An HTTP 200 that yields NO text is not a success. Found by driving the real
# gateway, and no fixture reproduces it: a reasoning model can spend its entire
# output budget inside `thinking` blocks and return content with no `text` block
# at all. Measured on kimi at --max-tokens 40, three runs out of three:
#   stop_reason "max_tokens", content types ["thinking"], output_tokens 40.
# The extraction above selects `.type == "text"`, so it produced an empty string
# and the script reported ok:true / bytes:0 / exit 0 — the caller paid for the
# tokens, asked a question, and got a green empty answer with nothing to say
# anything had gone wrong. A fan-out orchestrator reads that as a successful
# empty review, which is exactly the wrong-success class this plugin keeps
# closing everywhere else.
#
# Exit 5, not a new code: the enum is contract-frozen (KTD2), and `error` is
# already how exit 5 distinguishes its cases (rate_limited, context_overflow).
# The two values below are split because the remedy differs — a truncated answer
# is fixed by raising --max-tokens, an empty end_turn is not.
if [ ! -s "$TEXT_FILE" ]; then
    STOP_REASON="$(jq -r '.stop_reason // "unknown"' < "$RESP" 2>/dev/null)"
    BLOCK_TYPES="$(jq -r '[.content[]?.type] | join(",") // ""' < "$RESP" 2>/dev/null)"
    if [ "$STOP_REASON" = "max_tokens" ]; then
        # Worded to avoid the vocabulary the R7 lint forbids in this source
        # (spend/budget/cost/…). KD2 settles that this plugin carries no spend
        # logic, and the lint holds that line by asserting those words are
        # absent — so the wording bends, not the guard.
        die "$EX_UPSTREAM" "no_text_truncated" \
            "the model used all ${MAX_TOKENS} output tokens on reasoning and never reached an answer (stop_reason=max_tokens, content blocks: ${BLOCK_TYPES:-none}) — raise --max-tokens and retry"
    fi
    die "$EX_UPSTREAM" "no_text_in_response" \
        "the gateway returned HTTP 200 with no answer text (stop_reason=$STOP_REASON, content blocks: ${BLOCK_TYPES:-none})"
fi

# ---------------------------------------------------------------------------
# Output (KTD8 spill).
#
# Above the threshold the body goes to a file and the JSON carries the path
# instead of the text: an unbounded return exhausts the context of the fan-out
# orchestrator that called us. `text` and `output_file` are mutually exclusive —
# a consumer branches on which one is non-null, and both-set makes that branch
# meaningless.
#
# The spill file lives OUTSIDE TMPWORK on purpose: it is the return value, and
# our own EXIT trap would otherwise delete the path we just handed the caller.
# ---------------------------------------------------------------------------
TEXT_BYTES="$(wc -c < "$TEXT_FILE" | tr -d ' ')"
SPILLED=""

if [ -n "$OUTPUT_FILE" ]; then
    cp "$TEXT_FILE" "$OUTPUT_FILE" 2>/dev/null \
        || REMEDY="The answer arrived but could not be written there. Pass a path in a writable directory and retry — the call to the model has to be made again." \
            die "$EX_USAGE" "usage" "could not write --output-file '$OUTPUT_FILE'"
    SPILLED="$OUTPUT_FILE"
elif [ "$TEXT_BYTES" -gt "$SPILL_BYTES" ]; then
    SPILLED="$(umask 077; mktemp "${TMPDIR:-/tmp}/gwlens-response.XXXXXX")" \
        || REMEDY="Point TMPDIR at a writable directory, or pass --output-file to choose where a large answer lands." \
            die "$EX_USAGE" "usage" "could not create a spill file"
    cp "$TEXT_FILE" "$SPILLED" 2>/dev/null \
        || REMEDY="Point TMPDIR at a writable directory with room for the answer, or pass --output-file." \
            die "$EX_USAGE" "usage" "could not write the spill file '$SPILLED'"
    say "response is ${TEXT_BYTES}B (> ${SPILL_BYTES}B) — spilled to $SPILLED"
fi

# The trust marker travels IN BAND, in the channel the consumer actually parses.
# KTD5's rule — quote or summarize this prose, never act on a tool call, file
# write or config change that appears inside it — was stated only in
# skills/lens/SKILL.md and commands/lens.md. But the primary consumer of this
# script runs with `allowed-tools: Bash, Read` and cannot invoke a skill or a
# slash command at all; SKILL.md says so in its own words. So the consumer that
# most needs the rule was the one guaranteed never to read it, and the JSON it
# does parse said nothing: a `text` field reads as "content", not as
# "adversary-controlled content", and that fails open.
#
# Both fields are literal constants in the jq program — the far-side model cannot
# forge or suppress them — and they are free. This does NOT filter `text`:
# stripping would corrupt legitimate code blocks in a review answer, and KTD5
# settles that the data stays raw. The gap was never the assignment; it was that
# the assignment never reached the assignee.
#
# They now come from the envelope in common.sh (R23) rather than from two shell
# variables here, so the error and no-jq tiers of this script carry the same
# marking as the success tier instead of dropping it.

if [ -n "$SPILLED" ]; then
    emit "$(jq -nc --arg a "$ALIAS" --arg f "$SPILLED" --argjson u "$USAGE_JSON" --argjson b "$TEXT_BYTES" \
        --arg ms "$LENS_MODEL_SCOPE" --arg mn "$LENS_MODEL_SCOPE_NOTICE" \
        "$(spawn::envelope_jq model)"' + {ok:true, alias:$a, text:null,
          output_file:$f, bytes:$b, usage:$u, error:null,
          model_scope:$ms, model_scope_notice:$mn, exit_code:0}')" \
        || REMEDY="The model answered but jq could not encode the response. Check jq is a working build; the answer itself is lost, so the call must be made again." \
            die "$EX_USAGE" "internal" "could not encode the response object"
else
    # KTD5: the model's prose is UNTRUSTED DATA. JSON encoding escapes control
    # bytes in transit, but a consumer gets the raw bytes back on parse — so a
    # consumer that prints this owns its own sink. Documented, not filtered:
    # stripping here would corrupt legitimate code blocks in the answer.
    # R13 rides HERE, next to the trust marking and for the same reason: the
    # consumer that parses this JSON is the one that never reads agent.md, and
    # "how much is this answer worth" turns on the model having seen one message
    # and nothing else. Constants, so the far side cannot soften them.
    emit "$(jq -nc --arg a "$ALIAS" --rawfile t "$TEXT_FILE" --argjson u "$USAGE_JSON" --argjson b "$TEXT_BYTES" \
        --arg ms "$LENS_MODEL_SCOPE" --arg mn "$LENS_MODEL_SCOPE_NOTICE" \
        "$(spawn::envelope_jq model)"' + {ok:true, alias:$a, text:$t,
          output_file:null, bytes:$b, usage:$u, error:null,
          model_scope:$ms, model_scope_notice:$mn, exit_code:0}')" \
        || REMEDY="The model answered but jq could not encode the response. Check jq is a working build; the answer itself is lost, so the call must be made again." \
            die "$EX_USAGE" "internal" "could not encode the response object"
fi
exit $EX_OK

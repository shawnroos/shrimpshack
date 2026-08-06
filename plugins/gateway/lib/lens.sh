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
#   The `error` field distinguishes `rate_limited` and `context_overflow` from
#   other upstream failures.
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
CTL="$SCRIPT_DIR/gatewayctl.sh"

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------
EX_OK=0
EX_USAGE=2
EX_UNREACHABLE=3
# EX_ALIAS=4 is never produced HERE. The served-list check lives in
# gatewayctl.sh ensure (KTD3) so both surfaces inherit one definition of exit 4;
# this script propagates ensure's code and its JSON verbatim rather than
# re-deriving "unknown alias" from an upstream error body.
EX_UPSTREAM=5
EX_DEADLINE=6
EX_AUTH=7

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
CONNECT_TIMEOUT="${GATEWAY_CONNECT_TIMEOUT:-2}"
TOTAL_TIMEOUT="${GATEWAY_LENS_TIMEOUT:-600}"

# KTD8 spill threshold. An unbounded return exhausts a fan-out orchestrator's
# context — multi-slice-review already codifies why.
SPILL_BYTES="${GATEWAY_SPILL_BYTES:-16384}"

DEFAULT_MAX_TOKENS="${GATEWAY_LENS_MAX_TOKENS:-8192}"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
say() { printf '▸ %s\n' "$*" >&2; }

# The single stdout write. Every path funnels through here so "exactly one JSON
# object, always" is a property of the code shape rather than of discipline.
EMITTED=0
emit() {
    [ "$EMITTED" -eq 1 ] && return 0
    EMITTED=1
    printf '%s\n' "$1"
}

ALIAS=""
emit_error() {
    # $1 = exit code, $2 = machine-readable error value, rest = human detail.
    local code="$1" err="$2"; shift 2
    [ "$EMITTED" -eq 1 ] && return 0
    if command -v jq >/dev/null 2>&1; then
        emit "$(jq -nc --arg a "$ALIAS" --arg e "$err" --arg d "$*" --argjson c "$code" \
            '{ok:false, alias:(if $a == "" then null else $a end), text:null,
              usage:null, error:$e, detail:$d, exit_code:$c}')"
    else
        EMITTED=1
        printf '{"ok":false,"alias":null,"text":null,"usage":null,"error":"%s","exit_code":%s}\n' "$err" "$code"
    fi
}

die() {
    local code="$1" err="$2"; shift 2
    printf '✗ %s\n' "$*" >&2
    emit_error "$code" "$err" "$*"
    exit "$code"
}

# TMPWORK holds scratch that MUST NOT outlive the call: the request body and,
# above all, the mode-0600 credential file (KTD6 permits it only as an
# ephemeral file created and removed within a single invocation). The spill
# file is deliberately NOT in here — it is the return value, and a return value
# deleted by our own EXIT trap is a path the caller cannot read.
TMPWORK=""
cleanup() {
    [ -n "$TMPWORK" ] && rm -rf "$TMPWORK" 2>/dev/null
    return 0
}
trap cleanup EXIT

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
            printf '✗ cannot create a temp dir\n' >&2; exit 2; }
    fi
}

need_jq() {
    command -v jq >/dev/null 2>&1 || {
        printf '✗ jq is required (the contract is one JSON object on stdout)\n' >&2
        printf '{"ok":false,"alias":null,"text":null,"usage":null,"error":"usage","exit_code":2}\n'
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
        -h|--help)      usage; need_jq; die "$EX_USAGE" "usage" "help requested" ;;
        --) shift
            # Everything after -- would be an argv prompt. Refused: see below.
            [ $# -gt 0 ] && { need_jq; die "$EX_USAGE" "usage" "the prompt is never taken from argv (KTD8) — pipe it on stdin or pass --prompt-file"; }
            ;;
        *)
            # THE ARGV-PROMPT REFUSAL. A caller that writes
            #   lens.sh --alias x "here is my 40KB diff"
            # must fail loudly and immediately. Accepting it would work in
            # testing and then silently truncate or mangle the first real
            # review-sized prompt, which is exactly the failure KTD8 names.
            need_jq
            die "$EX_USAGE" "usage" "unexpected argument '$1' — the prompt is never taken from argv (KTD8); pipe it on stdin or pass --prompt-file"
            ;;
    esac
done

need_jq

[ -n "$ALIAS" ] || { usage; die "$EX_USAGE" "usage" "--alias is required"; }
validate_alias "$ALIAS"

[[ "$TOTAL_TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
    || die "$EX_USAGE" "usage" "--timeout must be a number of seconds, got '$TOTAL_TIMEOUT'"
MAX_TOKENS="${MAX_TOKENS:-$DEFAULT_MAX_TOKENS}"
[[ "$MAX_TOKENS" =~ ^[0-9]+$ ]] \
    || die "$EX_USAGE" "usage" "--max-tokens must be a positive integer, got '$MAX_TOKENS'"

# ---------------------------------------------------------------------------
# Prompt intake (KTD8): stdin by default, --prompt-file alternative.
# ---------------------------------------------------------------------------
tmpwork
WORK="$TMPWORK"
PROMPT_PATH="$WORK/prompt.txt"

if [ -n "$PROMPT_FILE" ]; then
    [ -f "$PROMPT_FILE" ] || die "$EX_USAGE" "usage" "--prompt-file '$PROMPT_FILE' is not a readable file"
    cp "$PROMPT_FILE" "$PROMPT_PATH" 2>/dev/null \
        || die "$EX_USAGE" "usage" "could not read --prompt-file '$PROMPT_FILE'"
else
    # A TTY on stdin with no --prompt-file means nobody piped anything. Reading
    # would block forever with no output at all — the worst failure mode for an
    # unattended agent caller, because it looks like work in progress.
    if [ -t 0 ]; then
        usage
        die "$EX_USAGE" "usage" "no prompt: stdin is a terminal and --prompt-file was not given"
    fi
    cat > "$PROMPT_PATH"
fi

[ -s "$PROMPT_PATH" ] || die "$EX_USAGE" "usage" "the prompt is empty"

# ---------------------------------------------------------------------------
# Preflight (U3 step 2/3): gatewayctl.sh ensure <alias>.
#
# The alias is passed so the served-list check and its exit 4 come from ONE
# place (KTD3). ensure already prints a contract-shaped JSON object naming the
# alias and the served list, so on failure this script re-emits THAT object
# verbatim and propagates the code unchanged. Printing our own object on top of
# it would put two objects on stdout — the exact bug KTD2 exists to stop.
# ---------------------------------------------------------------------------
ENSURE_OUT="$(bash "$CTL" ensure "$ALIAS")"
ENSURE_RC=$?
if [ "$ENSURE_RC" -ne 0 ]; then
    if [ -n "$ENSURE_OUT" ]; then
        emit "$ENSURE_OUT"
    else
        emit_error "$ENSURE_RC" "preflight_failed" "gatewayctl ensure failed with code $ENSURE_RC and printed nothing"
    fi
    exit "$ENSURE_RC"
fi

BASE_URL="$(printf '%s' "$ENSURE_OUT" | jq -r '.base_url // empty')"
[ -n "$BASE_URL" ] || die "$EX_UNREACHABLE" "preflight_failed" "gatewayctl ensure returned no base_url"
BASE_URL="${BASE_URL%/}"

# ---------------------------------------------------------------------------
# Token resolution.
#
# The token comes from the SAME place gatewayctl's probe reads it — server.token
# in the resolved gateway.yaml, with ${VAR} expansion — because a lens that
# authenticated with a different token than the probe would pass preflight and
# then 401, and that divergence is undebuggable from the outside. When
# GATEWAY_CONFIG is unset, the config path is taken from `status`, which already
# owns install-dir resolution (KTD4), rather than re-deriving it here.
# ---------------------------------------------------------------------------
expand_env_refs() {
    local s="$1" out="" name val
    while [[ "$s" =~ ^([^$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; do
        name="${BASH_REMATCH[2]}"
        val="${!name-}"
        out+="${BASH_REMATCH[1]}${val}"
        s="${BASH_REMATCH[3]}"
    done
    printf '%s' "${out}${s}"
}

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

CONFIG_PATH="${GATEWAY_CONFIG:-}"
if [ -z "$CONFIG_PATH" ]; then
    CONFIG_PATH="$(bash "$CTL" status 2>/dev/null | jq -r '.config // empty')"
fi
TOKEN=""
if [ -n "$CONFIG_PATH" ]; then
    TOKEN="$(expand_env_refs "$(read_server_token "$CONFIG_PATH")")"
fi
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
    || die "$EX_USAGE" "usage" "could not encode the prompt as a JSON request body"

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
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
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
# curl owns the deadline via --max-time, so the timeout kills the request from
# INSIDE the child rather than from a watchdog that signals it: there is no
# window in which a backgrounded curl outlives this script. That is what "no
# orphaned child process on deadline" means in practice.
# ---------------------------------------------------------------------------
RESP="$WORK/resp.json"
: > "$RESP"
HTTP="$(curl -sS -o "$RESP" -w '%{http_code}' \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TOTAL_TIMEOUT" \
    --config "$CURLRC" 2>"$WORK/curl.err")"
CURL_RC=$?

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
        || die "$EX_USAGE" "usage" "could not write --output-file '$OUTPUT_FILE'"
    SPILLED="$OUTPUT_FILE"
elif [ "$TEXT_BYTES" -gt "$SPILL_BYTES" ]; then
    SPILLED="$(umask 077; mktemp "${TMPDIR:-/tmp}/gwlens-response.XXXXXX")" \
        || die "$EX_USAGE" "usage" "could not create a spill file"
    cp "$TEXT_FILE" "$SPILLED" 2>/dev/null \
        || die "$EX_USAGE" "usage" "could not write the spill file '$SPILLED'"
    say "response is ${TEXT_BYTES}B (> ${SPILL_BYTES}B) — spilled to $SPILLED"
fi

if [ -n "$SPILLED" ]; then
    emit "$(jq -nc --arg a "$ALIAS" --arg f "$SPILLED" --argjson u "$USAGE_JSON" --argjson b "$TEXT_BYTES" \
        '{ok:true, alias:$a, text:null, output_file:$f, bytes:$b, usage:$u, error:null, exit_code:0}')"
else
    # KTD5: the model's prose is UNTRUSTED DATA. JSON encoding escapes control
    # bytes in transit, but a consumer gets the raw bytes back on parse — so a
    # consumer that prints this owns its own sink. Documented, not filtered:
    # stripping here would corrupt legitimate code blocks in the answer.
    emit "$(jq -nc --arg a "$ALIAS" --rawfile t "$TEXT_FILE" --argjson u "$USAGE_JSON" --argjson b "$TEXT_BYTES" \
        '{ok:true, alias:$a, text:$t, output_file:null, bytes:$b, usage:$u, error:null, exit_code:0}')"
fi
exit $EX_OK

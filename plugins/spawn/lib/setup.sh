#!/usr/bin/env bash
# setup.sh — the gateway plugin's setup path (plan U2 onward).
#
#   setup.sh acquire      fetch, build and promote the latest gateway release
#   setup.sh gw           rewrite ~/.local/bin/gw as a Keychain-sourced,
#                         plugin-delegating wrapper (U5)
#   setup.sh wire         wire the installed harnesses — Claude Code's shell
#                         token snippet and Codex's managed config block (U6)
#
# This file grows one verb per unit.
#
# CONTRACT (KTD2 owns it; this file implements it, it does not redefine it):
#   exactly one JSON object on stdout, ALWAYS, including every failure path;
#   diagnostics on stderr only. Every object carries ok, error and exit_code.
#
# EXIT CODES. KTD17 adds exactly two codes to the plugin's enum — 8 and 9 — so
# this file MINTS NOTHING NEW and maps its own failures onto what already
# exists. The mapping is stated here so the later setup units adopt it instead
# of re-deriving it:
#   0 ok · 2 usage, or a REFUSAL this script makes on its own invariants (a
#   staging directory that is not a complete install) · 3 could not produce a
#   runnable install: the release lookup, the download, the extract or the build
#   failed · 8 operator confirmation required (U4+) · 9 a prerequisite binary is
#   missing.
#
# WHY A STAGING DIRECTORY, AND WHY IT LIVES WHERE IT DOES (KTD4)
# --------------------------------------------------------------
# resolve_install_dir in spawnctl.sh picks the HIGHEST-VERSION ~/gateway-*
# directory and dies if THAT directory holds no runnable binary. There is no
# fallback to an older working install. So building in place under the final
# version name has two failure modes, both of which hit every OTHER process on
# the machine while the build runs:
#   * before the binary lands, every concurrent status/lens/launch resolves the
#     half-made directory and exits 3 — "no gateway install found" on a machine
#     that has a perfectly good one;
#   * after the binary lands but before the config does, resolution SUCCEEDS,
#     the probe reads an empty token out of the missing config, presents it to
#     the still-running old gateway, is refused, and reports exit 7 — pointing
#     the operator at an authentication problem that does not exist.
# Hence: build somewhere the `gateway-*` glob cannot match, and become visible
# in ONE atomic move that happens only when the directory is already complete.
#
# The staging directory sits under $SEARCH_ROOT (dot-prefixed, so the glob
# cannot see it) rather than under $TMPDIR, and that is deliberate: on a real
# machine $TMPDIR and $HOME are different filesystems, where `mv` degrades to
# copy-then-delete — which is precisely the slow, half-visible directory this
# whole design exists to prevent. Same filesystem is what makes the move atomic.
#
# set -e is deliberately OFF (only -u -o pipefail). Every failure path here is
# an exit code the contract names; letting bash exit on the first non-zero
# command would turn a classified 9 or 3 into an unclassified 1 with no JSON.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# KTD5. Sourced, not re-implemented: three copies of a sanitizer is how one of
# them silently drifts. Unlike common.sh and secrets.sh, this file HAS a
# terminal sink — it reports which step failed and what it had already changed
# (R18) — so it is a full citizen of the escapes.bats sink lint.
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"

# Same reason, applied to the plain helpers: emit and the ${VAR} expander were
# byte-identical copies across the scripts before common.sh existed.
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

# The Keychain primitives (U1). Setup needs exactly one thing from them here:
# whether a gateway token is STORED — never its value. See require_token_delivery.
# shellcheck source=./secrets.sh
. "$SCRIPT_DIR/secrets.sh"

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------
EX_OK=0
EX_USAGE=2
EX_UNREACHABLE=3
# KTD17's confirmation path: setup.sh is non-interactive, so a change that needs
# the operator's say-so is REFUSED with this code and a JSON object naming what
# needs consent. The caller (commands/setup.md) asks once and re-invokes with the
# matching --consent-* flag. No other new code is minted.
EX_CONSENT=8
EX_PREREQ=9

# ---------------------------------------------------------------------------
# Configuration surface. Every knob is env-overridable because the tests must
# be able to point the whole script at fixtures: a suite that fetched from
# GitHub and ran a real cargo build would be slow, rate-limited, and dependent
# on what upstream published this morning — all three of which are how a
# "passing" suite stops meaning anything.
# ---------------------------------------------------------------------------
GATEWAY_REPO="${SPAWN_GATEWAY_REPO:-superagent-ai/gateway}"

# Where ~/gateway-* lives, and therefore where staging lives too. Same variable
# spawnctl.sh resolves against, so a test that redirects one redirects both.
SEARCH_ROOT="${SPAWN_SEARCH_ROOT:-$HOME}"

# Seams (KTD8), same shape as SPAWN_CLAUDE_BIN in launch.sh.
SPAWN_CURL_BIN="${SPAWN_CURL_BIN:-curl}"
SPAWN_CARGO_BIN="${SPAWN_CARGO_BIN:-cargo}"
SPAWN_TAR_BIN="${SPAWN_TAR_BIN:-tar}"

# The two harnesses U6 wires. Detection is KTD12 — `command -v`, never config
# presence and never asking — so these are the SAME names the operator's PATH
# would resolve, and the seams exist so a suite can hand this script a PATH
# holding one, both or neither. SPAWN_CLAUDE_BIN is launch.sh's existing seam
# name, deliberately reused rather than re-spelled.
SPAWN_CLAUDE_BIN="${SPAWN_CLAUDE_BIN:-claude}"
SPAWN_CODEX_BIN="${SPAWN_CODEX_BIN:-codex}"

# Budgets sized from the HEALTHY path: an API lookup is a small JSON read, a
# source archive is a few MB. The build gets no deadline at all — a real
# `cargo build --release` legitimately runs for minutes, and a timeout tuned to
# anything shorter would kill working builds on a cold cargo registry.
API_TIMEOUT="${SPAWN_SETUP_API_TIMEOUT:-30}"
DOWNLOAD_TIMEOUT="${SPAWN_SETUP_DOWNLOAD_TIMEOUT:-300}"
# Bound on the "does this binary actually run?" probe (seconds). There is no
# `timeout` binary on macOS, so this is enforced in-process; see run_bounded.
PROBE_BUDGET="${SPAWN_SETUP_PROBE_BUDGET:-10}"

# The config file name is the gateway's own, verified against the upstream repo
# root (superagent-ai/gateway ships gateway.yaml at the top level).
CONFIG_NAME="gateway.yaml"
# Where a config template may hide inside a source archive, most likely first.
CONFIG_CANDIDATES=("gateway.yaml" "config/gateway.yaml" "gateway.example.yaml")

# Keychain coordinates. Byte-identical defaults and override names to
# spawnctl.sh's — the two scripts are talking about the SAME two items, and a
# service name spelled differently in one of them is a credential neither can
# find. Overrides exist so the suites can point the whole path at a fake store.
KEYCHAIN_SERVICE="${SPAWN_KEYCHAIN_SERVICE:-spawn-gateway}"
KEYCHAIN_ACCOUNT_TOKEN="${SPAWN_KEYCHAIN_ACCOUNT_TOKEN:-gateway-token}"
# The OpenRouter key's account name, spelled the way spawnctl.sh spells it for
# the same reason: the two scripts are talking about the SAME item, and setup is
# the only writer of it.
KEYCHAIN_ACCOUNT_OPENROUTER="${SPAWN_KEYCHAIN_ACCOUNT_OPENROUTER:-openrouter-api-key}"

# The wrapper setup rewrites (KD8, R19). Overridable so no suite can ever be one
# typo away from writing the operator's real `gw`.
GW_PATH="${SPAWN_GW_PATH:-$HOME/.local/bin/gw}"

# The delegation target, baked ABSOLUTE into the emitted wrapper (KTD14). It is
# resolved from this script's own location, so a setup re-run from a moved or
# reinstalled plugin re-bakes the new path rather than leaving the wrapper
# pointing at a directory that no longer exists.
SPAWNCTL_PATH="${SPAWN_SPAWNCTL_PATH:-$SCRIPT_DIR/spawnctl.sh}"

# ---------------------------------------------------------------------------
# U6's write targets. EVERY ONE OF THEM IS A SAFETY RAIL, for the same reason
# SPAWN_GW_PATH is: these are the operator's real dotfiles, and a suite that ran
# against the defaults would rewrite the shell rc of the machine it is testing
# on. Each override points the whole path at a sandbox.
# ---------------------------------------------------------------------------
# Codex's config file. `~/.codex/config.toml` is Codex's own path; setup writes
# a MARKER-DELIMITED BLOCK inside it and never owns the whole file — the rest is
# the operator's, and a re-run must leave it byte-identical.
CODEX_CONFIG="${SPAWN_CODEX_CONFIG:-$HOME/.codex/config.toml}"

# KTD15's sourced snippet, and the rc file that sources it. The snippet holds a
# Keychain READ, never a value, so rotation reaches every new shell with no
# rewrite. Appending the source line to the rc is an edit to a file setup does
# not own, so it is consent-gated (KTD17).
GATEWAY_ENV_FILE="${SPAWN_GATEWAY_ENV_FILE:-$HOME/.gateway/env.sh}"
SHELL_RC="${SPAWN_SHELL_RC:-$HOME/.zshrc}"

# The gateway's own root URL. Derived from spawnctl.sh's SPAWN_BASE_URL seam so
# a test that redirects one redirects both, with the `/anthropic` suffix trimmed:
# that suffix is Claude Code's route prefix, and Codex needs the ROOT plus `/v1`.
GATEWAY_ROOT_URL="${SPAWN_GATEWAY_ROOT_URL:-${SPAWN_BASE_URL:-http://127.0.0.1:4000/anthropic}}"
GATEWAY_ROOT_URL="${GATEWAY_ROOT_URL%/anthropic}"
GATEWAY_ROOT_URL="${GATEWAY_ROOT_URL%/}"

# The window table (KTD7, KTD19). Same variable name and default spawnctl.sh
# resolves against.
MODELS_JSON="${SPAWN_MODELS_JSON:-$SCRIPT_DIR/models.json}"

# The gateway config whose alias list is intersected with the table. SPAWN_CONFIG
# is spawnctl.sh's override, reused for the same reason.
WIRE_CONFIG="${SPAWN_CONFIG:-}"

# The TOML table key the emitted provider lives under. A bare key, so it needs no
# quoting anywhere it is referenced.
CODEX_PROVIDER_ID="${SPAWN_CODEX_PROVIDER_ID:-spawn_gateway}"

# Bound on the `codex doctor` call. Same reason run_bounded exists at all: the
# thing being run is a third-party binary, and a hang is worse than a named
# failure.
DOCTOR_BUDGET="${SPAWN_SETUP_DOCTOR_BUDGET:-20}"

# Binary candidates inside an install dir, most specific first.
#
# DELIBERATE DUPLICATION of the list in spawnctl.sh, and the one thing that
# makes it safe: setup-acquire.bats asserts the two BIN_CANDIDATES lines are
# byte-identical. Sourcing spawnctl.sh is not available — it dispatches a verb
# and exits at the bottom of the file — and moving the list into common.sh
# would edit three scripts to save one line. Drift is the real risk here (this
# plugin already carries the scar of three copies of one parser), so it is
# closed by a test rather than by discipline.
BIN_CANDIDATES=("target/release/gateway" "target/debug/gateway" "bin/gateway" "gateway")

# ---------------------------------------------------------------------------
# Plumbing. Same chokepoints as the sibling scripts, deliberately byte-identical
# where the escapes.bats lint reads them: a defence spelled differently in each
# file is a defence the lint cannot verify.
# ---------------------------------------------------------------------------
say() { printf '▸ %s\n' "$(spawn::sanitize_for_display "$*")" >&2; }
die() {
    # $1 = exit code, rest = message. Stderr only — stdout belongs to the one
    # JSON object. The sanitize call is INLINE at the printf rather than hidden
    # behind a local, because the lint reads these lines and a defence it cannot
    # see is one the next reviewer cannot verify either.
    local code="$1"; shift
    printf '✗ %s\n' "$(spawn::sanitize_for_display "$*")" >&2
    # R18. Under the orchestrator every failure object carries the accumulated
    # state report — the step that failed and everything already changed —
    # rather than the bare {ok,error,exit_code} a single verb emits. Routed HERE
    # rather than at each call site so a failure path added later cannot forget:
    # there is exactly one exit door and it already knows.
    if [ "$ORCHESTRATING" -eq 1 ]; then
        emit_setup_failure "$code" "$*"
    else
        emit_error "$code" "$*"
    fi
    exit "$code"
}

VERB="${1:-}"

# Staging state. STAGING_ROOT holds the download and the build tree; ASIDE is
# the previous install moved out of the way during a same-version upgrade. Both
# are cleaned by the trap, and ASIDE is RESTORED rather than deleted if the
# swap died between the two moves — a crash there must never leave the machine
# with no install at all.
STAGING_ROOT=""
ASIDE=""
ASIDE_DEST=""
cleanup() {
    if [ -n "$ASIDE" ] && [ -d "$ASIDE" ]; then
        if [ -n "$ASIDE_DEST" ] && [ ! -e "$ASIDE_DEST" ]; then
            mv "$ASIDE" "$ASIDE_DEST" 2>/dev/null
        else
            rm -rf "$ASIDE" 2>/dev/null
        fi
    fi
    [ -n "$STAGING_ROOT" ] && rm -rf "$STAGING_ROOT" 2>/dev/null
    return 0
}
trap cleanup EXIT
# bash does NOT run an EXIT trap when the shell dies on an untrapped INT/TERM/
# HUP (measured on this box, bash 5.3.15). Without these, a cancelled setup
# leaks a staging directory into $HOME — and, worse, could leave a previous
# install parked under its aside name with nothing at gateway-<version>. These
# exit THROUGH the EXIT path rather than calling cleanup directly: a bare
# `trap cleanup INT` runs cleanup and then lets the script keep going.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

need_jq() {
    command -v jq >/dev/null 2>&1 || {
        printf '✗ jq is required (the contract is one JSON object on stdout)\n' >&2
        # "exactly one JSON object on stdout, ALWAYS" includes the path where
        # the encoder itself is missing. VERB is raw argv, so it is reduced to
        # the verb enum's own charset — unsanitized, it could put a quote or an
        # escape byte into stdout.
        printf '{"ok":false,"verb":"%s","error":"internal","exit_code":2}\n' "${VERB//[^a-z]/}"
        exit 2
    }
}

EMITTED=0
emit_error() {
    local code="$1" msg="$2"
    [ "$EMITTED" -eq 1 ] && return 0
    # Sanitized here as well as in die(): idempotent on an already-clean string,
    # and it means a future caller reaching emit_error directly cannot open a
    # hole in the `error` field, which is display text a consumer prints.
    msg="$(spawn::sanitize_for_display "$msg")"
    if command -v jq >/dev/null 2>&1; then
        emit "$(jq -nc --arg v "$(spawn::sanitize_for_display "$VERB")" --arg e "$msg" --argjson c "$code" \
            '{ok:false, verb:$v, error:$e, exit_code:$c}')" && return 0
    fi
    # Pure-bash fallback, for a jq that is present but errored. Both fields are
    # reduced to a safe charset rather than quoted, because a hand-rolled JSON
    # encoder that tries to escape arbitrary bytes is how invalid JSON reaches
    # a consumer that was promised it could parse this whole.
    emit "$(printf '{"ok":false,"verb":"%s","error":"%s","exit_code":%d}' \
        "${VERB//[^a-z]/}" "${msg//[^A-Za-z0-9 ._:\/-]/ }" "$code")"
}

# ===========================================================================
# THE ORCHESTRATOR'S STATE REPORT (U7; R18, F1, F3)
# ===========================================================================
#
# R18 says a failure names the step that failed AND what had already been
# changed. The tempting shape is to work that out in the error handler — walk
# the filesystem, re-read the Keychain, reconstruct what probably happened. That
# is a SECOND implementation of the run, written under the worst conditions
# (something has just gone wrong), and it drifts the day a step is added.
#
# So the state report is ACCUMULATED AS THE RUN GOES. Every step appends its own
# outcome the moment it settles, and every change appends itself at the point it
# is made. The failure object and the success object serialize THE SAME two
# accumulators — which is what makes the property testable from both sides: a
# success that carried no steps would be as wrong as a failure that carried no
# changes.
#
# ORCHESTRATING is the switch that routes die() here. It stays 0 for the single
# verbs (`acquire`, `gw`, `wire`), whose one-object contract is unchanged.
# ---------------------------------------------------------------------------
ORCHESTRATING=0
CURRENT_STEP=""
STEPS_JSON="[]"
CHANGED_JSON="[]"
# What the failure object needs to name the release it just installed (F3).
SETUP_TAG=""
SETUP_INSTALL_DIR=""
# Filled by the wire step so the final object can report them; empty until then,
# and reported as such rather than as an empty success.
SETUP_WIRED_JSON="[]"
SETUP_SKIPPED_JSON="[]"
SETUP_LOSSES_JSON="[]"
SETUP_GAPS_JSON="[]"
SETUP_ACTIVATION_JSON="null"
SETUP_VERIFY_JSON="null"
SETUP_FAILURE_CLASS=""

# step_start <name> — the step that is now in flight. A failure inside it is
# attributed to this name with no further bookkeeping at the failure site.
step_start() { CURRENT_STEP="$1"; }

# step_done <name> <status> <detail> — one settled step, appended in order.
step_done() {
    STEPS_JSON="$(printf '%s' "$STEPS_JSON" | jq -c \
        --arg n "$1" --arg s "$2" --arg d "$(spawn::sanitize_for_display "$3")" \
        '. + [{step:$n, status:$s, detail:$d}]' 2>/dev/null)" || STEPS_JSON="[]"
    CURRENT_STEP=""
}

# record_change <what> <target> <detail> — one thing this machine now has that
# it did not have before. Appended AT THE POINT OF CHANGE, never inferred later.
# `target` is a path or a Keychain coordinate; NO VALUE EVER GOES IN HERE — the
# whole object is printed, and R5 forbids the key reaching any output.
record_change() {
    CHANGED_JSON="$(printf '%s' "$CHANGED_JSON" | jq -c \
        --arg w "$1" --arg t "$(spawn::sanitize_for_display "$2")" --arg d "$(spawn::sanitize_for_display "$3")" \
        '. + [{what:$w, target:$t, detail:$d}]' 2>/dev/null)" || CHANGED_JSON="[]"
}

# emit_setup_failure <code> <message> — the R18 object. It SERIALIZES the
# accumulators; it does not build them. If this function had to work out what
# had changed, mutating it would be the only way to break the report, and the
# accumulation it is meant to prove would be untested.
emit_setup_failure() {
    local code="$1" msg="$2" steps
    [ "$EMITTED" -eq 1 ] && return 0
    msg="$(spawn::sanitize_for_display "$msg")"
    if ! command -v jq >/dev/null 2>&1; then
        emit_error "$code" "$msg"
        return 0
    fi
    # The in-flight step is closed as failed here rather than left dangling: a
    # steps array whose last entry is missing is a report that names everything
    # except the answer.
    steps="$(printf '%s' "$STEPS_JSON" | jq -c --arg n "${CURRENT_STEP:-unknown}" --arg e "$msg" \
        'if $n == "" then . else . + [{step:$n, status:"failed", detail:$e}] end' 2>/dev/null)"
    [ -n "$steps" ] || steps="$STEPS_JSON"
    emit "$(jq -nc \
        --arg e "$msg" --argjson c "$code" \
        --argjson steps "$steps" --argjson changed "$CHANGED_JSON" \
        --argjson wired "$SETUP_WIRED_JSON" --argjson skipped "$SETUP_SKIPPED_JSON" \
        --argjson losses "$SETUP_LOSSES_JSON" --argjson gaps "$SETUP_GAPS_JSON" \
        --argjson verification "$SETUP_VERIFY_JSON" \
        --arg step "${CURRENT_STEP:-unknown}" --arg tag "$SETUP_TAG" --arg dir "$SETUP_INSTALL_DIR" \
        --arg class "$SETUP_FAILURE_CLASS" \
        '{ok:false, verb:"setup", failed_step:$step, failure_class:(if $class == "" then null else $class end),
          steps:$steps, changed:$changed, wired:$wired, skipped:$skipped,
          losses:$losses, validation_gaps:$gaps, verification:$verification,
          release:{tag:(if $tag == "" then null else $tag end),
                   install_dir:(if $dir == "" then null else $dir end)},
          error:$e, exit_code:$c}')" \
        || emit_error "$code" "$msg"
    return 0
}

# ---------------------------------------------------------------------------
# run_bounded <seconds> <command...>
# Runs a command with a wall-clock bound, returning its status, or 124 if it
# had to be killed. There is NO `timeout` binary on macOS — reaching for one
# gives a command-not-found whose non-zero status reads exactly like the probe
# failing, so the "is this binary runnable?" question would answer "no" on
# every machine. The bound matters because the thing being run is an arbitrary
# file found on disk: a binary that ignores --version and starts serving would
# otherwise hang setup forever, and a hang is worse than a named failure.
#
# The bound itself lives in run_bounded_out below; this is the discard-stdout
# case of the same thing. One copy of the kill/wait sequencing, so a fix to it
# cannot land in only half the callers.
# ---------------------------------------------------------------------------
run_bounded() {
    run_bounded_out "$1" /dev/null "${@:2}"
}

# ---------------------------------------------------------------------------
# run_bounded_out <seconds> <stdout-file> <command...>
# run_bounded with the child's STDOUT KEPT. Same bound, same 124, and it exists
# because the KTD20 validation needs the JSON body, not just a status — the
# whole point of that decision is that the status is the thing it must NOT
# believe.
# ---------------------------------------------------------------------------
run_bounded_out() {
    local secs="$1" out="$2"; shift 2
    local pid i rc
    : > "$out"
    "$@" </dev/null >"$out" 2>/dev/null &
    pid=$!
    for ((i = 0; i < secs * 10; i++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 124
    fi
    wait "$pid"
    rc=$?
    return "$rc"
}

# ---------------------------------------------------------------------------
# Prerequisites (R4). Checked BEFORE anything is fetched, built or written, so
# a machine without a Rust toolchain learns that in one second rather than
# after a multi-megabyte download. Exit 9 names the missing binary; a caller
# reading "setup failed" with no name has nothing to act on.
#
# A seam pointing at a PATH must be an executable file; a bare name is looked
# up on PATH. Both are checked, because a test that points a seam at a deleted
# fixture and a machine with no cargo are the same failure and must report the
# same way.
# ---------------------------------------------------------------------------
need_prereqs() {
    local name path missing=""
    for name in curl cargo tar; do
        case "$name" in
            curl)  path="$SPAWN_CURL_BIN" ;;
            cargo) path="$SPAWN_CARGO_BIN" ;;
            tar)   path="$SPAWN_TAR_BIN" ;;
        esac
        case "$path" in
            */*) [ -f "$path" ] && [ -x "$path" ] || missing="$name" ;;
            *)   command -v "$path" >/dev/null 2>&1 || missing="$name" ;;
        esac
        [ -n "$missing" ] && die "$EX_PREREQ" "missing prerequisite: $missing (resolved to '$path'; install it, or point the matching SPAWN_*_BIN seam at it)"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Release resolution (KTD16). The TAG is pinned and the COMMIT SHA is recorded;
# no tarball checksum is stored, because GitHub generates source archives on
# demand and they are not byte-stable (verified) — a stored hash would break
# spuriously and train the operator to ignore it.
#
# curl runs with -fsSL: -f turns an HTTP error into a non-zero status instead of
# a 404 body that jq would happily parse into a null tag.
#
# BOTH FUNCTIONS RETURN THROUGH A GLOBAL, NOT STDOUT, and that is not a style
# choice. A `tag="$(latest_tag)"` form runs the function in a SUBSHELL, so the
# JSON object die() writes to stdout would be CAPTURED INTO THE VARIABLE
# instead of reaching the consumer, exit would end the subshell only, and the
# caller would sail on with a JSON blob as its tag. The contract says one JSON
# object on stdout on every failure path; a die inside a command substitution
# silently breaks it.
# ---------------------------------------------------------------------------
LATEST_TAG=""
COMMIT_SHA=""

resolve_latest_tag() {
    local body
    body="$("$SPAWN_CURL_BIN" -fsSL --max-time "$API_TIMEOUT" \
        "https://api.github.com/repos/$GATEWAY_REPO/releases/latest" 2>/dev/null)" \
        || die "$EX_UNREACHABLE" "step 'resolve release': could not reach the GitHub API for $GATEWAY_REPO (nothing has been changed on this machine)"
    LATEST_TAG="$(printf '%s' "$body" | jq -r '.tag_name // empty' 2>/dev/null)"
    # Validated against an identifier grammar rather than sanitized: this value
    # becomes a directory name and a URL path segment, and KTD5's rule is that
    # identifiers are closed BY CONSTRUCTION at the input site.
    [[ "$LATEST_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || die "$EX_UNREACHABLE" "step 'resolve release': the latest release of $GATEWAY_REPO carries no usable tag_name (nothing has been changed on this machine)"
}

resolve_commit_sha() {
    local tag="$1" body
    body="$("$SPAWN_CURL_BIN" -fsSL --max-time "$API_TIMEOUT" \
        "https://api.github.com/repos/$GATEWAY_REPO/commits/$tag" 2>/dev/null)" \
        || die "$EX_UNREACHABLE" "step 'resolve commit': could not resolve tag '$tag' to a commit (nothing has been changed on this machine)"
    COMMIT_SHA="$(printf '%s' "$body" | jq -r '.sha // empty' 2>/dev/null)"
    # The /commits/<ref> endpoint dereferences an annotated tag to its commit,
    # which /git/ref/tags/<tag> does not — that one returns the tag OBJECT's sha
    # for an annotated tag, which is not the commit and is not what R1 means by
    # recording the release's identity.
    [[ "$COMMIT_SHA" =~ ^[0-9a-f]{7,40}$ ]] \
        || die "$EX_UNREACHABLE" "step 'resolve commit': tag '$tag' resolved to no commit sha (nothing has been changed on this machine)"
}

# ---------------------------------------------------------------------------
# Install inspection
# ---------------------------------------------------------------------------
find_binary_in() {
    local dir="$1" cand
    for cand in "${BIN_CANDIDATES[@]}"; do
        # A REGULAR file, executable. `-x` alone is true of a directory, so a
        # stray `gateway/` dir would resolve as the binary.
        if [ -f "$dir/$cand" ] && [ -x "$dir/$cand" ]; then
            printf '%s' "$dir/$cand"
            return 0
        fi
    done
    return 1
}

# binary_runs <path> — R3's "and its binary runs". Presence is not enough: an
# interrupted build, a partially-restored backup, or a binary built for the
# other architecture all leave a file that resolves and then fails to execute,
# and skipping on those is how a machine stays broken across re-runs.
#
# --version then --help, because which one a given release answers is an
# upstream detail this plugin does not own; either exiting 0 proves the file
# executes, which is the whole question.
binary_runs() {
    local bin="$1"
    [ -f "$bin" ] && [ -x "$bin" ] || return 1
    run_bounded "$PROBE_BUDGET" "$bin" --version && return 0
    run_bounded "$PROBE_BUDGET" "$bin" --help && return 0
    return 1
}

# ---------------------------------------------------------------------------
# TOKEN RETIREMENT (KTD18; R9, R23)
#
# config_has_server_token <file> — 0 when the file declares an ACTIVE server
# token entry of any shape, 1 when it does not. It is a DETECTOR, not a parser:
# it never yields, prints or stores the value. That distinction is the whole
# point — this plugin already carries the scar of three near-identical
# server.token parsers, a fourth is forbidden, and retirement is deletion, so
# setup has no reason to ever hold the old literal.
#
# Commented shapes are not configuration and are left alone; the upstream
# template's own `# tokens: [...]` and `# token: "${GATEWAY_TOKEN}"` lines are
# documentation the operator should keep reading.
# ---------------------------------------------------------------------------
config_has_server_token() {
    [ -f "$1" ] || return 1
    awk '
        /^[A-Za-z_][A-Za-z0-9_-]*:/ { sec = $0; sub(/:.*$/, "", sec); next }
        sec != "server" { next }
        /^[ \t]*#/ { next }
        /^[ \t]+tokens?:/ { found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

# strip_server_token <src> <dst> — write <src> to <dst> with every active
# server token entry REMOVED and every other byte untouched.
#
# A line-level edit, deliberately. Rewriting the file through a YAML library
# would reflow comments, quoting and key order — and this file is the
# operator's, carrying their models, their providers and their notes. The three
# shapes removed are the three the gateway accepts:
#     token: <literal>        the shape the live config uses today
#     tokens: [a, b]          the flow-sequence list form
#     tokens:                 the block-sequence list form, with its `- item`
#       - a                   continuation lines
# KD5 forbids the reference shape `token: "${GATEWAY_TOKEN}"` as well: delivery
# through the environment replaces it, so a reference is just another entry to
# remove rather than a special case to preserve.
strip_server_token() {
    local src="$1" dst="$2"
    [ -f "$src" ] || return 1
    awk '
        # A top-level key ends whatever block we were in, including a dropped
        # tokens: list.
        /^[A-Za-z_][A-Za-z0-9_-]*:/ { sec = $0; sub(/:.*$/, "", sec); drop = 0; print; next }
        sec == "server" && /^[ \t]*#/ { print; next }
        sec == "server" && /^[ \t]+tokens?:/ { drop = 1; next }
        # Continuation of a dropped block sequence. Anything that is not a list
        # item ends the drop and is printed as usual.
        drop == 1 && /^[ \t]*-[ \t]/ { next }
        drop == 1 && /^[ \t]*-$/ { next }
        { drop = 0; print }
    ' "$src" > "$dst" || return 1
    return 0
}

# previous_config — the newest existing install's gateway.yaml, or nothing.
#
# `sort -V` over the candidate paths, matching the resolution order the secret
# scan in run-tests.sh already uses. This is NOT a fourth copy of
# resolve_install_dir: that resolver answers "which install do I run?" and hard-
# fails when the answer is unusable, while this answers "is there a config worth
# carrying forward?" — a question whose only failure mode is falling back to the
# template. On a same-version rebuild the newest install IS the destination, and
# migrating from it is exactly right: that is the operator's current config.
previous_config() {
    local d
    local -a cand=()
    for d in "$SEARCH_ROOT"/gateway-*/; do
        [ -f "$d$CONFIG_NAME" ] && cand+=("$d$CONFIG_NAME")
    done
    [ "${#cand[@]}" -gt 0 ] || return 1
    printf '%s\n' "${cand[@]}" | sort -V | tail -1
}

# ---------------------------------------------------------------------------
# stage_config <staging-dir> — make sure the staged tree carries a gateway.yaml
# that carries no token (KTD18).
#
# Two sources, in order:
#   1. the previous install's config, forward-MIGRATED — the operator's models,
#      providers, clients and comments survive an upgrade untouched;
#   2. on a bare machine, the upstream template, which the source archive
#      carries at its root (the candidate list exists because "at the root" is
#      an upstream layout detail, not a guarantee).
#
# THE STRIP RUNS ON BOTH PATHS, and that is not an over-reading of "the template
# as shipped". The upstream template ships an ACTIVE `token:` line carrying a
# placeholder value — a value published in a public repository, and the one
# this machine's own install is still running on. Emitting it verbatim would
# leave a bare machine authenticating with a token the whole internet knows,
# which is the failure R9 and R23 exist to prevent. "As shipped" governs where
# the CONTENT comes from (upstream, not a generator); token retirement applies
# to whatever content arrives.
#
# STAGED_CONFIG_ORIGIN records which path ran, for the operator-facing message.
# ---------------------------------------------------------------------------
STAGED_CONFIG_ORIGIN=""
stage_config() {
    local staging="$1" cand src="" prev tmp
    if prev="$(previous_config)" && [ -n "$prev" ]; then
        src="$prev"
        STAGED_CONFIG_ORIGIN="migrated"
    else
        STAGED_CONFIG_ORIGIN="template"
        for cand in "${CONFIG_CANDIDATES[@]}"; do
            if [ -f "$staging/$cand" ]; then
                src="$staging/$cand"
                break
            fi
        done
    fi
    if [ -n "$src" ]; then
        # Written beside the destination and moved into place, never edited in
        # flight: a strip that died halfway would otherwise leave a truncated
        # config that promote() would happily accept as complete.
        tmp="$staging/.$CONFIG_NAME.migrating"
        rm -f "$tmp" 2>/dev/null
        strip_server_token "$src" "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
        # The strip is checked by the detector rather than trusted. A silent
        # pass-through here is the exact defect that would put a live token back
        # into a promoted install while every other assertion stayed green.
        if config_has_server_token "$tmp"; then
            rm -f "$tmp" 2>/dev/null
            return 1
        fi
        mv "$tmp" "$staging/$CONFIG_NAME" || { rm -f "$tmp" 2>/dev/null; return 1; }
        return 0
    fi
    STAGED_CONFIG_ORIGIN=""
    return 1  # no template found
}

# ---------------------------------------------------------------------------
# require_token_delivery <config> — R9's static half.
#
# The staged config now declares no token, so the gateway's auth list will be
# whatever start-time delivery puts there and nothing else. An EMPTY auth list
# does not make the gateway reject callers; it makes its auth check pass
# everything, i.e. an open proxy on 127.0.0.1 forwarding to a paid provider. So
# an install that cannot be authenticated is refused BEFORE it becomes visible
# to the `gateway-*` glob, rather than after.
#
# keychain_exists, never keychain_read: setup has no use for the token's value,
# and materialising a secret to answer a yes/no question is how secrets end up
# in diagnostics. A stored-but-EMPTY item slips past this check and is caught by
# U3's start guard, which reads the value anyway and refuses on an empty one.
#
# The live half of R9 is that same start guard; this half exists because a
# promoted install is a durable artifact and "it will fail later" is not the
# same promise as "it was never installed unauthenticated".
# ---------------------------------------------------------------------------
require_stored_token() {
    spawn::keychain_exists "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_TOKEN" && return 0
    die "$EX_USAGE" "step 'config': refusing to leave a gateway whose $CONFIG_NAME declares no token while no gateway token is stored (Keychain service '$KEYCHAIN_SERVICE', account '$KEYCHAIN_ACCOUNT_TOKEN') — an empty auth token list makes the gateway an open proxy; store the credential first, then re-run. Nothing was moved into place."
}

require_token_delivery() {
    local cfg="$1"
    config_has_server_token "$cfg" && return 0
    require_stored_token
}

# ---------------------------------------------------------------------------
# retire_installed_token <config> — R23 on the SKIP path.
#
# `acquire` skips the fetch and build when the latest release is already
# installed and runnable. That is the state this machine is in today, and its
# config is the one still holding the literal token — so a skip that only
# skipped would mean setup never retires anything on exactly the machine the
# requirement was written for. The same line-level edit runs, in place, through
# a temp file and one rename: the config is being read by concurrent status and
# lens calls, and rename is the only way it is never seen half-written.
# ---------------------------------------------------------------------------
retire_installed_token() {
    local cfg="$1" tmp
    config_has_server_token "$cfg" || return 0
    require_stored_token
    tmp="$cfg.retiring.$$"
    rm -f "$tmp" 2>/dev/null
    strip_server_token "$cfg" "$tmp" \
        || { rm -f "$tmp" 2>/dev/null; die "$EX_USAGE" "step 'config': could not rewrite '$cfg' without its token entry; it is untouched"; }
    if config_has_server_token "$tmp"; then
        rm -f "$tmp" 2>/dev/null
        die "$EX_USAGE" "step 'config': the token entry in '$cfg' survived the edit; it is untouched"
    fi
    # Mode carried over rather than left to the umask: this file may already be
    # tightened, and a rename that loosened it would be a silent downgrade.
    # BSD stat first (this is a macOS-only path, KD11), GNU as the fallback.
    local mode
    mode="$(stat -f '%Lp' "$cfg" 2>/dev/null || stat -c '%a' "$cfg" 2>/dev/null)"
    [ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null
    mv "$tmp" "$cfg" \
        || { rm -f "$tmp" 2>/dev/null; die "$EX_USAGE" "step 'config': could not move the token-free '$cfg' into place; it is untouched"; }
    say "retired the server token entry in $cfg — the gateway now authenticates from the stored credential only"
    return 0
}

# ---------------------------------------------------------------------------
# promote <staging-dir> <destination> — the single atomic move (KTD4).
#
# REFUSED unless staging is already a COMPLETE install: a runnable binary AND a
# config. Promoting either half is the exact failure this whole unit exists to
# prevent, and the check lives here — at the one place that makes a directory
# visible to the `gateway-*` glob — rather than at the call sites.
#
# A destination that already exists (the same-version rebuild path) is swapped,
# not merged: a bare `mv staging dest` onto an existing directory moves staging
# INSIDE it, producing ~/gateway-0.1.1/.gateway-staging.XXXX and an install that
# looks untouched. Old is moved aside, new is moved in, old is deleted; the
# window between the two moves is covered by the trap, which puts the old
# directory back if the process dies inside it.
#
# The resolved binary comes back in PROMOTED_BIN rather than on stdout, for the
# same reason resolve_latest_tag uses a global: this function calls die, and a
# die inside a command substitution writes its JSON object into a variable
# instead of to the consumer.
# ---------------------------------------------------------------------------
PROMOTED_BIN=""
promote() {
    local staging="$1" dest="$2" bin
    bin="$(find_binary_in "$staging")" \
        || die "$EX_USAGE" "step 'promote': refusing to install '$dest' — the staged build holds no executable gateway binary (looked for: ${BIN_CANDIDATES[*]}); nothing was moved into place"
    [ -f "$staging/$CONFIG_NAME" ] \
        || die "$EX_USAGE" "step 'promote': refusing to install '$dest' — the staged build holds no $CONFIG_NAME, and an install with a binary but no config makes every concurrent status and lens misreport an auth failure (KTD4); nothing was moved into place"

    if [ -e "$dest" ]; then
        ASIDE_DEST="$dest"
        ASIDE="$SEARCH_ROOT/.gateway-replaced.$$"
        rm -rf "$ASIDE" 2>/dev/null
        mv "$dest" "$ASIDE" || die "$EX_USAGE" "step 'promote': could not move the existing install at '$dest' aside; it is untouched"
    fi
    mv "$staging" "$dest" || die "$EX_USAGE" "step 'promote': could not move the staged build into '$dest'"
    # Past the point of no return: the new install is live, so the aside copy is
    # no longer a rollback target and must not be restored by the trap.
    if [ -n "$ASIDE" ]; then
        rm -rf "$ASIDE" 2>/dev/null
        ASIDE=""
        ASIDE_DEST=""
    fi
    # Rebased onto the destination: the path found above pointed into staging,
    # which no longer exists. Reporting the staging path in the success object
    # would hand every consumer a path that is already gone.
    PROMOTED_BIN="$dest/${bin#"$staging/"}"
}

# ===========================================================================
# THE gw REWRITE (U5; KD8, KTD11, KTD14, KTD17 — R19, R20, R23)
# ===========================================================================
#
# WHY REWRITE IT AT ALL. `~/.local/bin/gw` is the surface that is actually in
# the operator's muscle memory, and it shares ~/.gateway.pid with the plugin's
# control layer on purpose so the two never double-start. Retiring it would
# throw away both. So it stays, and becomes a thin front door.
#
# WHY IT DELEGATES (KTD14). The wrapper's own start/stop/status logic carries
# three defects that spawnctl.sh has already fixed: liveness by `kill -0` on a
# pidfile (wrong on a stale pid and wrong again on a recycled one), a `>` log
# redirect that TRUNCATES the history that would explain a crash loop, and no
# lock at all, so concurrent callers race a start each. Reimplementing any of
# that here would be a fourth copy of control logic in a plugin that already
# carries the scar of three copies of one parser. `start|stop|restart|status`
# therefore exec spawnctl.sh; only `log` and `claude` stay local, because
# neither has an equivalent over there.
#
# WHY NOTHING SECRET IS IN THE EMITTED FILE (R23). The file this replaces
# carried a token literal on two lines. The generated one carries a Keychain
# READ instead — resolved in the operator's own shell, at the moment they run
# `gw claude`, so rotation reaches it with no rewrite and no value ever rests
# in the file. Same discipline launch.sh applies to its printed attach command:
# values travel by reference, never resolved into emitted text.
# ---------------------------------------------------------------------------

# The recognition marker (KTD11). Its exact text is part of the contract: a
# rewrite that changed it would make every previously generated wrapper read as
# hand-edited and demand consent it does not need.
GW_MARKER="# spawn-setup: generated wrapper — rewritten by /spawn:setup, edits are not preserved"
GW_HASH_PREFIX="# spawn-setup-body-sha256: "

# gw_hash — sha256 of stdin, bare hex. One implementation, used by BOTH the
# generator and the recognizer: two spellings of "the body's hash" is exactly
# how a wrapper starts reading as hand-edited the moment either side changes.
gw_hash() { shasum -a 256 | awk '{print $1}'; }

# gw_body — everything below the hash line. The first heredoc is EXPANDED (it
# bakes the absolute paths and the Keychain coordinates resolved right now);
# the second is QUOTED, so every `$` in it belongs to the wrapper's own runtime
# rather than to this script.
gw_body() {
    cat <<EOF
set -euo pipefail

# Baked at write time from the plugin's own location; a setup re-run re-bakes it.
SPAWNCTL="$SPAWNCTL_PATH"
# credentials are NEVER baked into this file: the token is read from the
# Keychain at run time, so rotating it reaches this wrapper with no rewrite.
EOF
    cat <<'EOF'

# Keychain coordinates, matching the plugin's (a service name spelled
# differently in one place is a credential neither surface can find).
KEYCHAIN_SERVICE="${SPAWN_KEYCHAIN_SERVICE:-spawn-gateway}"
KEYCHAIN_ACCOUNT_TOKEN="${SPAWN_KEYCHAIN_ACCOUNT_TOKEN:-gateway-token}"
SECURITY_BIN="${SPAWN_SECURITY_BIN:-/usr/bin/security}"

# Shared runtime state. These three paths are deliberately the same ones
# lib/spawnctl.sh uses, so the two control surfaces see one gateway and neither
# double-starts against the other.
STATE_HOME="${SPAWN_STATE_HOME:-$HOME}"
PIDFILE="${SPAWN_PIDFILE:-$STATE_HOME/.gateway.pid}"
LOGFILE="${SPAWN_LOG:-$STATE_HOME/.gateway.log}"
LOCKDIR="${SPAWN_LOCK:-$STATE_HOME/.gateway.lock}"

usage() {
    cat <<'USAGE'
gw — Superagent Gateway control

  gw start          start the gateway if it is not already serving
  gw stop           stop it
  gw restart        stop then start
  gw status         is it up? what does it serve?
  gw log            follow the gateway log
  gw claude [args]  launch Claude Code pointed at the gateway
USAGE
}

case "${1:-status}" in
  start|stop|restart|status)
    # Delegation, not reimplementation: locked start, probe-based liveness and
    # an append-only log all live in one place.
    exec bash "$SPAWNCTL" "$1"
    ;;
  log)
    if [ ! -f "$LOGFILE" ]; then
      printf 'no gateway log yet — start the gateway first\n'
      exit 0
    fi
    tail -f "$LOGFILE"
    ;;
  claude)
    shift
    # The base URL comes back from the control layer rather than being baked:
    # the port is the gateway's business, and a stale copy here is how a
    # wrapper starts pointing at nothing.
    ensured="$(bash "$SPAWNCTL" ensure)" || {
      printf 'gateway is not available (see: gw status)\n' >&2
      exit 3
    }
    base="$(printf '%s' "$ensured" | jq -r '.base_url // empty')"
    if [ -z "$base" ]; then
      printf 'the gateway did not report a base url\n' >&2
      exit 3
    fi
    # `|| true` because `security` exits 44 when there is no such item, and
    # under `set -e` that status would kill the wrapper before the named,
    # actionable refusal below ever ran.
    token="$("$SECURITY_BIN" find-generic-password -a "$KEYCHAIN_ACCOUNT_TOKEN" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
    if [ -z "$token" ]; then
      printf 'no gateway token is stored — run /spawn:setup\n' >&2
      exit 9
    fi
    ANTHROPIC_BASE_URL="$base" ANTHROPIC_AUTH_TOKEN="$token" exec claude "$@"
    ;;
  *)
    usage
    exit 2
    ;;
esac
EOF
}

# gw_stored_body <file> — the bytes the hash line covers: everything BELOW it.
gw_stored_body() {
    awk -v p="$GW_HASH_PREFIX" 'seen { print } index($0, p) == 1 { seen = 1 }' "$1"
}

# gw_classify <path> — KTD11's recognition matrix, answered in GW_STATE:
#   absent     no such file        → write freely
#   generated  marker, hash agrees → rewrite freely
#   modified   marker, hash differs→ hand-edited since setup wrote it: consent
#   foreign    no marker at all    → not ours: consent
# The live wrapper on this machine carries no marker, so the first real run
# lands on `foreign` exactly once and asks.
GW_STATE=""
gw_classify() {
    local path="$1" declared actual
    if [ ! -e "$path" ]; then
        GW_STATE="absent"
        return 0
    fi
    grep -qF -- "$GW_MARKER" "$path" 2>/dev/null || { GW_STATE="foreign"; return 0; }
    declared="$(awk -v p="$GW_HASH_PREFIX" 'index($0, p) == 1 { print substr($0, length(p) + 1); exit }' "$path")"
    [ -n "$declared" ] || { GW_STATE="modified"; return 0; }
    actual="$(gw_stored_body "$path" | gw_hash)"
    if [ "$declared" = "$actual" ]; then
        GW_STATE="generated"
    else
        GW_STATE="modified"
    fi
    return 0
}

# write_gw <path> — assemble, hash, and land the wrapper in one rename. The
# body is hashed BEFORE the header is prepended, and gw_stored_body reads back
# exactly those bytes, so generation and recognition cannot disagree.
write_gw() {
    local path="$1" dir tmp body
    dir="$(dirname "$path")"
    mkdir -p "$dir" || return 1
    body="$(gw_body)"
    [ -n "$body" ] || return 1
    tmp="$path.spawn-setup.$$"
    rm -f "$tmp" 2>/dev/null
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$GW_MARKER"
        printf '%s%s\n' "$GW_HASH_PREFIX" "$(printf '%s\n' "$body" | gw_hash)"
        printf '%s\n' "$body"
    } > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
    chmod 755 "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv "$tmp" "$path" || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# gw (R19, R20, R23; F1)
# ---------------------------------------------------------------------------
do_gw() {
    local consent="$1" before

    gw_classify "$GW_PATH"
    before="$GW_STATE"

    case "$before" in
        absent|generated) ;;
        *)
            if [ "$consent" -ne 1 ]; then
                # KTD17: refused, not prompted. Nothing is touched on this path
                # — the operator's file is still byte-for-byte theirs.
                say "'$GW_PATH' was not written by setup (state: $before) — refusing to overwrite it without consent"
                emit "$(jq -nc --arg p "$GW_PATH" --arg s "$before" --argjson c "$EX_CONSENT" \
                    '{ok:false, verb:"gw", error:("refusing to overwrite \($p): it was not written by setup (\($s)); re-run with --consent-overwrite-gw to replace it"),
                      consent_required:"overwrite-gw", path:$p, state_before:$s, exit_code:$c}')" \
                    || die "$EX_USAGE" "could not encode the gw consent object"
                exit "$EX_CONSENT"
            fi
            ;;
    esac

    write_gw "$GW_PATH" \
        || die "$EX_USAGE" "step 'gw': could not write '$GW_PATH'; it is untouched"

    say "wrote $GW_PATH — its control verbs now delegate to the plugin, and its token is read from the Keychain at run time"
    emit "$(jq -nc --arg p "$GW_PATH" --arg s "$before" --arg ctl "$SPAWNCTL_PATH" \
        '{ok:true, verb:"gw", action:(if $s == "absent" then "created" else "rewritten" end),
          path:$p, state_before:$s, spawnctl:$ctl, error:null, exit_code:0}')" \
        || die "$EX_USAGE" "could not encode the gw object"
    exit "$EX_OK"
}

# ===========================================================================
# HARNESS WIRING (U6; KTD12, KTD15, KTD17, KTD19, KTD20 — R8, R11, R12, R14,
# R15, R24, R25)
# ===========================================================================
#
# TWO HARNESSES, TWO COMPLETELY DIFFERENT SHAPES OF WIRING.
#
#   Codex has a config file setup writes: a marker-delimited managed block in
#   ~/.codex/config.toml declaring one provider and one profile per alias. The
#   credential appears in it BY NAME ONLY (`env_key = "GATEWAY_TOKEN"`, R12).
#
#   Claude Code has NO setup-written config file. What it needs is the token in
#   the environment, which is the KTD15 snippet plus one marker-guarded source
#   line in the operator's shell rc. The gateway URL is the plugin's own launch
#   path's business, deliberately NOT exported here: exporting ANTHROPIC_BASE_URL
#   into every shell would silently redirect every unrelated `claude` invocation
#   on this machine through the gateway.
#
# R11 IS FAIL-NOT-SKIP. `skipped` means "not installed on this machine" and
# nothing else. An installed harness that cannot be wired — a Codex config the
# loader will not accept, a validation that comes back invalid — FAILS setup,
# named, with the loader's own message. The tempting shape (mark it skipped and
# carry on green) is the exact wrong-success this reads as a defect.
#
# ORDER IS AN INVARIANT, NOT AN ACCIDENT: every refusal this verb can make —
# nothing installed, no aliases to emit, consent needed for the rc line, an
# existing Codex config that will not load, a corrupt managed block — runs
# BEFORE the first byte is written anywhere. Past that point the only failure
# left is a post-write validation, which restores the byte-exact backup first.
# ---------------------------------------------------------------------------

# Codex managed-block delimiters. Their exact text is part of the contract, the
# same way GW_MARKER's is: change them and every previously written block reads
# as absent, so a re-run appends a second one.
CODEX_BEGIN="# >>> spawn-setup: managed block — rewritten by /spawn:setup, edits inside it are not preserved"
CODEX_END="# <<< spawn-setup: end managed block"

# The shell-rc guard. Recognition is by MARKER rather than by matching the
# source line itself, so an operator who reformats the line still does not get a
# second copy appended on the next run.
RC_MARKER="# spawn-setup: gateway token for new shells (see the sourced file)"

# ---------------------------------------------------------------------------
# R15 — what a gateway-pointed session loses, CARRIED AS DATA.
#
# Sourced once, at authoring time, from the verified list in
# plugins/spawn/skills/launch/SKILL.md (verified live 2026-08-06) plus the Codex
# auto-compaction gap. It is COPIED rather than referenced on purpose: that
# SKILL.md never loads at runtime (KD9), so pointing setup's output at it would
# reproduce the exact gap that bit during the surface drive — a statement the
# operator is told exists, in a file nothing opens.
# ---------------------------------------------------------------------------
WIRE_LOSSES=(
"claude.ai MCP connectors do not load: the gateway auth token takes precedence over the claude.ai login, so the connectors that login would carry are not there."
"The advisor tool is disabled: gateway aliases carry no advisor rank in the model catalog."
"Claude Code warns that the model is unrecognized unless a context window is declared, and silently caps output at 32000 tokens unless an output window is declared. Both are declared per alias below; an alias missing from the table launches without either."
"An attached session runs the full agent loop under your normal permissions with a third-party model choosing the actions. That is the feature, not a bug, but the judgement in that session is a third-party model's judgement."
"Codex auto-compaction does not work through the gateway: Codex posts to /responses/compact, which the gateway does not serve, so that request 404s mid-session."
)

# KTD20's stated gaps. R25 asks for the check AND for what the check cannot
# cover; a validation that reported only its own success would be the more
# comfortable and less honest half.
WIRE_CODEX_GAPS=(
"Codex's strict_config defaults to false, so a MISSPELLED key name inside the emitted block is silently ignored by every check available: config.load catches syntax and type errors, not typos."
"Codex is not installed on the machine this path was built on, so the Codex branch ships fixture-proven with no live confirmation."
)

# harness_installed <bin> — KTD12. A seam pointing at a path must be an
# executable file; a bare name is looked up on PATH. Same two-armed shape
# need_prereqs uses, for the same reason: a test pointing a seam at a deleted
# fixture and a machine without the harness are the same answer.
harness_installed() {
    case "$1" in
        */*) [ -f "$1" ] && [ -x "$1" ] ;;
        *)   command -v "$1" >/dev/null 2>&1 ;;
    esac
}

# ---------------------------------------------------------------------------
# config_aliases <gateway.yaml> — the alias NAMES in the config's models block.
#
# Deliberately NOT a fourth copy of spawnctl.sh's yaml_scan: that one exists to
# read server.token and the model strings behind each alias, and this needs
# neither. It reads key names and nothing else, so there is no value here to
# leak, mis-expand or mis-quote.
# ---------------------------------------------------------------------------
config_aliases() {
    [ -f "$1" ] || return 1
    awk '
        /^[A-Za-z_][A-Za-z0-9_-]*:/ { sec = $0; sub(/:.*$/, "", sec); next }
        sec == "models" && /^  [A-Za-z0-9._-]+:[ \t]*(#.*)?$/ {
            a = $0; sub(/[ \t]*#.*$/, "", a); sub(/:[ \t]*$/, "", a)
            gsub(/^[ \t]+|[ \t]+$/, "", a)
            if (a != "") print a
        }
    ' "$1"
}

# wire_config_path — which gateway.yaml the alias list comes from. The explicit
# override wins; otherwise the newest install's, which is the same file
# previous_config resolves for the migration path.
wire_config_path() {
    if [ -n "$WIRE_CONFIG" ]; then
        [ -f "$WIRE_CONFIG" ] || return 1
        printf '%s' "$WIRE_CONFIG"
        return 0
    fi
    previous_config
}

# ---------------------------------------------------------------------------
# resolve_wire_models — R14 + step 6: the INTERSECTION of the gateway's
# configured aliases and the plugin's window table, as a JSON array of
# {alias, context_window, output_window}.
#
# Intersection rather than either side alone, and both directions matter: an
# alias in the table that the gateway does not serve would emit a Codex profile
# pointing at a model that 404s, and an alias the gateway serves with no table
# entry would emit windows this plugin cannot source (R14 says sourced from
# models.json, not hand-entered).
#
# Through a global for the same reason resolve_latest_tag uses one: this
# function's callers die, and a die inside a command substitution writes its
# JSON object into a variable instead of to the consumer.
# ---------------------------------------------------------------------------
WIRE_MODELS_JSON=""
resolve_wire_models() {
    local cfg names
    cfg="$(wire_config_path)" || die "$EX_USAGE" "step 'wire': no gateway config to read alias names from (looked for \$SPAWN_CONFIG, then $SEARCH_ROOT/gateway-*/$CONFIG_NAME) — run the acquire step first; nothing has been written."
    [ -f "$MODELS_JSON" ] || die "$EX_USAGE" "step 'wire': the alias window table '$MODELS_JSON' is missing, so no context or output window can be declared (R14); nothing has been written."

    names="$(config_aliases "$cfg")"
    [ -n "$names" ] || die "$EX_USAGE" "step 'wire': '$cfg' declares no model aliases, so there is nothing to wire either harness to; nothing has been written."

    # The shape guard is common.sh's spawn_aliases — the same predicate
    # spawnctl.sh's table_json uses, shared rather than copied so the two
    # readers of this file cannot drift apart.
    WIRE_MODELS_JSON="$(printf '%s\n' "$names" | jq -Rsc --slurpfile t "$MODELS_JSON" \
        "$SPAWN_SANITIZE_JQ_DEF$SPAWN_MODELS_ALIASES_JQ_DEF"'
        (($t[0] // {}) | spawn_aliases) as $tbl
        | strip_display_controls
        | split("\n")
        | map(select(length > 0))
        | unique
        | map(select(. as $a | $tbl | has($a)))
        | map({alias: .,
               context_window: ($tbl[.].context_window // null),
               output_window:  ($tbl[.].output_window  // null)})
        | map(select(.context_window != null and .output_window != null))
        | strip_display_deep' 2>/dev/null)"
    case "$WIRE_MODELS_JSON" in
        "" | null) WIRE_MODELS_JSON="[]" ;;
    esac
    # An empty intersection is a REFUSAL, not an empty success: a provider block
    # serving zero models is a config that looks wired and answers nothing.
    [ "$(printf '%s' "$WIRE_MODELS_JSON" | jq -r 'length')" -gt 0 ] \
        || die "$EX_USAGE" "step 'wire': none of the aliases in '$cfg' has an entry with both windows in '$MODELS_JSON', so every emitted model entry would be missing the windows R14 requires; nothing has been written."
    return 0
}

# ---------------------------------------------------------------------------
# codex_block — the managed block's bytes.
#
# THE THREE PROVIDER FIELDS ARE EACH A VERIFIED DECISION, NOT A GUESS:
#   base_url ends in /v1  — Codex joins base_url with the endpoint VERBATIM, so
#                           <root>/v1 yields POST /v1/responses, which is the
#                           route the gateway serves. A base_url without it
#                           posts to /responses, which does not exist.
#   env_key               — the credential BY NAME (R12). No value is written.
#   wire_api = responses  — `chat` was removed upstream and no longer
#                           deserializes; `responses` is also the default, so
#                           this is stating the contract rather than changing it.
#
# Profile keys are QUOTED: alias names may carry a dot, and a bare TOML key with
# a dot in it is a dotted path — [profiles.gpt.sol] is two nested tables, not
# one profile named gpt.sol.
# ---------------------------------------------------------------------------
codex_block() {
    printf '%s\n' "$CODEX_BEGIN"
    cat <<EOF
# Written by /spawn:setup. Everything OUTSIDE these two markers is yours and is
# never read, rewritten or reordered by setup.
#
# No credential is stored here: env_key names an environment variable, and
# ~/.gateway/env.sh reads that variable's value out of the Keychain when a shell
# starts, so rotating the token reaches this file with no rewrite.
[model_providers.$CODEX_PROVIDER_ID]
name = "Superagent Gateway (spawn)"
base_url = "$GATEWAY_ROOT_URL/v1"
env_key = "GATEWAY_TOKEN"
wire_api = "responses"
EOF
    # One profile per alias in the intersection, carrying both windows (R14).
    printf '%s' "$WIRE_MODELS_JSON" | jq -r --arg p "$CODEX_PROVIDER_ID" '
        .[] | "\n[profiles.\"\(.alias)\"]\nmodel = \"\(.alias)\"\nmodel_provider = \"\($p)\"\nmodel_context_window = \(.context_window)\nmodel_max_output_tokens = \(.output_window)"'
    printf '%s\n' "$CODEX_END"
}

# codex_block_state <file> — absent | present | corrupt.
#   corrupt = a begin marker with no end marker (an operator truncated the file
#   mid-block). Stripping to EOF would delete whatever they wrote after it and
#   appending would leave two blocks, so this refuses instead.
CODEX_BLOCK_STATE=""
codex_block_state() {
    local f="$1" b e
    if [ ! -f "$f" ]; then CODEX_BLOCK_STATE="absent"; return 0; fi
    b="$(grep -cF -- "$CODEX_BEGIN" "$f" 2>/dev/null || true)"
    e="$(grep -cF -- "$CODEX_END" "$f" 2>/dev/null || true)"
    if [ "${b:-0}" -eq 0 ] && [ "${e:-0}" -eq 0 ]; then
        CODEX_BLOCK_STATE="absent"
    elif [ "${b:-0}" -eq 1 ] && [ "${e:-0}" -eq 1 ]; then
        CODEX_BLOCK_STATE="present"
    else
        CODEX_BLOCK_STATE="corrupt"
    fi
    return 0
}

# write_codex_block <file> — replace the managed block IN PLACE, or append it.
#
# In place, not append-always: an operator's own content after the block would
# otherwise see the block migrate to the end of the file on every run, which is
# both a diff they did not ask for and a second thing to explain. Replacement
# keeps a re-run byte-identical.
write_codex_block() {
    local f="$1" dir tmp blk
    dir="$(dirname "$f")"
    mkdir -p "$dir" || return 1
    blk="$f.spawn-block.$$"
    tmp="$f.spawn-setup.$$"
    rm -f "$blk" "$tmp" 2>/dev/null
    codex_block > "$blk" || { rm -f "$blk" 2>/dev/null; return 1; }
    [ -s "$blk" ] || { rm -f "$blk" 2>/dev/null; return 1; }

    if [ -f "$f" ]; then
        awk -v b="$CODEX_BEGIN" -v e="$CODEX_END" -v blk="$blk" '
            index($0, b) == 1 { skip = 1; while ((getline l < blk) > 0) print l; close(blk); seen = 1; next }
            skip == 1 { if (index($0, e) == 1) skip = 0; next }
            { print }
            END { if (!seen) { while ((getline l < blk) > 0) print l; close(blk) } }
        ' "$f" > "$tmp" || { rm -f "$blk" "$tmp" 2>/dev/null; return 1; }
    else
        cat "$blk" > "$tmp" || { rm -f "$blk" "$tmp" 2>/dev/null; return 1; }
    fi
    rm -f "$blk" 2>/dev/null
    chmod 600 "$tmp" 2>/dev/null
    mv "$tmp" "$f" || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# codex_config_load_status — KTD20's validation, and the one place in this file
# where a non-zero process exit is DELIBERATELY IGNORED.
#
# `codex doctor --json` runs several checks and its exit status folds all of
# them together — including network reachability, which fails on an offline
# machine or a gateway that is simply not started yet. Branching on `$?` would
# therefore report a perfectly loadable config as broken, and would do it in
# exactly the situation setup runs in. The status of the `config.load` check
# INSIDE the JSON is the only signal that answers the question asked.
#
# It fails CLOSED in both directions: unparseable output, or output with no
# config.load check in it, is a validation FAILURE naming that — never a pass.
# "The check was not there" reading as "the check passed" is the same class of
# wrong-success as marking an unwireable harness skipped.
#
# Answers through two globals: the status word and the loader's own detail
# string, which R11/AE10 require be reported rather than paraphrased.
# ---------------------------------------------------------------------------
CODEX_LOAD_STATUS=""
CODEX_LOAD_DETAIL=""
codex_config_load_status() {
    local out rc found
    CODEX_LOAD_STATUS=""
    CODEX_LOAD_DETAIL=""
    out="$(mktemp "${TMPDIR:-/tmp}/spawn-codex-doctor.XXXXXX")" || return 1
    run_bounded_out "$DOCTOR_BUDGET" "$out" "$SPAWN_CODEX_BIN" doctor --json
    rc=$?
    if [ "$rc" -eq 124 ]; then
        CODEX_LOAD_STATUS="unreadable"
        CODEX_LOAD_DETAIL="codex doctor --json did not finish within ${DOCTOR_BUDGET}s"
        rm -f "$out" 2>/dev/null
        return 0
    fi
    # rc is READ but never branched on for validity — see the header. It is not
    # even carried into the result, because a consumer given it would branch on
    # it, which is the whole defect this decision exists to avoid.
    found="$(jq -r '[.checks[]? | select(.name == "config.load")] | first
                    | if . == null then empty else "\(.status // "")\t\(.detail // "")" end' \
             "$out" 2>/dev/null)"
    rm -f "$out" 2>/dev/null
    if [ -z "$found" ]; then
        CODEX_LOAD_STATUS="unreadable"
        CODEX_LOAD_DETAIL="codex doctor --json produced no readable config.load check"
        return 0
    fi
    CODEX_LOAD_STATUS="${found%%$'\t'*}"
    CODEX_LOAD_DETAIL="${found#*$'\t'}"
    case "$CODEX_LOAD_STATUS" in
        ok|pass|passed|success) CODEX_LOAD_STATUS="ok" ;;
        "") CODEX_LOAD_STATUS="unreadable"; CODEX_LOAD_DETAIL="codex doctor --json reported a config.load check with no status" ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# The KTD15 snippet. The first heredoc is EXPANDED — it bakes the Keychain
# coordinates and the security path resolved right now — and every one of those
# is still an override-able default at RUN time, so the file the operator ends
# up sourcing behaves the same way the plugin's own scripts do.
#
# What is NOT in here: ANTHROPIC_BASE_URL. Exporting it would point every
# `claude` on this machine at the gateway, which is the plugin's launch path's
# decision to make per session, not a global one setup gets to take.
# ---------------------------------------------------------------------------
ENV_MARKER="# spawn-setup: generated — rewritten by /spawn:setup, edits are not preserved"
env_snippet() {
    printf '%s\n' "$ENV_MARKER"
    cat <<EOF
# Sourced by your shell rc. It holds a Keychain READ, never a token value, so
# rotating the credential reaches every new shell with no rewrite here.
#
# Underscore-prefixed and unset again at the end: this is sourced into the
# operator's own interactive shell, so it leaves exactly one name behind.
# The coordinates are baked from what setup resolved, and each stays
# overridable at run time so this file behaves the way the plugin's own
# scripts do.
__spawn_security="\${SPAWN_SECURITY_BIN:-$SPAWN_SECURITY_BIN}"
__spawn_service="\${SPAWN_KEYCHAIN_SERVICE:-$KEYCHAIN_SERVICE}"
__spawn_account="\${SPAWN_KEYCHAIN_ACCOUNT_TOKEN:-$KEYCHAIN_ACCOUNT_TOKEN}"
EOF
    cat <<'EOF'

# `|| true`: `security` exits 44 when there is no such item, and a shell rc
# sourced under `set -e` would otherwise die at login over a missing credential.
GATEWAY_TOKEN="$("$__spawn_security" find-generic-password \
    -a "$__spawn_account" -s "$__spawn_service" -w 2>/dev/null || true)"
if [ -n "$GATEWAY_TOKEN" ]; then
    export GATEWAY_TOKEN
else
    # Nothing stored: leave the variable UNSET rather than exported-and-empty.
    # An empty export looks like a credential to everything downstream and
    # fails as an authentication error instead of as a missing setup step.
    unset GATEWAY_TOKEN
fi
unset __spawn_security __spawn_service __spawn_account
EOF
}

write_env_snippet() {
    local f="$1" dir tmp
    dir="$(dirname "$f")"
    ( umask 077; mkdir -p "$dir" ) || return 1
    tmp="$f.spawn-setup.$$"
    rm -f "$tmp" 2>/dev/null
    env_snippet > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
    [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
    chmod 600 "$tmp" 2>/dev/null
    mv "$tmp" "$f" || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

rc_has_line() {
    [ -f "$1" ] || return 1
    grep -qF -- "$RC_MARKER" "$1" 2>/dev/null
}

# append_rc_line <rc> — two lines, appended once. APPEND, never rewrite: this is
# the operator's shell rc and setup owns exactly the lines it adds.
append_rc_line() {
    local rc="$1" dir
    dir="$(dirname "$rc")"
    mkdir -p "$dir" || return 1
    {
        printf '\n%s\n' "$RC_MARKER"
        printf '[ -f "%s" ] && . "%s"\n' "$GATEWAY_ENV_FILE" "$GATEWAY_ENV_FILE"
    } >> "$rc" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# wire (R8, R11, R12, R14, R15, R24, R25; F1)
# ---------------------------------------------------------------------------
do_wire() {
    local consent="$1"
    local claude_here=0 codex_here=0
    local codex_backup="" codex_action="" rc_action="" restored=""

    harness_installed "$SPAWN_CLAUDE_BIN" && claude_here=1
    harness_installed "$SPAWN_CODEX_BIN" && codex_here=1

    # Nothing installed is a refusal, not an empty success. Setup's whole claim
    # is that a harness works afterwards; reporting ok:true having wired none of
    # them is a green run that changed nothing anyone can use.
    if [ "$claude_here" -eq 0 ] && [ "$codex_here" -eq 0 ]; then
        die "$EX_USAGE" "step 'wire': no supported harness is installed (looked for '$SPAWN_CLAUDE_BIN' and '$SPAWN_CODEX_BIN' on PATH) — install Claude Code or Codex, then re-run; nothing has been written."
    fi

    resolve_wire_models

    # --- refusals, all of them, before the first byte is written -------------

    # KTD17: the rc line is an edit to a file setup does not own.
    if [ "$claude_here" -eq 1 ] && ! rc_has_line "$SHELL_RC" && [ "$consent" -ne 1 ]; then
        say "wiring Claude Code means adding one source line to '$SHELL_RC' — refusing to edit it without consent"
        emit "$(jq -nc --arg rc "$SHELL_RC" --arg env "$GATEWAY_ENV_FILE" --argjson c "$EX_CONSENT" \
            '{ok:false, verb:"wire",
              error:("refusing to append the gateway token source line to \($rc): setup does not own your shell rc; re-run with --consent-shell-rc to add it"),
              consent_required:"shell-rc", shell_rc:$rc, env_file:$env, exit_code:$c}')" \
            || die "$EX_USAGE" "could not encode the wire consent object"
        exit "$EX_CONSENT"
    fi

    if [ "$codex_here" -eq 1 ]; then
        codex_block_state "$CODEX_CONFIG"
        [ "$CODEX_BLOCK_STATE" = "corrupt" ] \
            && die "$EX_USAGE" "step 'wire': the managed block in '$CODEX_CONFIG' is incomplete (one marker without its pair) — setup cannot tell where it ends, so it will not guess; repair or delete the block and re-run. The file is untouched."

        # AE10. An EXISTING config that the loader will not accept fails the run
        # here, before anything is written: setup cannot rewrite a file whose
        # contents it cannot interpret without discarding something unknown.
        if [ -f "$CODEX_CONFIG" ]; then
            codex_config_load_status
            if [ "$CODEX_LOAD_STATUS" != "ok" ]; then
                die "$EX_USAGE" "step 'wire': Codex is installed but its existing config '$CODEX_CONFIG' does not load, so it cannot be wired (R11 — this is a failure, not a skip). The loader reported: $CODEX_LOAD_DETAIL. The file is untouched."
            fi
        fi
    fi

    # --- writes -------------------------------------------------------------

    if [ "$claude_here" -eq 1 ]; then
        write_env_snippet "$GATEWAY_ENV_FILE" \
            || die "$EX_USAGE" "step 'wire': could not write the shell snippet '$GATEWAY_ENV_FILE'; nothing else has been changed."
        if rc_has_line "$SHELL_RC"; then
            rc_action="already-present"
        else
            append_rc_line "$SHELL_RC" \
                || die "$EX_USAGE" "step 'wire': could not append the source line to '$SHELL_RC'; the snippet at '$GATEWAY_ENV_FILE' was written."
            rc_action="appended"
        fi
    fi

    if [ "$codex_here" -eq 1 ]; then
        # The byte-exact backup exists for one purpose: a post-write validation
        # failure must leave the operator's file as it was found, and "rewrite it
        # from the block we removed" is a reconstruction, not a restore.
        if [ -f "$CODEX_CONFIG" ]; then
            codex_backup="$CODEX_CONFIG.spawn-backup.$$"
            rm -f "$codex_backup" 2>/dev/null
            cat "$CODEX_CONFIG" > "$codex_backup" \
                || die "$EX_USAGE" "step 'wire': could not back up '$CODEX_CONFIG' before editing it; it is untouched."
        fi
        write_codex_block "$CODEX_CONFIG" || {
            [ -n "$codex_backup" ] && cat "$codex_backup" > "$CODEX_CONFIG" 2>/dev/null
            rm -f "$codex_backup" 2>/dev/null
            die "$EX_USAGE" "step 'wire': could not write the managed block into '$CODEX_CONFIG'; it is as it was."
        }
        codex_action="$([ "$CODEX_BLOCK_STATE" = "present" ] && printf 'updated' || printf 'created')"

        # KTD20, second call: the block setup just wrote is validated by the
        # harness that owns it before setup reports success.
        codex_config_load_status
        if [ "$CODEX_LOAD_STATUS" != "ok" ]; then
            if [ -n "$codex_backup" ]; then
                cat "$codex_backup" > "$CODEX_CONFIG" 2>/dev/null
                restored=" The file has been restored to what it was."
            else
                rm -f "$CODEX_CONFIG" 2>/dev/null
                restored=" The file setup created has been removed."
            fi
            rm -f "$codex_backup" 2>/dev/null
            die "$EX_USAGE" "step 'wire': Codex rejected the config setup wrote to '$CODEX_CONFIG', so it is not wired (R11 — this is a failure, not a skip). The loader reported: $CODEX_LOAD_DETAIL.$restored"
        fi
        rm -f "$codex_backup" 2>/dev/null
    fi

    # --- report -------------------------------------------------------------

    # R24. The invoking shell cannot be reached by exporting into it — a process
    # cannot modify its parent's environment — so it is reached by printing ONE
    # line the operator runs, and by saying plainly that no later shell needs it.
    local activation=". \"$GATEWAY_ENV_FILE\""

    if [ "$claude_here" -eq 1 ]; then
        say "wrote $GATEWAY_ENV_FILE (a Keychain read, no token value) and the source line in $SHELL_RC ($rc_action)"
    fi
    if [ "$codex_here" -eq 1 ]; then
        say "$codex_action the spawn-setup managed block in $CODEX_CONFIG — the credential is referenced by name (GATEWAY_TOKEN), never stored there"
    fi
    say "shells you open from now on need nothing. For THIS shell, run: $activation"

    # The two prose lists travel as JSON arrays built by jq itself rather than
    # as positional arguments sliced by index: an index slice is a silent
    # mis-report the day either list grows an entry.
    local losses_json gaps_json
    losses_json="$(printf '%s\n' "${WIRE_LOSSES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    gaps_json="$(printf '%s\n' "${WIRE_CODEX_GAPS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"

    emit "$(jq -nc \
        --argjson models "$WIRE_MODELS_JSON" \
        --argjson losses "$losses_json" --argjson gaps "$gaps_json" \
        --arg env "$GATEWAY_ENV_FILE" --arg rc "$SHELL_RC" --arg rca "${rc_action:-}" \
        --arg cfg "$CODEX_CONFIG" --arg ca "${codex_action:-}" \
        --arg base "$GATEWAY_ROOT_URL/v1" --arg act "$activation" \
        --argjson ch "$claude_here" --argjson kh "$codex_here" \
        --arg detail "$CODEX_LOAD_DETAIL" \
        '
        {ok:true, verb:"wire",
         wired: ([ (if $ch == 1 then
                      {harness:"claude-code", mechanism:"shell token",
                       env_file:$env, shell_rc:$rc, rc_line:$rca,
                       validated_by:null,
                       validation_note:"Claude Code has no setup-written config file to validate; its wiring is the shell token plus the plugin launch path, so the live round-trip is its whole proof."}
                    else empty end),
                   (if $kh == 1 then
                      {harness:"codex", mechanism:"managed block",
                       config:$cfg, action:$ca, base_url:$base,
                       credential_reference:"GATEWAY_TOKEN", wire_api:"responses",
                       validated_by:"codex doctor --json (config.load check; the process exit is deliberately ignored — it folds in network reachability)",
                       validation_detail:$detail}
                    else empty end) ]),
         skipped: ([ (if $ch == 0 then {harness:"claude-code", reason:"not installed"} else empty end),
                     (if $kh == 0 then {harness:"codex", reason:"not installed"} else empty end) ]),
         models: $models,
         losses: $losses,
         validation_gaps: $gaps,
         activation: {shell_command:$act,
                      this_shell:"a process cannot change its parent shell environment, so run the line above in THIS shell",
                      later_shells:"shells opened after this run need nothing — the rc line sources the snippet at startup"},
         error:null, exit_code:0}')" \
        || die "$EX_USAGE" "could not encode the wire object"
    exit "$EX_OK"
}

# ===========================================================================
# THE ROUND-TRIP PROOF (U7; KTD13 — R16, R17)
# ===========================================================================
#
# WHY TWO LAYERS, AND WHY NEITHER ALONE (KTD13). Layer two is KTD20's config
# validation, run inside `wire` by the harness's own loader — it proves the file
# setup wrote is one the harness accepts, and it proves nothing about whether a
# gateway is up. Layer one is this: a real request over the wire, in each wired
# harness's own shape, to the gateway that is actually running — which proves
# the gateway serves and the credential is valid, and proves nothing about
# whether the config was written where the harness will look for it. Reporting
# either as "verified" is a claim the evidence does not support, so both run and
# both are named separately in the output.
#
# WHY A REJECT PROBE IS PART OF IT (R9). A config with no token entry and a
# gateway with an empty auth list is not a gateway that refuses callers — it is
# an OPEN PROXY on 127.0.0.1 forwarding to a paid provider, because the auth
# check returns success immediately on an empty list. Every other probe here
# PRESENTS a credential, so every one of them passes against that gateway. Only
# a request that presents nothing can tell the two apart, and it runs against
# the live process rather than against the config, which is the half a config
# reading cannot cover.
#
# THE ALIAS IS CHOSEN FROM THE SERVED LIST AT RUNTIME. A bare-machine install
# from the upstream template does not serve this machine's aliases, so a
# hardcoded one would 404 on exactly the first-run path this whole unit exists
# for. spawnctl's start object already carries the served list; it is used.
#
# CREDENTIAL DELIVERY IS A MODE-0600 curl --config FILE, never `-H` in argv, for
# the reason spawnctl.sh's probe spells out: argv is readable from the process
# table by anything on this box.
# ---------------------------------------------------------------------------
RT_CODE=""
round_trip() {   # round_trip <url> <body-file> <token|"">  → RT_CODE
    local url="$1" body="$2" tok="$3" work curlrc code rc
    RT_CODE=""
    work="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/spawn-rt.XXXXXX")" || return 1
    curlrc="$work/rt.curlrc"
    {
        printf 'url = "%s"\n' "$(esc "$url")"
        printf 'header = "content-type: application/json"\n'
        # An EMPTY token is the reject probe: no auth header at all, which is
        # the only request that can tell a guarded gateway from an open one.
        if [ -n "$tok" ]; then
            printf 'header = "authorization: Bearer %s"\n' "$(esc "$tok")"
        fi
    } > "$curlrc"
    chmod 600 "$curlrc" 2>/dev/null
    # The BODY is not secret (a model alias and a one-word prompt), so it may
    # travel as a file argument; the credential may not, and does not.
    # PLAIN `curl`, not SPAWN_CURL_BIN, and the difference matters: that seam
    # stands in for the GITHUB API during acquire, and a fixture that answers
    # release lookups cannot answer a live gateway. This is the one call in the
    # whole path that must reach a real socket — KTD8 says the live round-trip
    # is the thing no fake covers — so it uses the same real binary
    # spawnctl.sh's probe uses.
    code="$(curl -s -o "$work/body" -w '%{http_code}' -X POST \
        --connect-timeout "${SPAWN_CONNECT_TIMEOUT:-5}" --max-time "${SPAWN_SETUP_RT_TIMEOUT:-60}" \
        --config "$curlrc" --data-binary "@$body" 2>/dev/null)"
    rc=$?
    # The response BODY is deliberately dropped rather than reported: a 401 body
    # can quote the credential that was presented (AE7), and relaying it is how
    # a key reaches a transcript through the error path. The status and the
    # route answer the question; the body cannot be trusted to.
    rm -rf "$work" 2>/dev/null
    [ "$rc" -eq 0 ] || return 1
    RT_CODE="$code"
    [ -n "$RT_CODE" ] && [ "$RT_CODE" != "000" ] || return 1
    return 0
}

# rt_body <file> <shape> <alias> — the request body for one harness's wire
# shape. Bounded to a minimal output budget: this is a proof of life, and a
# verification step that bought a full completion on every setup run would be
# charging the operator for a handshake.
rt_body() {
    local file="$1" shape="$2" alias="$3"
    case "$shape" in
        anthropic)
            jq -nc --arg m "$alias" \
                '{model:$m, max_tokens:1, messages:[{role:"user", content:"ping"}]}' > "$file"
            ;;
        responses)
            jq -nc --arg m "$alias" \
                '{model:$m, input:"ping", max_output_tokens:16}' > "$file"
            ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# verify <base-url> <alias> — both layers, each attributable in the output.
#
# Fails through die(), so every failure here carries the full R18 state report:
# by this point the install, both credentials, the wrapper and the harness
# configs are all already recorded, which is exactly what the operator needs to
# know they do not have to redo (AE5).
# ---------------------------------------------------------------------------
VERIFY_RT_JSON="[]"
verify_round_trips() {
    local root="$1" alias="$2" tok="$3" work body harness shape route url
    VERIFY_RT_JSON="[]"
    work="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/spawn-rtb.XXXXXX")" \
        || die "$EX_UNREACHABLE" "step 'verify': could not create a working directory for the round-trip"
    body="$work/body.json"

    # One request per WIRED harness, in that harness's own wire shape. Driven
    # off the wire step's own report rather than off a list spelled twice: a
    # harness that was wired and not verified is the wrong-success this exists
    # to prevent, and two lists is how that happens.
    while IFS= read -r harness; do
        [ -n "$harness" ] || continue
        case "$harness" in
            claude-code) shape="anthropic"; route="/anthropic/v1/messages" ;;
            codex)       shape="responses"; route="/v1/responses" ;;
            *)  rm -rf "$work" 2>/dev/null
                die "$EX_USAGE" "step 'verify': the wire step reported a harness this verification does not know how to exercise ('$harness') — refusing to report success for a harness whose round-trip never ran" ;;
        esac
        rt_body "$body" "$shape" "$alias" \
            || { rm -rf "$work" 2>/dev/null; die "$EX_USAGE" "step 'verify': could not build the $harness request body"; }
        url="$root$route"
        if ! round_trip "$url" "$body" "$tok"; then
            rm -rf "$work" 2>/dev/null
            SETUP_FAILURE_CLASS="unreachable"
            die "$EX_UNREACHABLE" "step 'verify': no HTTP response from $url — the gateway is not answering the $harness round-trip, so setup will not report success. The install and both stored credentials are unchanged and listed under 'changed'."
        fi
        case "$RT_CODE" in
            200|201)
                VERIFY_RT_JSON="$(printf '%s' "$VERIFY_RT_JSON" | jq -c \
                    --arg h "$harness" --arg r "$route" --arg a "$alias" --argjson s "$RT_CODE" \
                    '. + [{harness:$h, route:$r, alias:$a, http_status:$s, ok:true}]')"
                say "round-trip ok: $harness → POST $route (alias $alias)"
                ;;
            401|403)
                rm -rf "$work" 2>/dev/null
                SETUP_FAILURE_CLASS="auth"
                # No response body, ever. See round_trip's note (AE7).
                die "$EX_UNREACHABLE" "step 'verify': the gateway REJECTED the stored credential on the $harness round-trip (POST $route returned HTTP $RT_CODE). Writing the config files is not evidence that the credential works, which is why this check exists — re-run with --rotate-openrouter-key if the key is wrong. Nothing was rolled back; see 'changed'."
                ;;
            *)
                rm -rf "$work" 2>/dev/null
                SETUP_FAILURE_CLASS="round-trip"
                die "$EX_UNREACHABLE" "step 'verify': the $harness round-trip (POST $route, alias '$alias') came back HTTP $RT_CODE, not 200 — the gateway is serving but this wire shape does not work, so setup will not report success. The release just installed is named under 'release'."
                ;;
        esac
    done <<EOF
$(printf '%s' "$SETUP_WIRED_JSON" | jq -r '.[].harness')
EOF

    # ---- the unauthenticated reject probe (R9) -----------------------------
    # UNCONDITIONAL, and against a route the gateway serves regardless of which
    # harness is wired: routes are the gateway's, wiring is the client's.
    rt_body "$body" "anthropic" "$alias" \
        || { rm -rf "$work" 2>/dev/null; die "$EX_USAGE" "step 'verify': could not build the unauthenticated probe body"; }
    if ! round_trip "$root/anthropic/v1/messages" "$body" ""; then
        rm -rf "$work" 2>/dev/null
        SETUP_FAILURE_CLASS="unreachable"
        die "$EX_UNREACHABLE" "step 'verify': no HTTP response to the unauthenticated probe at $root/anthropic/v1/messages, so setup cannot show that the gateway refuses unauthenticated callers (R9)."
    fi
    rm -rf "$work" 2>/dev/null
    case "$RT_CODE" in
        401|403) ;;
        2*)
            SETUP_FAILURE_CLASS="open-proxy"
            die "$EX_USAGE" "step 'verify': the gateway SERVED a request that presented no credential at all (POST /anthropic/v1/messages returned HTTP $RT_CODE) — that is an open proxy on this machine forwarding to a paid provider, which R9 forbids. Setup will not report success. Stop the gateway, make sure its $CONFIG_NAME declares no empty token list, and re-run."
            ;;
        *)
            SETUP_FAILURE_CLASS="reject-probe"
            die "$EX_UNREACHABLE" "step 'verify': the unauthenticated probe came back HTTP $RT_CODE, which is neither a rejection (401/403) nor a serve — setup cannot show that the gateway refuses unauthenticated callers (R9), so it does not claim to."
            ;;
    esac
    VERIFY_UNAUTH_JSON="$(jq -nc --argjson s "$RT_CODE" \
        '{route:"/anthropic/v1/messages", presented:"nothing", http_status:$s, rejected:true}')"
    say "unauthenticated probe rejected with HTTP $RT_CODE — the gateway is not an open proxy"
    return 0
}
VERIFY_UNAUTH_JSON="null"

# ===========================================================================
# ORCHESTRATION (U7; KTD5, KTD13, KTD17 — R5, R6, R16, R17, R18, R21, R22, R25)
# ===========================================================================
#
# THE SUB-STEPS ARE RUN AS CHILD PROCESSES, not as function calls, and that is
# deliberate: `acquire`, `gw` and `wire` each end in `exit`, each owns a
# one-JSON-object contract, and each is already covered by its own suite. Calling
# them in-process would mean rewriting all three to return instead of exit —
# three more edits to already-proven code — and the child's JSON is exactly the
# report this step needs anyway. The script re-invokes ITSELF by path, so a
# mutated copy of this file drives its own mutated verbs.
# ---------------------------------------------------------------------------
SUB_JSON=""
SUB_RC=0
run_sub() {   # run_sub <verb> [args...]
    local out
    out="$(mktemp "${TMPDIR:-/tmp}/spawn-sub.XXXXXX")" || return 1
    SUB_RC=0
    # stdout is captured (it is the child's one JSON object); stderr is left
    # alone so the child's progress lines reach the operator as they happen.
    bash "$SCRIPT_DIR/setup.sh" "$@" >"$out" || SUB_RC=$?
    SUB_JSON="$(cat "$out")"
    rm -f "$out" 2>/dev/null
    return 0
}

# pass_consent <verb> — KTD17. A child that needs the operator's say-so exits 8
# with the flag name in its object. That is passed straight through, WITH the
# steps and changes made so far: a consent refusal in the middle of a run is
# itself a state report the operator needs (they are about to re-run).
pass_consent() {
    local verb="$1" required
    required="$(printf '%s' "$SUB_JSON" | jq -r '.consent_required // empty' 2>/dev/null)"
    [ -n "$required" ] || required="unknown"
    step_done "$verb" "needs-consent" "$(printf '%s' "$SUB_JSON" | jq -r '.error // "consent required"' 2>/dev/null)"
    emit "$(jq -nc --arg r "$required" --arg v "$verb" \
        --argjson steps "$STEPS_JSON" --argjson changed "$CHANGED_JSON" \
        --argjson child "${SUB_JSON:-null}" --argjson c "$EX_CONSENT" \
        '{ok:false, verb:"setup", failed_step:$v, failure_class:"consent",
          consent_required:$r, steps:$steps, changed:$changed,
          error:($child.error // "operator confirmation required"),
          detail:$child, exit_code:$c}')" \
        || die "$EX_USAGE" "could not encode the setup consent object"
    exit "$EX_CONSENT"
}

# ---------------------------------------------------------------------------
# The two credential steps (KTD5; R5, R6, R21, R22).
#
# A plain re-run REUSES both stored secrets and prompts for nothing — that is
# what makes re-running safe rather than a second interrogation. Rotation is the
# only path that touches a stored value, and each secret rotates differently
# because the two have different blast radii: replacing the OpenRouter key
# affects this machine's gateway process, while replacing the gateway token
# breaks authentication in every shell that is already open.
#
# NO VALUE IS EVER PRINTED, PASSED IN ARGV, OR PUT IN THE JSON. The dialog
# returns on stdout into a local, the local goes to the Keychain writer on
# stdin, and the local is cleared. The only thing that reaches the output is the
# fact that an item was written.
# ---------------------------------------------------------------------------
do_key_step() {
    local rotate="$1" key rc
    step_start "openrouter-key"
    if [ "$rotate" -ne 1 ] && spawn::keychain_exists "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_OPENROUTER"; then
        # R21. No dialog, no prompt, nothing changed.
        say "reusing the stored OpenRouter key (pass --rotate-openrouter-key to replace it)"
        step_done "openrouter-key" "reused" "the stored key was reused; the dialog was not shown"
        return 0
    fi
    [ "$rotate" -eq 1 ] && say "rotating the OpenRouter key: the new value replaces the stored one and the gateway is restarted so it picks it up"
    key="$(spawn::prompt_secret "Superagent Gateway setup" \
        "Paste your OpenRouter API key. It is stored in your login Keychain, never echoed, and never written to a file that outlives the gateway's startup.")"
    rc=$?
    case "$rc" in
        "$SPAWN_SECRET_OK") ;;
        "$SPAWN_SECRET_CANCELLED")
            key=""
            die "$EX_USAGE" "step 'openrouter-key': the key dialog was cancelled, so nothing was stored and setup stopped here." ;;
        "$SPAWN_SECRET_EMPTY")
            key=""
            die "$EX_USAGE" "step 'openrouter-key': the key dialog came back empty — an empty value is not a credential, so nothing was stored." ;;
        *)
            key=""
            die "$EX_USAGE" "step 'openrouter-key': the key dialog could not be shown (osascript failed). On a first run macOS may ask to allow automation; allow it and re-run." ;;
    esac
    spawn::keychain_write "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_OPENROUTER" "$key"
    rc=$?
    # Cleared BEFORE the failure branch: a die() below prints its message
    # through the sanitizer to stderr, and the value must already be gone from
    # this shell by then. It is never in the message either way.
    key=""
    [ "$rc" -eq "$SPAWN_SECRET_OK" ] \
        || die "$EX_USAGE" "step 'openrouter-key': the Keychain write could not be verified by reading it back, so setup will not claim the key is stored (Keychain service '$KEYCHAIN_SERVICE', account '$KEYCHAIN_ACCOUNT_OPENROUTER')."
    record_change "keychain-item" "$KEYCHAIN_SERVICE/$KEYCHAIN_ACCOUNT_OPENROUTER" \
        "$([ "$rotate" -eq 1 ] && printf 'the OpenRouter key was replaced in place' || printf 'the OpenRouter key was stored')"
    step_done "openrouter-key" "$([ "$rotate" -eq 1 ] && printf 'rotated' || printf 'stored')" \
        "captured through the password dialog and verified by read-back; the value appears in no output"
    return 0
}

do_token_step() {
    local rotate="$1" tok rc
    step_start "gateway-token"
    if [ "$rotate" -ne 1 ] && spawn::keychain_exists "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_TOKEN"; then
        # R22. Reused, so every already-open shell keeps authenticating.
        say "reusing the stored gateway token (pass --rotate-gateway-token to replace it)"
        step_done "gateway-token" "reused" "the stored token was reused, so shells that are already open keep authenticating"
        return 0
    fi
    if [ "$rotate" -eq 1 ]; then
        # R22: BEFORE it happens, not after. Printed ahead of the write, not
        # merely ahead of the restart — the old token stops being valid the
        # moment the new one replaces it in the store.
        say "WARNING: rotating the gateway token breaks authentication in EVERY SHELL THAT IS ALREADY OPEN. Those shells hold the old value; they need to be restarted, or to re-source $GATEWAY_ENV_FILE. Shells opened after this run pick the new token up automatically."
    fi
    tok="$(spawn::generate_token)" \
        || die "$EX_USAGE" "step 'gateway-token': could not generate a token from /dev/urandom; nothing was stored."
    spawn::keychain_write "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_TOKEN" "$tok"
    rc=$?
    tok=""
    [ "$rc" -eq "$SPAWN_SECRET_OK" ] \
        || die "$EX_USAGE" "step 'gateway-token': the Keychain write could not be verified by reading it back, so setup will not claim a token is stored (Keychain service '$KEYCHAIN_SERVICE', account '$KEYCHAIN_ACCOUNT_TOKEN')."
    record_change "keychain-item" "$KEYCHAIN_SERVICE/$KEYCHAIN_ACCOUNT_TOKEN" \
        "$([ "$rotate" -eq 1 ] && printf 'the gateway token was rotated; already-open shells stop authenticating' || printf 'a gateway token was generated and stored; no human ever sees the value')"
    step_done "gateway-token" "$([ "$rotate" -eq 1 ] && printf 'rotated' || printf 'generated')" \
        "generated by setup, so the operator never types, pastes or records a token value"
    return 0
}

# ---------------------------------------------------------------------------
# do_setup — the whole path, in F1's order with ONE deliberate deviation.
#
# F1 lists the build before the credentials. Run that way, the FIRST RUN fails:
# `acquire` promotes a config with no token entry, and it refuses to do that
# while no gateway token is stored (R9's static half, already implemented in
# require_token_delivery). So both credential steps run first. The order change
# is invisible in the outcome and is what makes an interrupted build re-runnable
# without re-prompting: the key is already stored before the build starts.
# ---------------------------------------------------------------------------
do_setup() {
    local rotate_key="$1" rotate_token="$2" consent_gw="$3" consent_rc="$4"
    local rotated=0 base_url alias served tok start_verb

    ORCHESTRATING=1

    step_start "prereqs"
    need_prereqs
    step_done "prereqs" "ok" "curl, cargo and tar are all present"

    do_key_step "$rotate_key"
    [ "$rotate_key" -eq 1 ] && rotated=1
    do_token_step "$rotate_token"
    [ "$rotate_token" -eq 1 ] && rotated=1

    # --- acquire ------------------------------------------------------------
    step_start "acquire"
    run_sub acquire || die "$EX_USAGE" "step 'acquire': could not run the acquire step"
    SETUP_TAG="$(printf '%s' "$SUB_JSON" | jq -r '.tag // empty' 2>/dev/null)"
    SETUP_INSTALL_DIR="$(printf '%s' "$SUB_JSON" | jq -r '.install_dir // empty' 2>/dev/null)"
    if [ "$SUB_RC" -ne 0 ]; then
        die "$SUB_RC" "step 'acquire': $(printf '%s' "$SUB_JSON" | jq -r '.error // "the gateway could not be acquired"' 2>/dev/null)"
    fi
    case "$(printf '%s' "$SUB_JSON" | jq -r '.action // empty' 2>/dev/null)" in
        installed)
            record_change "gateway-install" "$SETUP_INSTALL_DIR" "gateway $SETUP_TAG was built and installed here"
            step_done "acquire" "installed" "built and promoted $SETUP_TAG" ;;
        *)
            step_done "acquire" "skipped" "$SETUP_TAG was already installed and runnable at $SETUP_INSTALL_DIR" ;;
    esac

    # --- gw -----------------------------------------------------------------
    step_start "gw"
    if [ "$consent_gw" -eq 1 ]; then
        run_sub gw --consent-overwrite-gw || die "$EX_USAGE" "step 'gw': could not run the gw step"
    else
        run_sub gw || die "$EX_USAGE" "step 'gw': could not run the gw step"
    fi
    [ "$SUB_RC" -eq "$EX_CONSENT" ] && pass_consent "gw"
    [ "$SUB_RC" -eq 0 ] || die "$SUB_RC" "step 'gw': $(printf '%s' "$SUB_JSON" | jq -r '.error // "the gw wrapper could not be written"' 2>/dev/null)"
    record_change "wrapper" "$GW_PATH" "$(printf '%s' "$SUB_JSON" | jq -r '"the gw wrapper was \(.action) (it was \(.state_before) before); its control verbs now delegate to the plugin and it carries no token value"' 2>/dev/null)"
    step_done "gw" "ok" "$(printf '%s' "$SUB_JSON" | jq -r '.action // "written"' 2>/dev/null) $GW_PATH"

    # --- wire ---------------------------------------------------------------
    step_start "wire"
    if [ "$consent_rc" -eq 1 ]; then
        run_sub wire --consent-shell-rc || die "$EX_USAGE" "step 'wire': could not run the wire step"
    else
        run_sub wire || die "$EX_USAGE" "step 'wire': could not run the wire step"
    fi
    [ "$SUB_RC" -eq "$EX_CONSENT" ] && pass_consent "wire"
    [ "$SUB_RC" -eq 0 ] || die "$SUB_RC" "step 'wire': $(printf '%s' "$SUB_JSON" | jq -r '.error // "no harness could be wired"' 2>/dev/null)"
    SETUP_WIRED_JSON="$(printf '%s' "$SUB_JSON" | jq -c '.wired // []' 2>/dev/null)"
    SETUP_SKIPPED_JSON="$(printf '%s' "$SUB_JSON" | jq -c '.skipped // []' 2>/dev/null)"
    SETUP_LOSSES_JSON="$(printf '%s' "$SUB_JSON" | jq -c '.losses // []' 2>/dev/null)"
    SETUP_GAPS_JSON="$(printf '%s' "$SUB_JSON" | jq -c '.validation_gaps // []' 2>/dev/null)"
    SETUP_ACTIVATION_JSON="$(printf '%s' "$SUB_JSON" | jq -c '.activation // null' 2>/dev/null)"
    # Each written file recorded individually: "wire ran" is not what an
    # operator reading a failure needs to know — which files now exist is.
    while IFS=$'\t' read -r what target detail; do
        [ -n "$what" ] || continue
        record_change "$what" "$target" "$detail"
    done <<EOF
$(printf '%s' "$SUB_JSON" | jq -r '
    (.wired[]? | select(.harness == "claude-code")
      | "harness-config\t\(.env_file)\tthe Keychain-reading shell snippet for Claude Code (no token value in it)",
        "shell-rc\t\(.shell_rc)\tthe source line was \(.rc_line)"),
    (.wired[]? | select(.harness == "codex")
      | "harness-config\t\(.config)\tthe spawn-setup managed block was \(.action); the credential is referenced by name only")' 2>/dev/null)
EOF
    step_done "wire" "ok" "wired: $(printf '%s' "$SETUP_WIRED_JSON" | jq -r '[.[].harness] | join(", ")' 2>/dev/null)"

    # --- start --------------------------------------------------------------
    # A rotation RESTARTS: the running gateway is holding the previous values,
    # and a rotation that left it running would report success over a process
    # that still has the old key in memory.
    step_start "start"
    start_verb="start"
    [ "$rotated" -eq 1 ] && start_verb="restart"
    local ctl_out ctl_rc=0
    ctl_out="$(bash "$SPAWNCTL_PATH" "$start_verb")" || ctl_rc=$?
    if [ "$ctl_rc" -ne 0 ]; then
        SETUP_FAILURE_CLASS="start"
        die "$EX_UNREACHABLE" "step 'start': the gateway could not be $([ "$start_verb" = restart ] && printf 'restarted' || printf 'started') ($(printf '%s' "$ctl_out" | jq -r '.error // "no reason reported"' 2>/dev/null)). The release just installed is named under 'release'."
    fi
    base_url="$(printf '%s' "$ctl_out" | jq -r '.base_url // empty' 2>/dev/null)"
    served="$(printf '%s' "$ctl_out" | jq -c '.served_aliases // []' 2>/dev/null)"
    [ -n "$base_url" ] || die "$EX_UNREACHABLE" "step 'start': the gateway reported no base url, so there is nothing to verify against."
    # spawnctl reports Claude Code's ANTHROPIC base — the root plus the
    # `/anthropic` route prefix — because that is what its own probe and every
    # launch path uses. The round-trip needs the ROOT: one harness's route lives
    # under that prefix and the other's (`/v1/responses`) does not, so appending
    # to the reported value would post to /anthropic/anthropic/v1/messages, which
    # 404s. Same trimming the GATEWAY_ROOT_URL default does, applied to the value
    # that actually came back from the process that is serving.
    base_url="${base_url%/}"
    base_url="${base_url%/anthropic}"
    step_done "start" "ok" "the gateway is serving at $base_url"

    # --- verify -------------------------------------------------------------
    step_start "verify"
    # KTD13's alias rule: chosen from what THIS gateway serves, at run time. A
    # bare-machine install from the upstream template does not serve this
    # machine's aliases, so a hardcoded one would 404 on the first-run path.
    alias="$(printf '%s' "$served" | jq -r '.[0] // empty' 2>/dev/null)"
    [ -n "$alias" ] \
        || die "$EX_UNREACHABLE" "step 'verify': the gateway at $base_url serves no model aliases, so there is nothing to round-trip through it."

    # LAYER TWO first, because it is already done: the wire step ran each
    # harness's own loader over the config it wrote. It is carried into this
    # object rather than re-run, and it is reported SEPARATELY from the
    # round-trip so neither can be mistaken for the other (KTD13, R25).
    local cfgval
    cfgval="$(printf '%s' "$SETUP_WIRED_JSON" | jq -c '[.[] | {harness,
        validated_by: (.validated_by // null),
        detail: (.validation_detail // .validation_note // null),
        covered: (if (.validated_by // null) == null then false else true end)}]' 2>/dev/null)"
    [ -n "$cfgval" ] || cfgval="[]"

    # LAYER ONE. The credential is read here and nowhere else in this step, held
    # in a local, and cleared straight after.
    tok="$(spawn::keychain_read "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_TOKEN")" \
        || die "$EX_USAGE" "step 'verify': no gateway token could be read back from the Keychain, so no round-trip can be made (service '$KEYCHAIN_SERVICE', account '$KEYCHAIN_ACCOUNT_TOKEN')."
    [ -n "$tok" ] \
        || die "$EX_USAGE" "step 'verify': the stored gateway token is empty, which authenticates nothing; re-run with --rotate-gateway-token."
    verify_round_trips "$base_url" "$alias" "$tok"
    tok=""

    SETUP_VERIFY_JSON="$(jq -nc --argjson cfg "$cfgval" --argjson rt "$VERIFY_RT_JSON" \
        --argjson unauth "$VERIFY_UNAUTH_JSON" \
        '{config_validation:$cfg, round_trip:$rt, unauthenticated_probe:$unauth,
          note:"neither layer alone is sufficient: a round-trip can pass over a config written where the harness will not look for it, and a config validation can pass over a gateway that is down"}')"
    step_done "verify" "ok" "both layers passed: each wired harness round-tripped in its own wire shape, and the unauthenticated probe was rejected"

    # --- report -------------------------------------------------------------
    say "setup is done. For THIS shell, run: . \"$GATEWAY_ENV_FILE\" — shells you open from now on need nothing."
    emit "$(jq -nc \
        --argjson steps "$STEPS_JSON" --argjson changed "$CHANGED_JSON" \
        --argjson wired "$SETUP_WIRED_JSON" --argjson skipped "$SETUP_SKIPPED_JSON" \
        --argjson losses "$SETUP_LOSSES_JSON" --argjson gaps "$SETUP_GAPS_JSON" \
        --argjson verification "$SETUP_VERIFY_JSON" --argjson activation "$SETUP_ACTIVATION_JSON" \
        --arg tag "$SETUP_TAG" --arg dir "$SETUP_INSTALL_DIR" --arg base "$base_url" \
        '{ok:true, verb:"setup", failed_step:null,
          steps:$steps, changed:$changed, wired:$wired, skipped:$skipped,
          losses:$losses, validation_gaps:$gaps, verification:$verification,
          activation:$activation, base_url:$base,
          release:{tag:(if $tag == "" then null else $tag end),
                   install_dir:(if $dir == "" then null else $dir end)},
          error:null, exit_code:0}')" \
        || die "$EX_USAGE" "could not encode the setup object"
    exit "$EX_OK"
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<'EOF'
usage: setup.sh [--rotate-openrouter-key] [--rotate-gateway-token]
                [--consent-overwrite-gw] [--consent-shell-rc]
       setup.sh acquire
       setup.sh gw [--consent-overwrite-gw]
       setup.sh wire [--consent-shell-rc]

  (no verb)  the whole path: prerequisites, both credentials, the gateway
             install, the gw wrapper, harness wiring, a start, and a live
             round-trip through every wired harness plus an unauthenticated
             probe that must be rejected. Re-running is safe: both stored
             credentials are reused and nothing is prompted for.

             --rotate-openrouter-key   re-prompt for the key, replace the
                                       stored item, restart the gateway
             --rotate-gateway-token    generate a new token, restart. Says
                                       first that already-open shells stop
                                       authenticating.

  acquire   resolve the latest published gateway release, fetch and build it in
            a staging directory, and promote it to ~/gateway-<version> in one
            atomic move. Skips the fetch and build when that install already
            exists and its binary runs.

  gw        rewrite ~/.local/bin/gw as a wrapper whose control verbs delegate to
            lib/spawnctl.sh and whose token is read from the Keychain at run
            time. A wrapper setup did not write is refused with exit 8 until
            --consent-overwrite-gw is passed.

  wire      wire every supported harness that is installed. Codex gets a
            marker-delimited managed block in ~/.codex/config.toml, validated by
            its own loader; Claude Code gets ~/.gateway/env.sh (a Keychain read,
            never a value) plus one source line in your shell rc, which is
            refused with exit 8 until --consent-shell-rc is passed. An installed
            harness that cannot be wired fails the run; `skipped` means a
            harness that is not installed.
EOF
}

# ---------------------------------------------------------------------------
# acquire (R1, R2, R3, R4; F1, F2)
# ---------------------------------------------------------------------------
do_acquire() {
    need_prereqs

    local tag version dest sha bin url

    resolve_latest_tag
    tag="$LATEST_TAG"
    version="${tag#v}"
    dest="$SEARCH_ROOT/gateway-$version"

    # R3's skip. It keys on the version-named DESTINATION directly rather than
    # re-implementing resolve_install_dir's highest-version walk: a fourth copy
    # of a resolver in this plugin is a defect waiting to happen, and the
    # question here is specifically "is the LATEST release already installed
    # and working?", which the destination path answers exactly.
    #
    # The config is part of the test because promotion never produces a
    # directory without one — a dest holding a binary and no config is a
    # partial install from some earlier era, and skipping over it would leave
    # the machine in precisely the state KTD4 exists to prevent.
    if [ -d "$dest" ] && bin="$(find_binary_in "$dest")" && [ -f "$dest/$CONFIG_NAME" ] && binary_runs "$bin"; then
        # R23. A skip still retires the token — this is the state the machine
        # this requirement was written for is actually in, and a skip that
        # skipped retirement too would leave the literal live forever.
        retire_installed_token "$dest/$CONFIG_NAME"
        require_token_delivery "$dest/$CONFIG_NAME"
        say "gateway $tag is already installed and runnable at $dest — nothing to build"
        emit "$(jq -nc --arg tag "$tag" --arg dir "$dest" --arg bin "$bin" --arg cfg "$dest/$CONFIG_NAME" \
            '{ok:true, verb:"acquire", action:"skipped", tag:$tag, commit:null,
              install_dir:$dir, binary:$bin, config:$cfg,
              error:null, exit_code:0}')" \
            || die "$EX_USAGE" "could not encode the acquire object"
        exit "$EX_OK"
    fi

    resolve_commit_sha "$tag"
    sha="$COMMIT_SHA"

    # Staging, beside the installs and invisible to the glob (see the header).
    STAGING_ROOT="$(umask 077; mktemp -d "$SEARCH_ROOT/.gateway-staging.XXXXXX")" \
        || die "$EX_UNREACHABLE" "step 'stage': could not create a staging directory under $SEARCH_ROOT (nothing has been changed on this machine)"
    local build="$STAGING_ROOT/build" archive="$STAGING_ROOT/src.tar.gz"
    mkdir -p "$build" || die "$EX_UNREACHABLE" "step 'stage': could not create the build directory under $STAGING_ROOT"

    url="https://github.com/$GATEWAY_REPO/archive/refs/tags/$tag.tar.gz"
    say "fetching $GATEWAY_REPO $tag ($sha)"
    "$SPAWN_CURL_BIN" -fsSL --max-time "$DOWNLOAD_TIMEOUT" -o "$archive" "$url" \
        || die "$EX_UNREACHABLE" "step 'fetch': could not download the source archive for $tag; the staging directory was removed and no install was changed"

    # --strip-components=1 drops GitHub's generated top-level <owner>-<repo>-<sha>
    # directory, so the build tree is the repo root.
    "$SPAWN_TAR_BIN" -xzf "$archive" -C "$build" --strip-components=1 \
        || die "$EX_UNREACHABLE" "step 'extract': the source archive for $tag could not be unpacked; the staging directory was removed and no install was changed"
    rm -f "$archive" 2>/dev/null

    say "building $tag (this takes a few minutes on a cold cargo registry)"
    ( cd "$build" && "$SPAWN_CARGO_BIN" build --release ) \
        || die "$EX_UNREACHABLE" "step 'build': cargo build --release failed for $tag; the staging directory was removed and no install was changed"

    stage_config "$build" \
        || die "$EX_USAGE" "step 'config': the $tag source archive carries no config template (looked for: ${CONFIG_CANDIDATES[*]}); the staging directory was removed and no install was changed"
    case "$STAGED_CONFIG_ORIGIN" in
        migrated) say "migrated the existing $CONFIG_NAME forward with its token entry removed" ;;
        template) say "no previous install found — staging the upstream $CONFIG_NAME template with its token entry removed" ;;
    esac

    # R9's static half, checked while the staged tree is still invisible to the
    # `gateway-*` glob: nothing unauthenticated ever becomes the install.
    require_token_delivery "$build/$CONFIG_NAME"

    promote "$build" "$dest"
    bin="$PROMOTED_BIN"
    rm -rf "$STAGING_ROOT" 2>/dev/null
    STAGING_ROOT=""

    say "installed gateway $tag at $dest"
    emit "$(jq -nc --arg tag "$tag" --arg sha "$sha" --arg dir "$dest" --arg bin "$bin" --arg cfg "$dest/$CONFIG_NAME" \
        '{ok:true, verb:"acquire", action:"installed", tag:$tag, commit:$sha,
          install_dir:$dir, binary:$bin, config:$cfg,
          error:null, exit_code:0}')" \
        || die "$EX_USAGE" "could not encode the acquire object"
    exit "$EX_OK"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$VERB" in
    acquire)
        shift
        [ $# -eq 0 ] || { need_jq; die "$EX_USAGE" "unexpected argument '$1'"; }
        need_jq
        do_acquire
        ;;
    gw)
        shift
        GW_CONSENT=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --consent-overwrite-gw) GW_CONSENT=1 ;;
                *) need_jq; die "$EX_USAGE" "unexpected argument '$1'" ;;
            esac
            shift
        done
        need_jq
        do_gw "$GW_CONSENT"
        ;;
    wire)
        shift
        WIRE_CONSENT=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --consent-shell-rc) WIRE_CONSENT=1 ;;
                *) need_jq; die "$EX_USAGE" "unexpected argument '$1'" ;;
            esac
            shift
        done
        need_jq
        do_wire "$WIRE_CONSENT"
        ;;
    -h|--help|help)
        usage
        need_jq
        die "$EX_USAGE" "help requested"
        ;;
    ""|--*)
        # The bare run (U7). NOTHING IS SHIFTED HERE: when $1 is a flag it is
        # still an argument, and a shift would silently eat the first one —
        # which for --rotate-gateway-token would mean a run that quietly did
        # not rotate.
        ROTATE_KEY=0
        ROTATE_TOKEN=0
        SETUP_CONSENT_GW=0
        SETUP_CONSENT_RC=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --rotate-openrouter-key) ROTATE_KEY=1 ;;
                --rotate-gateway-token)  ROTATE_TOKEN=1 ;;
                --consent-overwrite-gw)  SETUP_CONSENT_GW=1 ;;
                --consent-shell-rc)      SETUP_CONSENT_RC=1 ;;
                *) need_jq; die "$EX_USAGE" "unexpected argument '$1'" ;;
            esac
            shift
        done
        need_jq
        do_setup "$ROTATE_KEY" "$ROTATE_TOKEN" "$SETUP_CONSENT_GW" "$SETUP_CONSENT_RC"
        ;;
    *)
        usage
        need_jq
        die "$EX_USAGE" "unknown verb '${VERB:-}' (expected: acquire|gw|wire, or no verb for the whole path)"
        ;;
esac

#!/usr/bin/env bash
# setup-lib.sh — the shared foundation of the gateway plugin's setup path
# (plan U2 onward). SOURCED, never exec'd: setup.sh (the front door and
# orchestrator) and the four verb scripts beside it all load this file.
#
#   setup.sh acquire      → setup-acquire.sh
#   setup.sh gw           → setup-gw.sh
#   setup.sh supervisor   → setup-supervisor.sh
#   setup.sh wire         → setup-wire.sh
#   setup.sh (no verb)    the whole path, run by setup.sh itself
#
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

# ...unless "this script's own location" is a GIT WORKTREE, which is a
# directory that is EXPECTED to be deleted. Baking one produces a `gw` that
# works perfectly until the PR lands and the worktree is removed, then fails
# with exit 127 and no explanation anywhere on the machine. That is not
# hypothetical: it happened here on 2026-08-10, and the only reason it was
# diagnosed is that the person who broke it had just removed the worktree.
#
# A linked worktree is identified by git itself — in one, --git-dir points at
# <main>/.git/worktrees/<name> while --git-common-dir points at <main>/.git, so
# the two DIFFER. In a normal clone (and in a plain non-git install directory,
# where both calls simply fail) they do not, and nothing below runs.
#
# The fix is to bake the SAME file in the main working tree instead. Only done
# when that file actually exists: a plugin developed on a branch that the main
# checkout does not carry has no durable copy, and pointing at a path that is
# not there would trade a delayed break for an immediate one. In that case the
# worktree path is kept and the caller warns, which is the honest ordering —
# working now and fragile later beats broken now.
spawn::durable_spawnctl_path() {
    local from="$1" gitdir commondir main rel cand
    command -v git >/dev/null 2>&1 || return 1
    gitdir="$(git -C "$from" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
    commondir="$(git -C "$from" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$gitdir" ] && [ -n "$commondir" ] || return 1
    # Same directory => not a linked worktree => nothing to re-point.
    [ "$gitdir" = "$commondir" ] && return 1
    main="$(dirname "$commondir")"
    [ -d "$main" ] || return 1
    rel="$(git -C "$from" rev-parse --show-prefix 2>/dev/null)" || return 1
    cand="$main/${rel}$(basename "$SPAWNCTL_PATH")"
    [ -f "$cand" ] || return 1
    printf '%s' "$cand"
}

# Only re-point a path we derived ourselves. An explicit SPAWN_SPAWNCTL_PATH is
# the caller's decision and the suites' rail; overriding it here would make the
# override untestable.
SPAWNCTL_FROM_WORKTREE=0
if [ -z "${SPAWN_SPAWNCTL_PATH:-}" ]; then
    if _durable="$(spawn::durable_spawnctl_path "$SCRIPT_DIR")"; then
        SPAWNCTL_PATH="$_durable"
    elif git -C "$SCRIPT_DIR" rev-parse --absolute-git-dir >/dev/null 2>&1 \
         && [ "$(git -C "$SCRIPT_DIR" rev-parse --absolute-git-dir 2>/dev/null)" \
              != "$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]; then
        # A linked worktree with no durable twin: keep the path, flag it loudly.
        SPAWNCTL_FROM_WORKTREE=1
    fi
    unset _durable
fi

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

# ---------------------------------------------------------------------------
# The supervisor surface (U3 step 6; R28, KTD21). Same safety-rail reasoning as
# SPAWN_GW_PATH, and more of it: the default here is the operator's REAL
# ~/Library/LaunchAgents, and a suite that ran against it would rewrite the
# agent that supervises the machine it is testing on. Every test points all
# three of these at its own temp directory.
# ---------------------------------------------------------------------------
LAUNCH_AGENTS_DIR="${SPAWN_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHCTL_BIN="${SPAWN_LAUNCHCTL_BIN:-/bin/launchctl}"

# How long the supervisor step waits for launchd to fork the launcher and for
# the launcher to write the pidfile, before deciding the adoption is configured
# but not in effect. A seam, for the usual reason: the suites drive this path
# ~34 times and a real-machine budget spent waiting for a pidfile no fixture
# will ever write turned one suite from 64s into 203s. Generous by default,
# because the cost of deciding too early on a real machine is a false warning
# about a working adoption.
ADOPT_VERIFY_TRIES="${SPAWN_ADOPT_VERIFY_TRIES:-10}"
ADOPT_VERIFY_SLEEP="${SPAWN_ADOPT_VERIFY_SLEEP:-0.5}"
PLUTIL_BIN="${SPAWN_PLUTIL_BIN:-/usr/bin/plutil}"

# WHERE THE GENERATED LAUNCHER LIVES, AND WHY IT IS NOT IN THE INSTALL DIR.
# $HOME/.gateway is the plugin's own directory (it already holds env.sh) and it
# SURVIVES promote(). The install directory does not: a same-version rebuild
# moves the old one aside and deletes it, so a launcher written there would be
# deleted out from under a plist still pointing at it — leaving launchd execing
# a path that no longer exists AND destroying the recorded original command,
# which is the only copy of what the agent used to start. Recognition on a
# re-run depends on that file still being readable, so it lives where nothing
# in this script deletes it.
GATEWAY_LAUNCHER="${SPAWN_GATEWAY_LAUNCHER:-$HOME/.gateway/spawn-launch.sh}"
# The pidfile the generated launcher registers itself in. Resolved exactly as
# spawnctl.sh resolves it, so the two control surfaces name one file. (The
# PIDFILE inside gw_body is a different thing entirely: that is text of the
# generated `gw` wrapper, not a variable of this script.)
SETUP_STATE_HOME="${SPAWN_STATE_HOME:-$HOME}"
PIDFILE="${SPAWN_PIDFILE:-$SETUP_STATE_HOME/.gateway.pid}"

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


# ---------------------------------------------------------------------------
# Plumbing. Same chokepoints as the sibling scripts, deliberately byte-identical
# where the escapes.bats lint reads them: a defence spelled differently in each
# file is a defence the lint cannot verify.
# ---------------------------------------------------------------------------
# say() is inherited from common.sh — it was byte-identical in four files.
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
# Per-call scratch that can hold a CREDENTIAL. round_trip writes a curl config
# carrying the bearer token here, so it must be reachable from cleanup: a
# Ctrl-C during the verify step is an ordinary thing to do, and the local
# `rm -rf` at the end of that function is only reached on the normal path.
RT_WORK=""
cleanup() {
    if [ -n "$ASIDE" ] && [ -d "$ASIDE" ]; then
        if [ -n "$ASIDE_DEST" ] && [ ! -e "$ASIDE_DEST" ]; then
            mv "$ASIDE" "$ASIDE_DEST" 2>/dev/null
        else
            rm -rf "$ASIDE" 2>/dev/null
        fi
    fi
    [ -n "$RT_WORK" ] && rm -rf "$RT_WORK" 2>/dev/null
    [ -n "$STAGING_ROOT" ] && rm -rf "$STAGING_ROOT" 2>/dev/null
    # The contract is one JSON object on stdout on EVERY path, and a cancelled
    # orchestrated run is the path that used to break it: by the time verify
    # runs, two Keychain items exist, an install is promoted, gw is rewritten
    # and the rc file has a line appended — and the accumulator naming all of
    # that would have been discarded in silence. Guarded on EMITTED so the
    # single verbs and every normal exit are untouched.
    if [ "${ORCHESTRATING:-0}" -eq 1 ] && [ "${EMITTED:-0}" -eq 0 ]; then
        emit_setup_failure "$EX_UNREACHABLE" \
            "interrupted during step '${CURRENT_STEP:-unknown}' — nothing was rolled back; see 'changed' for what this run had already done"
    fi
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

# ORCHESTRATING routes die() through the R18 state report. The accumulators,
# the step helpers and emit_setup_failure live in setup.sh (the orchestrator
# block there), which flips this to 1 for the whole-path run. The 0 default
# lives HERE, in the shared foundation, because die() expands it unguarded
# under `set -u`: a verb process without the default would die on the unbound
# variable mid-die and exit with no JSON object at all.
ORCHESTRATING=0

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

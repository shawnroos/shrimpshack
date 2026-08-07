#!/usr/bin/env bash
# setup.sh — the gateway plugin's setup path (plan U2 onward).
#
#   setup.sh acquire      fetch, build and promote the latest gateway release
#   setup.sh gw           rewrite ~/.local/bin/gw as a Keychain-sourced,
#                         plugin-delegating wrapper (U5)
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

# The wrapper setup rewrites (KD8, R19). Overridable so no suite can ever be one
# typo away from writing the operator's real `gw`.
GW_PATH="${SPAWN_GW_PATH:-$HOME/.local/bin/gw}"

# The delegation target, baked ABSOLUTE into the emitted wrapper (KTD14). It is
# resolved from this script's own location, so a setup re-run from a moved or
# reinstalled plugin re-bakes the new path rather than leaving the wrapper
# pointing at a directory that no longer exists.
SPAWNCTL_PATH="${SPAWN_SPAWNCTL_PATH:-$SCRIPT_DIR/spawnctl.sh}"

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
    emit_error "$code" "$*"
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

# ---------------------------------------------------------------------------
# run_bounded <seconds> <command...>
# Runs a command with a wall-clock bound, returning its status, or 124 if it
# had to be killed. There is NO `timeout` binary on macOS — reaching for one
# gives a command-not-found whose non-zero status reads exactly like the probe
# failing, so the "is this binary runnable?" question would answer "no" on
# every machine. The bound matters because the thing being run is an arbitrary
# file found on disk: a binary that ignores --version and starts serving would
# otherwise hang setup forever, and a hang is worse than a named failure.
# ---------------------------------------------------------------------------
run_bounded() {
    local secs="$1"; shift
    local pid i rc
    "$@" </dev/null >/dev/null 2>&1 &
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

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<'EOF'
usage: setup.sh acquire
       setup.sh gw [--consent-overwrite-gw]

  acquire   resolve the latest published gateway release, fetch and build it in
            a staging directory, and promote it to ~/gateway-<version> in one
            atomic move. Skips the fetch and build when that install already
            exists and its binary runs.

  gw        rewrite ~/.local/bin/gw as a wrapper whose control verbs delegate to
            lib/spawnctl.sh and whose token is read from the Keychain at run
            time. A wrapper setup did not write is refused with exit 8 until
            --consent-overwrite-gw is passed.
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
    -h|--help|help)
        usage
        need_jq
        die "$EX_USAGE" "help requested"
        ;;
    *)
        usage
        need_jq
        die "$EX_USAGE" "unknown verb '${VERB:-}' (expected: acquire|gw)"
        ;;
esac

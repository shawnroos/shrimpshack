#!/usr/bin/env bash
# setup-supervisor.sh — the `supervisor` verb: adopt a launchd agent that already supervises this gateway (U3 step 6).
# Split out of setup.sh as a pure code move: setup.sh still fronts this verb
# (its dispatch execs this file with argv passed through whole), and the
# CONTRACT, the frozen exit-code enum and the staging rationale are stated
# once in setup-lib.sh's header — none of them changed in the split.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sourced directly, not only through setup-lib.sh: escapes.bats' terminal sink
# lint requires every executable in lib/ to source the sanitizer and own its
# printing chokepoint — the same shape spawnctl.sh, lens.sh and launch.sh
# each carry.
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"

# The shared foundation: contract constants, the config surface, die/emit
# plumbing, the cleanup trap, and every helper more than one verb needs.
# shellcheck source=./setup-lib.sh
. "$SCRIPT_DIR/setup-lib.sh"

# The printing chokepoint, byte-identical to setup-lib.sh's definition (the
# sink lint asks each script to own the chokepoint it prints through).
say() { printf '▸ %s\n' "$(spawn::sanitize_for_display "$*")" >&2; }


# ===========================================================================
# THE SUPERVISOR (U3 step 6; R28, KTD21)
# ===========================================================================
#
# WHY THIS STEP EXISTS AT ALL. A `launchd` agent is a THIRD control surface,
# and it outranks both the plugin and `gw`: KeepAlive undoes a stop within
# seconds, RunAtLoad starts the gateway at login, and its relaunch carries a
# BARE ENVIRONMENT that never sees the transient delivery file the start path
# writes. Found live on the build machine: the agent has no EnvironmentVariables
# key at all, so once setup retires the token out of gateway.yaml, EVERY launchd
# start comes up with an empty auth token list — which that gateway serves as
# "no auth required". An unauthenticated request to it returned 200.
#
# WHY A LAUNCHER AND NOT A PLIST KEY. Writing GATEWAY_TOKEN into the plist's
# EnvironmentVariables was considered and REJECTED (KTD21): it puts a credential
# at rest where none was before, in a file that is not encrypted and rides into
# backups. The launcher reads the Keychain at start instead, so the Keychain
# stays the only store and nothing new rests on disk. Putting the token in the
# gateway's exec-time environment is already sanctioned by KD3 — it is
# loopback-only, worthless off 127.0.0.1:4000, and cheap to rotate. The
# OpenRouter key is the one that must never travel that way, and it does not:
# the launcher `cd`s to the install directory so the gateway keeps reading it
# from that directory's own .env.local, and UNSETS it before exec so an
# inherited export cannot turn into the exposure R7 forbids.
#
# WHAT IT WILL NOT DO. It adopts an agent that already exists and NEVER creates
# one; a machine with no matching agent is reported not-supervised and nothing
# is written anywhere. Two matching agents is a refusal, not a guess. Every
# other key in the adopted plist — KeepAlive, RunAtLoad, WorkingDirectory,
# StandardOutPath, StandardErrorPath, Label — survives untouched.
#
# THE COST, STATED RATHER THAN ABSORBED (KTD21): setup rewrites ProgramArguments
# in a plist the operator wrote, so the gateway now starts through a file this
# plugin owns. That is a real escalation of what the plugin touches, and the
# step says so in its own output rather than reporting a bare success.
# ---------------------------------------------------------------------------

# The recognition marker, and the recorded original command. Their exact text is
# part of the contract for the same reason GW_MARKER's is: a re-run recognises
# its own launcher by the marker, and recovers the argv the agent ORIGINALLY
# started with from the recorded line — the plist no longer holds it, because
# the plist now names the launcher.
LAUNCHER_MARKER="# spawn-setup: generated launcher — rewritten by /spawn:setup, edits are not preserved"
LAUNCHER_ARGV_PREFIX="# spawn-setup-original-argv: "
# The delivery file the launcher writes for the gateway's dotenv, and how long
# it may live. Both are baked into the generated script rather than read from
# the environment there — launchd inherits nothing — and both are overridable
# so the launcher-runtime tests do not have to sleep for real.
LAUNCHER_DELIVERY_NAME="${SPAWN_DELIVERY_NAME:-.env.local}"
LAUNCHER_DELIVERY_TTL="${SPAWN_LAUNCHER_DELIVERY_TTL:-15}"

# plist_json <path> — the plist as JSON on stdout. Goes through plutil rather
# than a text parser because a LaunchAgent plist is as likely to be binary as
# XML, and grepping a bplist for a path is how a detector reports "not
# supervised" on a machine that is. A plist plutil cannot represent as JSON
# (dates, data) fails here and is SKIPPED by the sweep — an unrelated agent in
# the operator's directory must not fail this step.
plist_json() {
    "$PLUTIL_BIN" -convert json -o - "$1" 2>/dev/null
}

# plist_format <path> — the encoding to write back. Preserved rather than
# normalised: rewriting a binary agent as XML changes a file the operator owns
# more than the one key this step is entitled to change.
plist_format() {
    case "$(head -c 8 "$1" 2>/dev/null)" in
        bplist0*) printf 'binary1' ;;
        *)        printf 'xml1' ;;
    esac
}

# launcher_stored_argv <file> — the recorded original command, as a JSON array,
# from a launcher this setup wrote. Non-zero when the file is absent, carries no
# marker, or carries no usable record: those are the states where the original
# command is UNRECOVERABLE, and the caller turns them into a named failure
# rather than quietly inventing an argv.
launcher_stored_argv() {
    local f="$1" line
    [ -f "$f" ] || return 1
    grep -qF -- "$LAUNCHER_MARKER" "$f" 2>/dev/null || return 1
    line="$(awk -v p="$LAUNCHER_ARGV_PREFIX" 'index($0, p) == 1 { print substr($0, length(p) + 1); exit }' "$f")"
    [ -n "$line" ] || return 1
    printf '%s' "$line" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || return 1
    printf '%s' "$line"
}

# sibling_install_of <arg0> <resolved-install> — the gateway install directory
# that an agent's ProgramArguments[0] names, when that path is a `gateway-*`
# install sitting BESIDE the resolved one. Nothing, non-zero, when it is not.
#
# WHY THIS EXISTS: matching only the RESOLVED binary makes the whole step
# silently no-op on the upgrade path. `acquire` installs gateway-<newer> beside
# the version the operator wrote into the plist, the exact comparison fails, the
# step reports "not supervised", and setup reports success while launchd keeps
# starting the OLD binary — which, after token retirement, comes up with an
# empty auth list. That is the wrong-success shape R28 exists to prevent.
#
# PURELY A PATH TEST — no `-e`, no stat. By the time this runs, the install the
# plist names is routinely GONE: promote() moves a replaced same-version install
# aside and deletes it. A detector that required the old path to still exist
# would go blind on exactly the upgrade it is here to catch.
#
# The suffix is stripped candidate by candidate rather than matched with a
# `case` glob because `*` in a case pattern crosses `/`, so `root/gateway-*/bin`
# would also match `root/gateway-x/anything/deeper/bin`.
sibling_install_of() {
    local arg0="$1" install="${2%/}" cand stale
    [ -n "$arg0" ] && [ -n "$install" ] || return 1
    for cand in "${SPAWN_BIN_CANDIDATES[@]}"; do
        stale="${arg0%/"$cand"}"
        [ "$stale" = "$arg0" ] && continue
        [ -n "$stale" ] || continue
        [ "$(dirname "$stale")" = "$(dirname "$install")" ] || continue
        case "$(basename "$stale")" in
            gateway-*) printf '%s' "$stale"; return 0 ;;
        esac
    done
    return 1
}

# rebase_argv <argv-json> <resolved-bin> <stale-install> <install> — the command
# the launcher should EXEC, with the install it was written against swapped for
# the one this run resolved.
#
# arg0 comes from find_binary_in rather than from a prefix substitution: an
# install built --release and one built --debug hold the binary at different
# paths inside the tree, so substituting the directory would name a file that
# does not exist. Every later argument that lived under the old install (the
# `--config .../gateway.yaml` the operator wrote) is prefix-rebased; anything
# else is passed through untouched.
rebase_argv() {
    printf '%s' "$1" | jq -c --arg b "$2" --arg s "${3%/}/" --arg i "${4%/}/" \
        '[$b] + (.[1:] | map(if type == "string" and startswith($s) then $i + .[($s | length):] else . end))' 2>/dev/null
}

# detect_supervisor <binary> <install> — the sweep. Answers in two globals rather
# than on stdout for the reason stated at resolve_latest_tag: this function calls
# die(), and a die inside a command substitution writes the contract's one JSON
# object into a variable instead of to the consumer.
#
# An agent matches when its ProgramArguments[0] is the resolved gateway binary
# (the first-adoption shape), ANY `gateway-*` sibling install's binary beside it
# (the upgrade shape — see sibling_install_of), or this script's own launcher
# (the re-run shape, where the original command comes back out of the launcher).
# Counting finishes BEFORE anything is written, so the zero-match and two-match
# paths write neither file.
SUPERVISOR_PLIST=""
SUPERVISOR_ARGV=""
detect_supervisor() {
    local bin="$1" install="$2" plist json arg0 args stored matches=0 found_plist="" found_args=""
    SUPERVISOR_PLIST=""
    SUPERVISOR_ARGV=""
    [ -d "$LAUNCH_AGENTS_DIR" ] || return 0
    for plist in "$LAUNCH_AGENTS_DIR"/*.plist; do
        [ -f "$plist" ] || continue
        json="$(plist_json "$plist")" || continue
        [ -n "$json" ] || continue
        arg0="$(printf '%s' "$json" | jq -r '.ProgramArguments[0]? // empty' 2>/dev/null)"
        [ -n "$arg0" ] || continue
        if [ "$arg0" = "$bin" ] || sibling_install_of "$arg0" "$install" >/dev/null; then
            args="$(printf '%s' "$json" | jq -c '.ProgramArguments' 2>/dev/null)"
            [ -n "$args" ] || continue
        elif [ "$arg0" = "$GATEWAY_LAUNCHER" ]; then
            stored="$(launcher_stored_argv "$GATEWAY_LAUNCHER")" \
                || die "$EX_USAGE" "step 'supervisor': the launchd agent '$plist' already starts the gateway through '$GATEWAY_LAUNCHER', but that file is missing or carries no recorded original command — the command the agent started with cannot be recovered, so nothing was rewritten. Restore the agent's own ProgramArguments and re-run."
            args="$stored"
        else
            continue
        fi
        matches=$((matches + 1))
        found_plist="$plist"
        found_args="$args"
    done
    [ "$matches" -eq 0 ] && return 0
    [ "$matches" -gt 1 ] \
        && die "$EX_USAGE" "step 'supervisor': $matches launchd agents in '$LAUNCH_AGENTS_DIR' start this gateway, and setup will not guess which one supervises it — nothing was written and no plist was touched. Leave exactly one and re-run."
    SUPERVISOR_PLIST="$found_plist"
    SUPERVISOR_ARGV="$found_args"
    return 0
}

# launcher_body <argv-json> <install-dir> — everything below the recorded-argv
# line. The Keychain coordinates and the security binary are BAKED RESOLVED
# rather than left as ${VAR:-default} expansions, because launchd starts this
# with a bare environment: an indirection through a variable nothing sets is an
# indirection to the default, and a test's seam would never reach it.
#
# NO CREDENTIAL VALUE IS RESOLVED HERE. The token is read at START time, in the
# launched process, so rotation reaches the supervised gateway with no rewrite
# and no value ever rests in this file.
launcher_body() {
    local argv="$1" install="$2" cmd dir gwbin
    cmd="$(printf '%s' "$argv" | jq -r '@sh' 2>/dev/null)" || return 1
    [ -n "$cmd" ] || return 1
    dir="$(printf '%s' "$install" | jq -Rr '@sh' 2>/dev/null)" || return 1
    [ -n "$dir" ] || return 1
    # argv[0] of the executed command — the gateway binary this launcher will
    # become. Recorded beside the pidfile so spawnctl's anchored identification
    # (pid_is_gateway) accepts a launcher-started process as its own.
    gwbin="$(printf '%s' "$argv" | jq -r '.[0] // empty' 2>/dev/null)" || return 1
    [ -n "$gwbin" ] || return 1
    cat <<EOF
set -uo pipefail

# Baked at write time from the install this setup run resolved.
INSTALL_DIR=$dir
GATEWAY_BIN='$gwbin'
KEYCHAIN_SERVICE='$KEYCHAIN_SERVICE'
KEYCHAIN_ACCOUNT_TOKEN='$KEYCHAIN_ACCOUNT_TOKEN'
KEYCHAIN_ACCOUNT_OPENROUTER='$KEYCHAIN_ACCOUNT_OPENROUTER'
SECURITY_BIN='$SPAWN_SECURITY_BIN'
# EVERY path is baked. launchd starts this with an environment that inherits
# nothing from the shell setup ran in — no SPAWN_STATE_HOME, no SPAWN_PIDFILE —
# so a launcher that read those would write its pidfile somewhere spawnctl
# never looks.
PIDFILE='$PIDFILE'
DELIVERY_NAME='$LAUNCHER_DELIVERY_NAME'
DELIVERY_TTL='$LAUNCHER_DELIVERY_TTL'
# credentials are NEVER baked into this file: the token is read from the
# Keychain at start time, so rotating it reaches this launcher with no rewrite.
EOF
    cat <<'EOF'

# The gateway loads its .env.local CWD-relative, and that file is how the
# OpenRouter key reaches it. Starting anywhere else silently starts a gateway
# with no upstream credential.
if ! cd "$INSTALL_DIR"; then
    printf 'spawn-launch: the recorded gateway install directory is gone — run /spawn:setup\n' >&2
    exit 3
fi

# `|| true` because `security` exits 44 when there is no such item, and under a
# pipefail shell that status would end the launcher before the named, actionable
# refusal below ever ran.
token="$("$SECURITY_BIN" find-generic-password -a "$KEYCHAIN_ACCOUNT_TOKEN" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
if [ -z "$token" ]; then
    printf 'spawn-launch: no gateway token is stored — refusing to start an unauthenticated gateway; run /spawn:setup\n' >&2
    exit 9
fi
export GATEWAY_TOKEN="$token"

# R7. The OpenRouter key must never arrive in an exec-time environment, where
# any same-user process reads it out of the process table; it comes from this
# directory's own .env.local instead. An inherited export would both sit in that
# environment AND suppress the delivered value, because the gateway's dotenv
# only sets variables that are unset.
unset OPENROUTER_API_KEY

# THE KEY IS DELIVERED HERE, not assumed to be lying around. This file used to
# rely on a pre-existing .env.local, and there is never one: spawnctl WRITES
# that file to start the gateway and deletes it again as soon as the start
# probe settles, so after any spawnctl start the launcher had no upstream
# credential at all and launchd brought up a keyless gateway. Mirrors
# spawnctl's deliver_secrets, for the reasons documented there — `rm -f` first
# so a stale symlink cannot redirect the key out of this directory, umask on
# creation AND an explicit chmod because a replaced file keeps its old mode,
# and a shell-builtin printf so the value never reaches the process table.
key="$("$SECURITY_BIN" find-generic-password -a "$KEYCHAIN_ACCOUNT_OPENROUTER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
if [ -n "$key" ]; then
    rm -f "$INSTALL_DIR/$DELIVERY_NAME" 2>/dev/null
    if (umask 077; : > "$INSTALL_DIR/$DELIVERY_NAME") 2>/dev/null; then
        chmod 600 "$INSTALL_DIR/$DELIVERY_NAME" 2>/dev/null
        printf 'OPENROUTER_API_KEY=%s\n' "$key" >> "$INSTALL_DIR/$DELIVERY_NAME"
        # The file's life is the startup window and no longer (KTD1: the key
        # rests in the Keychain, never on disk). It is removed further down, in
        # THIS process, once the gateway has started — see the supervision tail.
    else
        # No interpolation, like every other message this launcher prints: it
        # is a standalone generated script with no access to the sanitizing
        # chokepoints, and the install directory is recorded above in this same
        # file. The sink lint enforces that rule rather than trusting it.
        printf 'spawn-launch: could not write the start-time key delivery file in the install directory recorded above — starting without an upstream credential\n' >&2
    fi
fi
key=""

# THE SUPERVISION TAIL. This script does NOT exec the gateway; it starts it as
# a child and stays alive as a thin parent. launchd is satisfied by any
# long-lived process, and staying alive buys the one thing exec cannot: the
# delivery file is removed by THIS process, deterministically.
#
# The exec version forked a `( sleep N; rm )` child to do that, and under
# launchd that child did not survive to run — measured on a real adopted agent,
# where the key was still on disk minutes later with the TTL correctly baked.
# It works fine under a direct run, which is exactly why a test that runs the
# launcher directly cannot see the difference.
EOF
    # The argv is substituted HERE, at generation time: the surrounding heredoc
    # is quoted so the launcher's own runtime variables survive verbatim, which
    # also means $cmd would not expand inside it.
    printf '%s &\ngw_pid=$!\n' "$cmd"
    cat <<'EOF'

# REGISTER the CHILD. That pid is the gateway, which is what spawnctl must be
# able to identify and signal; without it a launchd-started gateway is
# invisible, `stop` refuses with "unmanaged" (correctly — it will not guess
# which process to signal) and every restart path aborts over a healthy one.
#
# The liveness check is not belt-and-braces. setup's own start step and launchd
# can race for the port; the loser must not overwrite the winner's pidfile,
# because that is how spawnctl would be pointed at a process that is not
# serving.
claimed=1
if [ -f "$PIDFILE" ] && [ -f "$PIDFILE.bin" ]; then
    prev="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null || true)"
    prevbin="$(cat "$PIDFILE.bin" 2>/dev/null || true)"
    if [ -n "$prev" ] && [ "$prevbin" = "$GATEWAY_BIN" ] && [ "$prev" != "$gw_pid" ] \
       && kill -0 "$prev" 2>/dev/null; then
        printf 'spawn-launch: another process is already running this gateway binary — leaving its pidfile alone\n' >&2
        claimed=0
    fi
    prev=""; prevbin=""
fi
if [ "$claimed" -eq 1 ]; then
    printf '%s\n' "$gw_pid" > "$PIDFILE"
    printf '%s\n' "$GATEWAY_BIN" > "$PIDFILE.bin"
fi

# launchd stops a job by signalling THIS process. Forward it, or the gateway
# would outlive the unload and keep the port — the state this whole unit exists
# to make impossible.
trap 'kill -TERM "$gw_pid" 2>/dev/null' TERM INT HUP

# The delivery file's whole life. The gateway reads its dotenv at startup, so a
# bounded wait covers it; then the plaintext key leaves the disk.
sleep "$DELIVERY_TTL"
rm -f "$INSTALL_DIR/$DELIVERY_NAME" 2>/dev/null

# `wait` returns early when a trapped signal arrives, so it is retried until
# the child is genuinely gone; the second wait reports its real status. Exiting
# with that status is what lets a KeepAlive agent see a crash as a crash.
wait "$gw_pid" 2>/dev/null
gw_rc=$?
while kill -0 "$gw_pid" 2>/dev/null; do
    wait "$gw_pid" 2>/dev/null
    gw_rc=$?
done
if [ "$claimed" -eq 1 ]; then
    rm -f "$PIDFILE" "$PIDFILE.bin" 2>/dev/null
fi
exit "$gw_rc"
EOF
}

# write_launcher <recorded-argv-json> <exec-argv-json> <install-dir> — assemble
# and land it in one rename.
#
# TWO ARGVS, AND THE DIFFERENCE IS DELIBERATE. The RECORDED one is the argv this
# setup FIRST adopted, and it never moves: it is the only surviving copy of the
# command the operator wrote, and a re-run recovers the agent from it. The
# EXECUTED one is that command rebased onto the install this run resolved, so an
# upgrade is followed rather than pinned. On a machine with no upgrade the two
# are identical and the file is byte-identical across re-runs.
write_launcher() {
    local argv="$1" exec_argv="$2" install="$3" dir tmp body
    dir="$(dirname "$GATEWAY_LAUNCHER")"
    mkdir -p "$dir" || return 1
    body="$(launcher_body "$exec_argv" "$install")" || return 1
    [ -n "$body" ] || return 1
    # PROVE the body is complete, do not assume it. launcher_body builds the
    # script from several heredocs, and an unset variable in ONE of them kills
    # only that heredoc inside the command substitution: the rest still emits,
    # the substitution still exits 0, and what lands is a launcher missing its
    # entire configuration block that fails at start time with `cd: null
    # directory`. That is not hypothetical — it is what this check was written
    # against. Each name below is load-bearing at runtime, so a body missing
    # any of them is a broken launcher and must not replace a working one.
    local need
    for need in INSTALL_DIR GATEWAY_BIN PIDFILE KEYCHAIN_SERVICE \
                KEYCHAIN_ACCOUNT_TOKEN KEYCHAIN_ACCOUNT_OPENROUTER SECURITY_BIN; do
        printf '%s' "$body" | grep -q "^$need=" || return 1
    done
    # The launch line and the supervision tail. The launcher no longer execs —
    # it starts the gateway as a child and waits — so a body that still ended
    # at an exec, or that lost the wait, would be a launcher launchd could not
    # stop and one that never removes the delivered key.
    printf '%s' "$body" | grep -q '^gw_pid=\$!' || return 1
    printf '%s' "$body" | grep -q '^wait "\$gw_pid"' || return 1
    printf '%s' "$body" | grep -q 'rm -f "\$INSTALL_DIR/\$DELIVERY_NAME"' || return 1
    tmp="$GATEWAY_LAUNCHER.spawn-setup.$$"
    rm -f "$tmp" 2>/dev/null
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$LAUNCHER_MARKER"
        printf '%s%s\n' "$LAUNCHER_ARGV_PREFIX" "$argv"
        printf '%s\n' "$body"
    } > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
    chmod 755 "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv "$tmp" "$GATEWAY_LAUNCHER" || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

# repoint_plist <plist> <launcher> — ONE key changed, through a temp file and a
# rename. Rename because launchd and the operator both read this file, and it
# must never be seen half-written; the mode is carried over with stat/chmod for
# the same reason retire_installed_token carries it, and the ENCODING is carried
# over too. Every other key round-trips through plutil untouched.
repoint_plist() {
    local plist="$1" launcher="$2" json new fmt tmpjson tmpplist mode
    json="$(plist_json "$plist")" || return 1
    [ -n "$json" ] || return 1
    new="$(printf '%s' "$json" | jq -c --arg l "$launcher" '.ProgramArguments = [$l]' 2>/dev/null)" || return 1
    [ -n "$new" ] || return 1
    fmt="$(plist_format "$plist")"
    tmpjson="$plist.spawn-setup.$$.json"
    tmpplist="$plist.spawn-setup.$$"
    rm -f "$tmpjson" "$tmpplist" 2>/dev/null
    printf '%s\n' "$new" > "$tmpjson" || { rm -f "$tmpjson" 2>/dev/null; return 1; }
    "$PLUTIL_BIN" -convert "$fmt" -o "$tmpplist" "$tmpjson" >/dev/null 2>&1 \
        || { rm -f "$tmpjson" "$tmpplist" 2>/dev/null; return 1; }
    rm -f "$tmpjson" 2>/dev/null
    mode="$(stat -f '%Lp' "$plist" 2>/dev/null || stat -c '%a' "$plist" 2>/dev/null)"
    [ -n "$mode" ] && chmod "$mode" "$tmpplist" 2>/dev/null
    mv "$tmpplist" "$plist" || { rm -f "$tmpplist" 2>/dev/null; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# supervisor (R28; F1)
#
# No credential is ever in scope in this path — the launcher carries a Keychain
# READ, and this script never resolves the value — so there is deliberately no
# `local -; set +x` guard here. Adding one would imply a secret passes through,
# which is the opposite of what the design promises.
# ---------------------------------------------------------------------------
do_supervisor() {
    local sv_consent="${1:-0}"; shift 2>/dev/null || true
    local install="$1" bin name path arg0 stale exec_argv rebased=0

    # R4's shape, applied to this verb's two seams: a missing binary is exit 9
    # naming it, never a silent "not supervised".
    for name in plutil launchctl; do
        case "$name" in
            plutil)    path="$PLUTIL_BIN" ;;
            launchctl) path="$LAUNCHCTL_BIN" ;;
        esac
        case "$path" in
            */*) [ -f "$path" ] && [ -x "$path" ] \
                    || die "$EX_PREREQ" "missing prerequisite: $name (resolved to '$path'; install it, or point the matching SPAWN_*_BIN seam at it)" ;;
            *)   command -v "$path" >/dev/null 2>&1 \
                    || die "$EX_PREREQ" "missing prerequisite: $name (resolved to '$path'; install it, or point the matching SPAWN_*_BIN seam at it)" ;;
        esac
    done

    [ -n "$install" ] \
        || die "$EX_USAGE" "step 'supervisor': no gateway install directory was given (pass --install-dir, or set SPAWN_INSTALL_DIR); nothing was written"
    # A trailing slash would break both the sibling comparison (dirname of
    # "$d/" is "$d") and the prefix rebase, so it is dropped once, here.
    install="${install%/}"
    [ -d "$install" ] \
        || die "$EX_USAGE" "step 'supervisor': '$install' is not a directory, so there is no install a launchd agent could be supervising; nothing was written"
    bin="$(find_binary_in "$install")" \
        || die "$EX_USAGE" "step 'supervisor': '$install' holds no executable gateway binary (looked for: ${SPAWN_BIN_CANDIDATES[*]}); nothing was written"

    detect_supervisor "$bin" "$install"

    if [ -z "$SUPERVISOR_PLIST" ]; then
        # NEVER CREATES ONE. A machine with no supervising agent has nothing to
        # adopt, and inventing a plist here would make this plugin the owner of
        # a startup path the operator never asked it to own.
        say "no launchd agent in $LAUNCH_AGENTS_DIR starts $bin — nothing to adopt, and nothing was written"
        emit "$(jq -nc --arg d "$LAUNCH_AGENTS_DIR" --arg b "$bin" \
            '{ok:true, verb:"supervisor", action:"not-supervised", plist:null, launcher:null,
              program:$b, agents_dir:$d,
              detail:"no launchd agent starts this gateway, so nothing was adopted; setup never creates one",
              error:null, exit_code:0}')" \
            || die "$EX_USAGE" "could not encode the supervisor object"
        exit "$EX_OK"
    fi

    # THE REBASE. The adopted argv may name an install this run did not resolve —
    # the operator wrote gateway-0.1.1 into the plist and acquire has since
    # installed gateway-0.2.0 beside it. The recorded argv keeps naming what it
    # first adopted (that record is the only surviving copy of the operators own
    # command), and the launcher EXECS the resolved binary and config instead.
    arg0="$(printf '%s' "$SUPERVISOR_ARGV" | jq -r '.[0] // empty' 2>/dev/null)"
    stale="$(sibling_install_of "$arg0" "$install")" || stale=""
    exec_argv="$SUPERVISOR_ARGV"
    if [ -n "$stale" ]; then
        exec_argv="$(rebase_argv "$SUPERVISOR_ARGV" "$bin" "$stale" "$install")"
        [ -n "$exec_argv" ] \
            || die "$EX_USAGE" "step 'supervisor': could not rebase the launchd agents recorded command from '$stale' onto '$install'; nothing was written and the agent at '$SUPERVISOR_PLIST' is untouched"
        [ "$exec_argv" = "$SUPERVISOR_ARGV" ] || rebased=1
    fi

    if [ "$rebased" -eq 1 ]; then
        say "the launchd agent at $SUPERVISOR_PLIST still names the install at $stale, and this run resolved $install — the launcher will start the RESOLVED binary and config, so the agent follows the upgrade instead of pinning to the version it was written against"
    fi

    # CONSENT (KTD17). Repointing a launchd agent takes over a file setup did
    # not write and inserts this plugin into the machine's startup path — the
    # same class of act as overwriting a foreign `gw`, which has been gated
    # since it shipped. This one was not, and it is the more consequential of
    # the two: it changes what happens at every login, not what one command
    # does.
    if [ "$sv_consent" -ne 1 ]; then
        say "adopting the launchd agent at $SUPERVISOR_PLIST means setup owns a step in this machine's startup path — refusing to repoint it without consent"
        emit "$(jq -nc --arg p "$SUPERVISOR_PLIST" --arg l "$GATEWAY_LAUNCHER" --argjson c "$EX_CONSENT" \
            '{ok:false, verb:"supervisor",
              error:("refusing to repoint \($p): adopting it puts setup in this machines startup path; re-run with --consent-adopt-agent to adopt it"),
              consent_required:"adopt-agent", plist:$p, launcher:$l, exit_code:$c}')" \
            || die "$EX_USAGE" "could not encode the supervisor consent object"
        exit "$EX_CONSENT"
    fi

    write_launcher "$SUPERVISOR_ARGV" "$exec_argv" "$install" \
        || die "$EX_USAGE" "step 'supervisor': could not write the launcher at '$GATEWAY_LAUNCHER'; the launchd agent at '$SUPERVISOR_PLIST' is untouched"

    repoint_plist "$SUPERVISOR_PLIST" "$GATEWAY_LAUNCHER" \
        || die "$EX_USAGE" "step 'supervisor': could not repoint the ProgramArguments of '$SUPERVISOR_PLIST'; it is untouched"

    # An unload of a job that is not loaded fails, and that is an ordinary state
    # (the operator's agent may be unloaded right now). It is said, not fatal.
    "$LAUNCHCTL_BIN" unload "$SUPERVISOR_PLIST" >/dev/null 2>&1 \
        || say "launchctl unload of $SUPERVISOR_PLIST reported a failure — the job was most likely not loaded; loading it now"
    "$LAUNCHCTL_BIN" load "$SUPERVISOR_PLIST" >/dev/null 2>&1 \
        || die "$EX_UNREACHABLE" "step 'supervisor': '$SUPERVISOR_PLIST' has ALREADY been repointed at '$GATEWAY_LAUNCHER' and the launcher is written, but 'launchctl load' failed, so the agent is not yet running the new command. Load it by hand, or log out and back in."

    # DID THE ADOPTION ACTUALLY TAKE EFFECT?
    #
    # `launchctl load` exiting 0 means the job was submitted, not that the
    # gateway now serving is the one it started. The failure this catches is
    # ordinary and silent: a gateway started OUTSIDE launchd — a plain
    # `spawnctl start`, or the operator's own `gw start` — already holds the
    # port, so the supervised launcher cannot bind and gives up, while every
    # downstream check still passes because the UNSUPERVISED process answers
    # them. Setup then reports "adopted" and the machine reboots into a
    # different arrangement than the one it was told it had.
    #
    # The question is answered the same way spawnctl's `stop` answers it, out
    # of common.sh, because it is the same question. Asked with a bounded
    # retry: launchd takes a moment to fork the launcher, and the pidfile is
    # written by the launcher, not by us.
    adoption_verified=0
    adoption_detail=""
    adopt_pid=""
    adopt_try=0
    while [ "$adopt_try" -lt "$ADOPT_VERIFY_TRIES" ]; do
        adopt_pid="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
        if [ -n "$adopt_pid" ] && kill -0 "$adopt_pid" 2>/dev/null \
           && spawn::supervising_label "$adopt_pid"; then
            adoption_verified=1
            break
        fi
        adopt_try=$((adopt_try + 1))
        [ "$adopt_try" -lt "$ADOPT_VERIFY_TRIES" ] && sleep "$ADOPT_VERIFY_SLEEP"
    done
    if [ "$adoption_verified" -eq 1 ]; then
        say "verified: the gateway now serving (pid $adopt_pid) is supervised by the launchd job '$SUPERVISOR_LABEL'"
    else
        # NOT fatal, and deliberately so: the plist IS repointed and the
        # launcher IS written, so the next login gets the adopted arrangement.
        # What is wrong is only the CURRENT process. Failing here would leave
        # the operator with a correct configuration and an error, which reads
        # as "the adoption broke" when it did not. Reported loudly instead, in
        # the object as well as in prose.
        adoption_detail="the plist is repointed and the launcher is written, but the gateway serving RIGHT NOW is not the one launchd started (pid ${adopt_pid:-none} is not under a loaded job). Something started a gateway outside launchd and is holding the port, so the supervised launcher could not bind. Stop that process — note that spawnctl stop refuses on a supervised gateway, so this one is unsupervised and will stop normally — then run: launchctl unload '$SUPERVISOR_PLIST' && launchctl load '$SUPERVISOR_PLIST'. The next login would pick up the adopted arrangement regardless."
        say "WARNING: adoption is configured but NOT in effect — $adoption_detail"
    fi

    say "adopted the launchd agent at $SUPERVISOR_PLIST — it now starts the gateway through $GATEWAY_LAUNCHER, which reads the token from the Keychain at start. Setup now owns a step in this machine's startup path."
    # NO APOSTROPHE in the detail text below: it sits inside a single-quoted jq
    # program, and one would close the quote and break the script at parse time
    # — which is how every test in the supervisor suite went red at once, once.
    emit "$(jq -nc --arg p "$SUPERVISOR_PLIST" --arg l "$GATEWAY_LAUNCHER" --arg b "$bin" \
        --arg d "$LAUNCH_AGENTS_DIR" --arg i "$install" --argjson argv "$SUPERVISOR_ARGV" \
        --argjson xargv "$exec_argv" --argjson reb "$rebased" --arg from "$stale" \
        --argjson ver "$adoption_verified" --arg vd "$adoption_detail" \
        --arg vpid "${adopt_pid:-}" --arg vlabel "${SUPERVISOR_LABEL:-}" \
        '{ok:true, verb:"supervisor", action:"repointed", plist:$p, launcher:$l,
          program:$b, agents_dir:$d, install_dir:$i, original_program_arguments:$argv,
          program_arguments:$xargv,
          rebased:($reb == 1), rebased_from:(if $reb == 1 then $from else null end),
          detail:("the agent now starts the gateway through a launcher setup owns, which reads the token from the Keychain at start; no credential was written to the plist, and every other key in it is unchanged. SETUP NOW OWNS A STEP IN THE STARTUP PATH of this machine: the gateway starts through a file this plugin writes."
            + (if $reb == 1 then " REBASED: the agent named the install at \($from), which is not the install this run resolved, so the launcher now execs the resolved binary and config at \($i) — the agent follows the upgrade instead of starting the older build. The recorded original command still names what was first adopted." else "" end)),
          adoption_in_effect:($ver == 1),
          supervised_pid:(if $ver == 1 and $vpid != "" then ($vpid|tonumber) else null end),
          supervisor_label:(if $ver == 1 and $vlabel != "" then $vlabel else null end),
          adoption_warning:(if $ver == 1 then null else $vd end),
          error:null, exit_code:0}')" \
        || die "$EX_USAGE" "could not encode the supervisor object"
    exit "$EX_OK"
}

# ---------------------------------------------------------------------------
# Dispatch — lifted verbatim from setup.sh's case arm for this verb. Invoked
# with the verb still in $1 (setup.sh's shim and run_sub both pass argv
# through whole), so the original leading shift still applies.
# ---------------------------------------------------------------------------
shift
SUPERVISOR_INSTALL="${SPAWN_INSTALL_DIR:-}"
SUPERVISOR_CONSENT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --install-dir)
            shift
            [ $# -gt 0 ] || { need_jq; die "$EX_USAGE" "--install-dir needs a directory"; }
            SUPERVISOR_INSTALL="$1" ;;
        --consent-adopt-agent) SUPERVISOR_CONSENT=1 ;;
        *) need_jq; die "$EX_USAGE" "unexpected argument '$1'" ;;
    esac
    shift
done
need_jq
do_supervisor "$SUPERVISOR_CONSENT" "$SUPERVISOR_INSTALL"

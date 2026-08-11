#!/usr/bin/env bash
# setup-gw.sh — the `gw` verb: rewrite ~/.local/bin/gw as a Keychain-sourced, plugin-delegating wrapper (U5).
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

# say() comes from setup-lib.sh, sourced above — one definition of the
# printing chokepoint, not six.


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
    # ESCAPED BEFORE BAKING. This heredoc is deliberately unquoted so it can
    # bake absolute paths, and the result is written to ~/.local/bin/gw and
    # chmod 755 — an EXECUTED file. A path containing a double quote, a
    # backslash, a `$` or a backtick therefore either breaks the wrapper
    # syntactically or gets EXECUTED on every `gw` invocation. The path is
    # caller-influenced: SPAWN_SPAWNCTL_PATH is an env override, and the
    # derived value is a filesystem path.
    #
    # The identical hazard on the REPORTING side is already closed ~170 lines
    # below, where the warning JSON is built by jq rather than by hand. Same
    # variable, same class, and only one of the two halves was defended.
    #
    # Escaping the four bytes rather than using printf %q keeps an ordinary path
    # byte-identical to what previous versions generated, so a re-run rewrites
    # the same bytes instead of churning the file for no reason.
    #
    # An earlier version of this comment justified it as avoiding consent churn,
    # claiming a changed body would make every `gw` on disk read as hand-edited.
    # THAT WAS WRONG and is corrected here rather than left to mislead the next
    # reader: gw_classify compares a file's own declared hash against its own
    # body, so a wrapper written by an older setup is self-consistent and
    # rewrites freely. Verified both directions on a real machine. The escaping
    # is still the right call; the reason given for it was not.
    local ctl_esc="$SPAWNCTL_PATH"
    ctl_esc="${ctl_esc//\\/\\\\}"   # backslash first, or it re-escapes the others
    ctl_esc="${ctl_esc//\"/\\\"}"
    ctl_esc="${ctl_esc//\$/\\\$}"
    ctl_esc="${ctl_esc//\`/\\\`}"
    cat <<EOF
set -euo pipefail

# Baked at write time from the plugin's own location; a setup re-run re-bakes it.
SPAWNCTL="$ctl_esc"
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
    # BOTH names, matching launch.sh and the printed attach command. Setting
    # only ANTHROPIC_AUTH_TOKEN left an operator's REAL ANTHROPIC_API_KEY —
    # exported in a normal shell, which is the common case — inherited straight
    # into the child. Whichever name Claude Code prefers, this surface then
    # authenticated differently from every other one, and in the case where the
    # API key wins, the operator's real Anthropic credential is handed to a
    # local proxy that forwards upstream. Overriding both closes it.
    ANTHROPIC_BASE_URL="$base" ANTHROPIC_AUTH_TOKEN="$token" ANTHROPIC_API_KEY="$token" exec claude "$@"
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

    # The baked path is a git worktree with no copy in the main checkout, so it
    # will stop existing when that worktree is removed. Reported in the object
    # and not only in prose: setup's caller is usually an agent, and a warning
    # it cannot branch on is a warning it will not act on.
    # BUILT BY jq, NOT BY HAND. An earlier version of this assembled the JSON
    # string itself — `warn="\"...$SPAWNCTL_PATH...\""` passed to --argjson —
    # so a single `"` or `\` anywhere in the path produced invalid JSON and took
    # the whole emit down with it. That is the one failure mode this script
    # cannot afford: KTD2 says exactly one object on stdout ALWAYS, and a path
    # is caller-influenced data. The flag is a bash integer and the prose is an
    # --arg string; jq does the quoting, which is the doctrine everywhere else
    # in this plugin.
    local warn_on=0
    if [ "${SPAWNCTL_FROM_WORKTREE:-0}" -eq 1 ]; then
        warn_on=1
        say "WARNING: $GW_PATH now points into a git worktree — re-run setup from the permanent checkout after this branch lands, or gw breaks when the worktree is removed"
    fi
    emit "$(jq -nc --arg p "$GW_PATH" --arg s "$before" --arg ctl "$SPAWNCTL_PATH" \
        --argjson won "$warn_on" \
        --arg wtext "the delegation target baked into this wrapper lives in a git WORKTREE ($SPAWNCTL_PATH), which is expected to be deleted; when it is, gw will fail with exit 127 and nothing on the machine will explain why. Re-run setup from the permanent checkout once this branch has landed there." \
        '{ok:true, verb:"gw", action:(if $s == "absent" then "created" else "rewritten" end),
          path:$p, state_before:$s, spawnctl:$ctl,
          warning:(if $won == 1 then $wtext else null end), error:null, exit_code:0}')" \
        || die "$EX_USAGE" "could not encode the gw object"
    exit "$EX_OK"
}

# ---------------------------------------------------------------------------
# Dispatch — lifted verbatim from setup.sh's case arm for this verb. Invoked
# with the verb still in $1 (setup.sh's shim and run_sub both pass argv
# through whole), so the original leading shift still applies.
# ---------------------------------------------------------------------------
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

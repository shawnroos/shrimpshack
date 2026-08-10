#!/usr/bin/env bash
# setup-wire.sh — the `wire` verb: wire the installed harnesses — Claude Code's shell token snippet and Codex's managed config block (U6).
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

# ---------------------------------------------------------------------------
# Dispatch — lifted verbatim from setup.sh's case arm for this verb. Invoked
# with the verb still in $1 (setup.sh's shim and run_sub both pass argv
# through whole), so the original leading shift still applies.
# ---------------------------------------------------------------------------
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

#!/usr/bin/env bash
# setup.sh — the gateway plugin's setup path (plan U2 onward): the front
# door, the orchestrator, and the whole-path verify. The verbs live beside
# it and the dispatch below execs them:
#
#   setup.sh acquire      → setup-acquire.sh   fetch, build and promote the
#                                              latest gateway release
#   setup.sh gw           → setup-gw.sh        rewrite ~/.local/bin/gw as a
#                                              Keychain-sourced, plugin-
#                                              delegating wrapper (U5)
#   setup.sh supervisor   → setup-supervisor.sh adopt a supervising launchd
#                                              agent (U3 step 6)
#   setup.sh wire         → setup-wire.sh      wire the installed harnesses
#                                              (U6)
#   setup.sh (no verb)    the whole path (U7), run here
#
# The CONTRACT (exactly one JSON object on stdout, ALWAYS), the frozen
# exit-code enum and the staging rationale are stated once, in
# setup-lib.sh's header, and are unchanged by the split.
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

# Contract constants, restated. setup-lib.sh owns the canonical, commented
# definitions (byte-identical values); they are restated here because
# tests/unit/surfaces.bats derives the exit-code table in commands/setup.md
# from THIS file's `EX_*=<n>` definitions. The enum is frozen — a change
# here without the matching change in setup-lib.sh is a defect.
EX_OK=0
EX_USAGE=2
EX_UNREACHABLE=3
EX_CONSENT=8
EX_PREREQ=9

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
# (ORCHESTRATING's 0 default lives in setup-lib.sh — die() expands it under
# set -u, so every verb process needs the default before its first die.)
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
    # xtrace guard: this scope holds credential values in locals, and a
    # caller running under `bash -x` would otherwise trace every one of them
    # into whatever it redirects stderr to. `local -` scopes the shell options
    # to this function, so the caller's own -x is restored on return.
    local -
    set +x
    local url="$1" body="$2" tok="$3" work curlrc code rc
    RT_CODE=""
    work="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/spawn-rt.XXXXXX")" || return 1
    RT_WORK="$work"
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
            # STOP IT, do not merely report it. This branch used to end in a
            # die that told the operator to stop the gateway — while leaving it
            # running and, under a KeepAlive launchd agent, respawning. An open
            # proxy to a paid provider is precisely the thing not to leave up
            # while a human reads a message.
            #
            # Unload first: with the supervisor still loaded, stopping the
            # process only triggers a respawn. Both are best-effort and their
            # outcome is reported rather than assumed — refusing to claim a
            # stop that did not happen is the same rule spawnctl's own stop
            # follows.
            local shut=""
            if [ -n "${SUPERVISOR_PLIST:-}" ] && [ -f "${SUPERVISOR_PLIST:-}" ]; then
                if "$LAUNCHCTL_BIN" unload "$SUPERVISOR_PLIST" >/dev/null 2>&1; then
                    shut=" The supervising launchd agent at $SUPERVISOR_PLIST was unloaded so it cannot restart it."
                else
                    shut=" The supervising launchd agent at $SUPERVISOR_PLIST could NOT be unloaded — unload it by hand before anything else."
                fi
            fi
            if bash "$SPAWNCTL_PATH" stop >/dev/null 2>&1; then
                shut="$shut The gateway was stopped."
            else
                shut="$shut The gateway could NOT be stopped automatically — stop it by hand NOW."
            fi
            die "$EX_USAGE" "step 'verify': the gateway SERVED a request that presented no credential at all (POST /anthropic/v1/messages returned HTTP $RT_CODE) — that is an open proxy on this machine forwarding to a paid provider, which R9 forbids. Setup will not report success.$shut Make sure its $CONFIG_NAME declares no empty token list, and re-run."
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
# report this step needs anyway. The verb scripts are invoked by path relative
# to SCRIPT_DIR, so a mutated copy of this lib directory drives its own
# mutated verbs.
# ---------------------------------------------------------------------------
SUB_JSON=""
SUB_RC=0
run_sub() {   # run_sub <verb> [args...]
    local out
    out="$(mktemp "${TMPDIR:-/tmp}/spawn-sub.XXXXXX")" || return 1
    SUB_RC=0
    # stdout is captured (it is the child's one JSON object); stderr is left
    # alone so the child's progress lines reach the operator as they happen.
    bash "$SCRIPT_DIR/setup-$1.sh" "$@" >"$out" || SUB_RC=$?
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
    # The value passes through this function as an argument, so the guard has
    # to live HERE too: `local -` inside secrets.sh cannot suppress the CALLER's
    # trace of the invocation line, which carries the secret verbatim.
    local -
    set +x
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
    # Same reason as do_key_step: the generated token passes through here as an
    # argument, and the caller's xtrace would print the invocation line.
    local -
    set +x
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
    # xtrace guard: this scope holds credential values in locals, and a
    # caller running under `bash -x` would otherwise trace every one of them
    # into whatever it redirects stderr to. `local -` scopes the shell options
    # to this function, so the caller's own -x is restored on return.
    local -
    set +x
    local rotate_key="$1" rotate_token="$2" consent_gw="$3" consent_rc="$4" consent_agent="${5:-0}"
    # Restart is decided by what this run CHANGED about what the gateway would
    # load, not by which flags were passed. A rotation is one such change; so is
    # installing a new release, and so is retiring the token out of the live
    # config. Keying on the flags alone let the round-trip verify a
    # still-running OLD process while the success object named the new release.
    local needs_restart=0 base_url alias served tok start_verb

    ORCHESTRATING=1

    step_start "prereqs"
    need_prereqs
    step_done "prereqs" "ok" "curl, cargo and tar are all present"

    do_key_step "$rotate_key"
    [ "$rotate_key" -eq 1 ] && needs_restart=1
    do_token_step "$rotate_token"
    [ "$rotate_token" -eq 1 ] && needs_restart=1

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
            # A newly promoted binary and a freshly migrated config are only
            # proven by a process that actually loaded them.
            needs_restart=1
            record_change "gateway-install" "$SETUP_INSTALL_DIR" "gateway $SETUP_TAG was built and installed here"
            step_done "acquire" "installed" "built and promoted $SETUP_TAG" ;;
        *)
            # The skip path still retires the token out of the LIVE config when
            # it finds one, which changes what a running gateway would load.
            if [ "$(printf '%s' "$SUB_JSON" | jq -r '.token_retired // false' 2>/dev/null)" = "true" ]; then
                needs_restart=1
            fi
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

    # --- supervisor ---------------------------------------------------------
    # After gw, because both are control surfaces and this one outranks it: a
    # KeepAlive agent undoes a stop within seconds, so the wrapper's verbs are
    # only meaningful once the agent starts an authenticated gateway.
    step_start "supervisor"
    [ -n "$SETUP_INSTALL_DIR" ] \
        || die "$EX_USAGE" "step 'supervisor': the acquire step reported no install directory, so there is no binary to look for in the launchd agents; nothing was written"
    if [ "$consent_agent" -eq 1 ]; then
        run_sub supervisor --consent-adopt-agent --install-dir "$SETUP_INSTALL_DIR" \
            || die "$EX_USAGE" "step 'supervisor': could not run the supervisor step"
    else
        run_sub supervisor --install-dir "$SETUP_INSTALL_DIR" \
            || die "$EX_USAGE" "step 'supervisor': could not run the supervisor step"
    fi
    # Same shape as gw and wire: exit 8 from the child is the operator's
    # decision to make, so it is passed through with the steps and changes so
    # far rather than reported as a failure of the run.
    [ "$SUB_RC" -eq "$EX_CONSENT" ] && pass_consent "supervisor"
    [ "$SUB_RC" -eq 0 ] \
        || die "$SUB_RC" "step 'supervisor': $(printf '%s' "$SUB_JSON" | jq -r '.error // "the supervising launchd agent could not be adopted"' 2>/dev/null)"
    case "$(printf '%s' "$SUB_JSON" | jq -r '.action // empty' 2>/dev/null)" in
        repointed)
            local sv_plist sv_launcher sv_rebased sv_from sv_note=""
            sv_plist="$(printf '%s' "$SUB_JSON" | jq -r '.plist // empty' 2>/dev/null)"
            sv_launcher="$(printf '%s' "$SUB_JSON" | jq -r '.launcher // empty' 2>/dev/null)"
            sv_rebased="$(printf '%s' "$SUB_JSON" | jq -r '.rebased // false' 2>/dev/null)"
            sv_from="$(printf '%s' "$SUB_JSON" | jq -r '.rebased_from // empty' 2>/dev/null)"
            record_change "launcher" "$sv_launcher" \
                "a start-time launcher that reads the gateway token from the Keychain and execs the gateway; it carries no credential value"
            record_change "launch-agent" "$sv_plist" \
                "its ProgramArguments now name that launcher; every other key in the plist is unchanged and no credential was written into it"
            # An agent that was following a DIFFERENT install than the one this
            # run resolved is not a detail to absorb: until now it was starting
            # an older build, and the operator is entitled to be told which one.
            if [ "$sv_rebased" = "true" ]; then
                sv_note=" It was pointing at the install at $sv_from, and now follows the one this run resolved ($SETUP_INSTALL_DIR)."
                record_change "launch-agent-rebase" "$sv_plist" \
                    "the agent was still starting the gateway installed at $sv_from; the launcher now execs the binary and config in $SETUP_INSTALL_DIR, so the supervised gateway follows this upgrade. The recorded original command is unchanged."
            fi
            # The adopt path ALREADY restarted the gateway: do_supervisor runs
            # launchctl unload followed by load, and a KeepAlive agent brings
            # the gateway straight back up through the new launcher — on the
            # resolved install, with the current credentials. A `restart` after
            # that would stop a healthy supervised process and race the
            # supervisor to rebind the port, which is the surviving half of the
            # start-vs-supervisor race. Downgrading to `start` lets the start
            # step observe the running gateway instead of fighting it.
            needs_restart=0
            # KTD21's stated cost, in the report rather than absorbed.
            step_done "supervisor" "adopted" \
                "the launchd agent at $sv_plist now starts the gateway through $sv_launcher, so its own starts authenticate — which means SETUP NOW OWNS A STEP IN THIS MACHINE'S STARTUP PATH: the gateway starts through a file this plugin writes.$sv_note" ;;
        *)
            step_done "supervisor" "not-supervised" \
                "no launchd agent starts this gateway, so nothing was adopted and no plist was created — this step never creates one" ;;
    esac

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
    [ "$needs_restart" -eq 1 ] && start_verb="restart"
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
       setup.sh supervisor [--install-dir DIR] [--consent-adopt-agent]
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

  supervisor  adopt a launchd agent that already supervises this gateway: its
            ProgramArguments are repointed at a generated launcher that reads
            the token from the Keychain at start and execs the original command,
            so the agent's own starts authenticate. No credential is written to
            the plist and every other key in it survives. A machine with no such
            agent is reported not-supervised and nothing is written — this step
            adopts an agent, it never creates one. Adoption puts setup in this
            machine's startup path, so it is refused with exit 8 until
            --consent-adopt-agent is passed.

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
# Dispatch. The four verbs are thin shims: each execs its own script, which
# carries its own argument parsing — argv is passed through whole, verb
# included, so `setup.sh <verb> [flags]` behaves exactly as it always has.
# ---------------------------------------------------------------------------
case "$VERB" in
    acquire|gw|supervisor|wire)
        exec bash "$SCRIPT_DIR/setup-$VERB.sh" "$@"
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
        SETUP_CONSENT_AGENT=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --rotate-openrouter-key) ROTATE_KEY=1 ;;
                --rotate-gateway-token)  ROTATE_TOKEN=1 ;;
                --consent-overwrite-gw)  SETUP_CONSENT_GW=1 ;;
                --consent-shell-rc)      SETUP_CONSENT_RC=1 ;;
                --consent-adopt-agent)   SETUP_CONSENT_AGENT=1 ;;
                *) need_jq; die "$EX_USAGE" "unexpected argument '$1'" ;;
            esac
            shift
        done
        need_jq
        do_setup "$ROTATE_KEY" "$ROTATE_TOKEN" "$SETUP_CONSENT_GW" "$SETUP_CONSENT_RC" "$SETUP_CONSENT_AGENT"
        ;;
    *)
        usage
        need_jq
        die "$EX_USAGE" "unknown verb '${VERB:-}' (expected: acquire|gw|supervisor|wire, or no verb for the whole path)"
        ;;
esac

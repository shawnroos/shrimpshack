#!/usr/bin/env bash
# The binding store: which Linear issue a worktree is bound to, and in what state.
# Sourced, never executed.
#
# WHAT A BINDING IS KEYED ON (KTD4)
# The worktree's resolved real path AND the branch recorded at confirmation.
# Path alone is not identity: worktree names recur here by convention, so a
# recreated worktree would inherit a record still reading `bound` and ground the
# session in the previous work's issue. A record whose recorded branch no longer
# matches the path's current branch reads as `proposed`.
#
# WHAT THE NONCE DOES, AND WHAT IT DOES NOT
# `confirm` requires the nonce that `propose` generated and stored. That makes a
# confirmation impossible to reach except through a proposal that was actually
# written -- no accidental confirmation, no stale one, and no cross-session one
# where two sessions share a worktree.
#
# It is NOT an attendedness check, and must not be described as one. U1 proved
# no field separates an interactive session from a headless one: `claude -p`
# reports the same `source: startup` an interactive start reports. A headless
# session running the bind skill would call propose, receive the nonce, and call
# confirm. Nothing in this file can prevent that.
#
# R6 is therefore satisfied by a PAIR: this file guarantees confirm requires the
# current proposal's nonce; U7's skill guarantees the nonce reaches confirm only
# after a human answered a prompt. Neither half satisfies R6 alone, and claiming
# otherwise here would be a check narrower than its invariant.
#
# WHY READS DO NOT WRITE
# A branch mismatch reports an EFFECTIVE state rather than rewriting the record.
# Downgrading on read would make every read a lock-taking mutation, which turns
# grounding -- the hot path, run on every session start -- into a writer, and
# makes a read during a concurrent mutation block. The next mutation persists it.

# --------------------------------------------------------------- configuration

# ground.sh sources sanitize.sh AFTER this file: without this the call below is
# 127, which its `||` branch reads as a refusal.
command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::_py >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/record.sh"

HERDR_LINEAR_PIN_DIR="${HERDR_LINEAR_PIN_DIR:-$HOME/.claude/linear-pin}"

# ------------------------------------------------------------------ identity

# Verbatim from ~/.claude/hooks/linear-pin.sh:30-36, so a seed lookup finds what
# that hook actually wrote. Deriving it independently would silently find
# nothing, which is indistinguishable from "no pin exists".
# Note `--show-toplevel` in a worktree returns the WORKTREE's path, not the main
# repository's, and a detached HEAD has no branch and therefore no key.
herdr_linear::_pin_branch_key() {
    local cwd="$1" root branch
    root=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null) || return 1
    branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
    [ -n "$branch" ] || return 1
    printf '%s' "${root}#${branch}" | shasum | cut -c1-16
}

# Never fails. A directory that is not a repository at all still has to answer
# -- the consent reader runs from an unbound checkout, and under `set -e` a
# non-zero here would take the caller down with it.
herdr_linear::_current_branch() {
    git -C "$1" --no-optional-locks branch --show-current 2>/dev/null || true
}

herdr_linear::binding_key() {
    local resolved
    resolved="$(cd "${1:-}" 2>/dev/null && pwd -P)" || return 1
    printf '%s' "$resolved" | shasum | cut -c1-16
}

herdr_linear::_record_path() {
    local key
    key="$(herdr_linear::binding_key "$1")" || return 1
    printf '%s/bindings/%s.json' "$HERDR_LINEAR_STORE_DIR" "$key"
}

# ------------------------------------------------------------- public read path

# herdr_linear::binding_read <worktree>
# Prints the record as JSON with `state` replaced by the EFFECTIVE state. Never
# writes, never locks.
# herdr_linear::bindings_effective
# One `file US identifier US worktree_path US tab US state` line per binding
# record in the store, with the state binding_read reports, or
# `worktree_missing` when the worktree directory is gone. Records the loader
# refuses, and rows carrying US or a newline, are left out.
herdr_linear::bindings_effective() {
    herdr_linear::_py list-effective "$HERDR_LINEAR_STORE_DIR"
}

herdr_linear::binding_read() {
    local wt="${1:-}" rec f branch recorded state
    f="$(herdr_linear::_record_path "$wt")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_mode_ok "$f" || return "$HERDR_LINEAR_BINDING_ABSENT"
    rec="$(herdr_linear::_py read "$f")" || return "$HERDR_LINEAR_BINDING_ABSENT"

    state="$(printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])' 2>/dev/null)"
    if [ "$state" = "bound" ]; then
        recorded="$(printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("branch_at_confirmation",""))' 2>/dev/null)"
        branch="$(herdr_linear::_current_branch "$wt")"
        if [ "$recorded" != "$branch" ]; then
            rec="$(printf '%s' "$rec" | python3 -c 'import sys,json;d=json.load(sys.stdin);d["state"]="proposed";d["downgraded_from_bound"]=True;print(json.dumps(d))')"
        fi
    fi
    printf '%s' "$rec"
    return "$HERDR_LINEAR_BINDING_OK"
}

herdr_linear::binding_state() {
    local rec
    rec="$(herdr_linear::binding_read "$1")" || { printf 'unbound'; return "$HERDR_LINEAR_BINDING_ABSENT"; }
    printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])' 2>/dev/null
}

herdr_linear::binding_identifier() {
    local rec id
    rec="$(herdr_linear::binding_read "$1")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    id="$(printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("issue_identifier",""))' 2>/dev/null)"
    # A proposed record has no identifier yet; that is absent, not hostile, and
    # callers distinguish the two.
    [ -n "$id" ] || return "$HERDR_LINEAR_BINDING_ABSENT"
    # A record written before this guard existed, or edited by anything that can
    # reach the store, is untrusted at read time too.
    herdr_linear::is_safe_identifier "$id" || return "$HERDR_LINEAR_BINDING_REFUSED"
    printf '%s' "$id"
}

# The pin store is a SEED and is never written. It holds a bare identifier with
# no room for proposed, declined or stale, so what it yields is a candidate for
# a proposal -- never a binding.
herdr_linear::binding_seed_candidate() {
    local wt="${1:-}" key f id
    key="$(herdr_linear::_pin_branch_key "$wt")" || return 1
    f="$HERDR_LINEAR_PIN_DIR/branch/$key"
    [ -r "$f" ] || return 1
    id="$(cat "$f" 2>/dev/null)"
    printf '%s' "$id" | grep -qE '^[A-Z][A-Z0-9]{1,7}-[0-9]{1,6}$' || return 1
    printf '%s' "$id"
}

# ---------------------------------------------------------- public write path

herdr_linear::_mutate() {
    local wt="$1"; shift
    local f
    herdr_linear::_ensure_store || return "$HERDR_LINEAR_BINDING_ABSENT"
    f="$(herdr_linear::_record_path "$wt")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_mutate_at "$f" "$@"
}

herdr_linear::binding_propose() {
    local wt="${1:-}" id="${2:-}"
    [ -n "$wt" ] && [ -n "$id" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    # The record is a delivery channel: what is written here comes back out of
    # binding_identifier and becomes a path segment downstream.
    herdr_linear::is_safe_identifier "$id" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate "$wt" propose "$(cd "$wt" && pwd -P)" "$id"
}

# The nonce is the whole gate. See the header: it orders confirm after propose,
# and it is NOT a proof that a human answered.
herdr_linear::binding_confirm() {
    local wt="${1:-}" id="${2:-}" nonce="${3:-}" branch
    [ -n "$wt" ] && [ -n "$id" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::is_safe_identifier "$id" || return "$HERDR_LINEAR_BINDING_REFUSED"
    branch="$(herdr_linear::_current_branch "$wt")"
    herdr_linear::_mutate "$wt" confirm "$id" "$nonce" "$branch"
}

herdr_linear::binding_decline()       { herdr_linear::_mutate "${1:-}" decline "${2:-}"; }
herdr_linear::binding_set_state()     { herdr_linear::_mutate "${1:-}" set-state "${2:-}"; }
herdr_linear::binding_add_child() {
    herdr_linear::is_safe_identifier "${2:-}" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate "${1:-}" add-child "$2"
}
herdr_linear::binding_add_document()  { herdr_linear::_mutate "${1:-}" add-document "${2:-}" "${3:-}"; }
herdr_linear::binding_set_desc_head() { herdr_linear::_mutate "${1:-}" set-description-head "${2:-}"; }
herdr_linear::binding_desc_head() {
    local rec
    rec="$(herdr_linear::binding_read "${1:-}")" || return 1
    printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("description_head",""))' 2>/dev/null
}
herdr_linear::binding_document_for()  { herdr_linear::_mutate "${1:-}" document-id-for "${2:-}"; }
herdr_linear::binding_owns_document() { herdr_linear::_mutate "${1:-}" owns-document "${2:-}"; }
herdr_linear::binding_set_judgment()  { herdr_linear::_mutate "${1:-}" set-judgment "${2:-}"; }
herdr_linear::binding_clear_judgment(){ herdr_linear::_mutate "${1:-}" clear-judgment; }

# Prints the pending judgment once per session, then not again for that session.
herdr_linear::binding_take_judgment() {
    herdr_linear::_mutate "${1:-}" take-judgment "${2:-${CLAUDE_SESSION_ID:-}}"
}

# ------------------------------------------------------------ write consent
#
# KTD1. Consent shares ONE mechanism with the binding: the path-hash key. It
# carries its own team, project and branch, and the reader compares all three
# itself. It cannot ride on `branch_at_confirmation`, which is compared only
# when the state is `bound`, is rewritten by every confirm including the
# no-human pairs in start.sh and create.sh, and is empty for the unbound
# checkout R9 has to cover.
#
# The reader requires no binding at all: `start_new` and `new_project` run from
# a checkout that has none.

# herdr_linear::has_consent <dir> -> 0 when an answer is RECORDED here.
# Presence, asked separately from value: the store reads through `_py field`,
# which prints an empty string for an absent key and for a null one alike.
herdr_linear::has_consent() {
    local f
    f="$(herdr_linear::_record_path "${1:-}")" || return 1
    herdr_linear::_mode_ok "$f" || return 1
    herdr_linear::_py has-consent "$f"
}

# herdr_linear::consent_ok <dir> <team> [project] -> 0 when the recorded answer
# covers this write. Never writes, never locks -- it is on the path of every
# mutation, and a read that takes the lock blocks during one.
herdr_linear::consent_ok() {
    local dir="${1:-}" team="${2:-}" project="${3:-}" f branch
    [ -n "$team" ] || return 1
    f="$(herdr_linear::_record_path "$dir")" || return 1
    herdr_linear::_mode_ok "$f" || return 1
    branch="$(herdr_linear::_current_branch "$dir")"
    herdr_linear::_py consent-ok "$f" "$team" "$project" "$branch"
}

# The write half. KTD2: `consent_confirm` has exactly one class of caller -- the
# ask-and-record fence in a write skill, every one of which is
# disable-model-invocation. Nothing under lib/, hooks/ or commands/ may call it.
herdr_linear::consent_propose() {
    local dir="${1:-}" team="${2:-}" project="${3:-}" resolved
    [ -n "$dir" ] && [ -n "$team" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    resolved="$(cd "$dir" 2>/dev/null && pwd -P)" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate "$dir" consent-propose "$resolved" "$team" "$project"
}

herdr_linear::consent_confirm() {
    local dir="${1:-}" team="${2:-}" project="${3:-}" nonce="${4:-}" branch
    [ -n "$dir" ] && [ -n "$team" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    branch="$(herdr_linear::_current_branch "$dir")"
    herdr_linear::_mutate "$dir" consent-confirm "$team" "$project" "$branch" "$nonce"
}

# R9a. What a run with nobody to ask would have written, kept where the next
# session can find it -- and NOT in the judgment slot, which holds one thing.
herdr_linear::binding_set_pending_consent() {
    herdr_linear::_mutate "${1:-}" set-pending-consent "${2:-}"
}

herdr_linear::binding_pending_consent() {
    local f
    f="$(herdr_linear::_record_path "${1:-}")" || return 1
    herdr_linear::_mode_ok "$f" || return 1
    herdr_linear::_py pending-consent "$f"
}

# KTD28. The tab a ticket owns, on that ticket's own binding. A tab's label is
# prose; this record is the only thing that says which tab is the ticket's.
herdr_linear::binding_set_tab() { herdr_linear::_mutate "${1:-}" set-tab "${2:-}"; }

herdr_linear::binding_tab() {
    local f
    f="$(herdr_linear::_record_path "${1:-}")" || return 1
    herdr_linear::_mode_ok "$f" || return 1
    herdr_linear::_py field "$f" tab
}

# KTD29. A placement question nobody was there to answer, kept for the next
# session start. An empty text clears it.
herdr_linear::binding_set_pending_placement() {
    herdr_linear::_mutate "${1:-}" set-pending-placement "${2:-}"
}

herdr_linear::binding_pending_placement() {
    local f
    f="$(herdr_linear::_record_path "${1:-}")" || return 1
    herdr_linear::_mode_ok "$f" || return 1
    herdr_linear::_py pending-placement "$f"
}

# The answer to no, and symmetric with confirm in both halves of the rule. KTD2
# governs who may call it -- a decline is a person's answer, so nothing under
# lib/, hooks/ or commands/ may -- and the nonce governs what it may answer.
herdr_linear::consent_decline() {
    local dir="${1:-}" team="${2:-}" project="${3:-}" nonce="${4:-}"
    [ -n "$dir" ] && [ -n "$team" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate "$dir" consent-decline "$team" "$project" "$nonce"
}

HERDR_LINEAR_SHADOW_LOG="${HERDR_LINEAR_SHADOW_LOG:-$HOME/.claude/work/shadow.log}"

herdr_linear::_shadow_log() {
    mkdir -p "$(dirname "$HERDR_LINEAR_SHADOW_LOG")" 2>/dev/null
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$HERDR_LINEAR_SHADOW_LOG"
}

# herdr_linear::consent_gate <dir> <team> <project> <what> [detail]
#   0  the recorded answer covers this write; proceed
#   1  it does not; the skip is logged and recorded, and the caller returns its
#      own shadow code
#
# The record is written on EVERY path, not just the hook's. No verb here can
# tell whether a person is watching -- all six are reachable from a subagent, a
# headless run, or another plugin sourcing lib/ -- and the costs are asymmetric:
# over-recording costs one line in one session, and only while the write still
# has not happened, while under-recording drops a write silently in exactly the
# unattended case R9a exists for.
herdr_linear::consent_gate() {
    local dir="${1:-}" team="${2:-}" project="${3:-}" what="${4:-}" detail="${5:-}"
    herdr_linear::consent_ok "$dir" "$team" "$project" && return 0
    herdr_linear::_shadow_log "SHADOW would $what${detail:+ $detail}"
    # A locked or unreadable store must not turn a refusal into a proceed.
    herdr_linear::binding_set_pending_consent "$dir" \
        "Nothing here has answered the write question yet, so this did not happen: $what. Run /work:describe or /work:new from this worktree to answer it; answering no clears this notice." \
        || true
    return 1
}

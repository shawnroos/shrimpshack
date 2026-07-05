#!/usr/bin/env bash
#
# spinoff.sh — fork the current workstream into a fresh worktree + a new cmux
# tab running a briefed Claude session. Driven by the spinoff skill.
#
# Mechanical only: the CALLER (Claude) supplies a synthesized handoff doc. This
# script handles worktree creation, env bootstrap, handoff finalization, doc
# carry-over, and cmux tab + Claude launch.
#
# Safe to read top-to-bottom before running. Prints each step. Never `git add -A`.

set -uo pipefail

step() { echo "▸ $*"; }
die()  { echo "✗ $*" >&2; exit 1; }
# Make a path absolute against the CURRENT cwd. Used to pin relative file args
# (handoff, transcript) BEFORE a `--repo` cd changes cwd out from under them —
# they're read later (post-cd), so a relative path would otherwise be lost.
abspath() { case "$1" in ""|/*) printf '%s' "$1" ;; *) printf '%s/%s' "$(pwd -P)" "$1" ;; esac; }

# ---- launcher seam (KTD-1 / KTD-2) ------------------------------------------
# The launch region near the bottom is backend-neutral: it calls launcher_*
# verbs that dispatch on the resolved $LAUNCHER. cmux is the only implemented
# backend today — its *_cmux verbs issue byte-identical CLI calls to the pre-seam
# script (a herdr-absent run behaves exactly as before). herdr verbs are stubs
# that later units (U3/U4) fill in. LAUNCHER=none reproduces today's
# "not inside cmux" manual-line fallback.

# Liveness probes. herdr: the binary resolves AND `status server` reports running
# (a stale HERDR_ENV=1 must not win — R8). cmux: the binary is executable.
_herdr_probe() { [ -n "${HERDR:-}" ] && "$HERDR" status server 2>/dev/null | grep -qi 'running'; }
_cmux_probe()  { [ -n "${CMUX:-}" ] && [ -x "$CMUX" ]; }

# resolve_launcher — collapse env + flag into a single $LAUNCHER (KTD-2).
# Precedence for `auto`: herdr (live) > cmux > none. A forced --launcher
# herdr|cmux skips the env-keyed detection but STILL probes the chosen backend,
# falling back to auto-detection (never hard-erroring) on probe failure (R8).
resolve_launcher() {
  case "$LAUNCHER" in
    herdr) if _herdr_probe; then LAUNCHER=herdr; return; fi
           echo "  ⚠ --launcher herdr requested but the herdr server isn't reachable — falling back to auto-detection" >&2 ;;
    cmux)  if _cmux_probe; then LAUNCHER=cmux; return; fi
           echo "  ⚠ --launcher cmux requested but the cmux CLI isn't available — falling back to auto-detection" >&2 ;;
  esac
  if   [ "${HERDR_ENV:-}" = 1 ] && _herdr_probe;          then LAUNCHER=herdr
  elif [ -n "${CMUX_WORKSPACE_ID:-}" ] && _cmux_probe;    then LAUNCHER=cmux
  else                                                         LAUNCHER=none
  fi
}

# --- neutral verb dispatchers (case-on-$LAUNCHER, KTD-1) ----------------------
launcher_new_tab()        { case "$LAUNCHER" in cmux) launcher_new_tab_cmux ;;        herdr) launcher_new_tab_herdr ;; esac; }
launcher_new_workspace()  { case "$LAUNCHER" in cmux) launcher_new_workspace_cmux ;;  herdr) launcher_new_workspace_herdr ;; esac; }
launcher_find_left_pane() { case "$LAUNCHER" in cmux) launcher_find_left_pane_cmux ;; herdr) launcher_find_left_pane_herdr ;; esac; }
launcher_launch_agent()   { case "$LAUNCHER" in cmux) launcher_launch_agent_cmux ;;   herdr) launcher_launch_agent_herdr ;; esac; }
launcher_wait_ready()     { case "$LAUNCHER" in cmux) launcher_wait_ready_cmux ;;     herdr) launcher_wait_ready_herdr ;; esac; }
launcher_send_kickoff()   { case "$LAUNCHER" in cmux) launcher_send_kickoff_cmux ;;   herdr) launcher_send_kickoff_herdr ;; esac; }
launcher_open_viewer()    { case "$LAUNCHER" in cmux) launcher_open_viewer_cmux ;;    herdr) launcher_open_viewer_herdr ;; esac; }

# --- cmux backend (BEHAVIOR-PRESERVING: exact pre-seam CLI calls) -------------
# Identify the left-hand agent pane: the lowest-indexed pane in this workspace
# that holds terminal surfaces (the markdown/browser pane is the other one).
launcher_find_left_pane_cmux() {
  LEFT_PANE="$("$CMUX" tree --workspace "$WS" 2>/dev/null \
    | awk '/pane / { for(i=1;i<=NF;i++) if($i ~ /^pane:/){p=$i} }
           /surface .*\[terminal\]/ && p { print p; exit }')"
}

# Tab: new surface on the current workspace's left agent pane. Sets SURFACE_REF
# and the LAUNCH_* refs the later verbs consume.
launcher_new_tab_cmux() {
  step "opening cmux tab on the left agent surface…"
  WS="$CMUX_WORKSPACE_ID"
  launcher_find_left_pane_cmux
  CREATE_ARGS=(--type terminal --workspace "$WS" --focus true)
  if [ -n "$LEFT_PANE" ]; then
    CREATE_ARGS=(--type terminal --pane "$LEFT_PANE" --workspace "$WS" --focus true)
    step "  left agent pane: $LEFT_PANE"
  else
    step "  ⚠ no terminal pane identified — using focused pane"
  fi
  # Create the surface; capture its ref from output.
  CREATE_OUT="$("$CMUX" new-surface "${CREATE_ARGS[@]}" 2>&1)"
  SURFACE_REF="$(echo "$CREATE_OUT" | grep -oE 'surface:[0-9]+' | head -1)"
  if [ -z "$SURFACE_REF" ]; then
    echo "  ⚠ could not parse new surface ref; cmux output was:" >&2
    echo "$CREATE_OUT" >&2
  fi
  LAUNCH_WS="$WS"; LAUNCH_SFC="$SURFACE_REF"; LAUNCH_LABEL="new surface"; LAUNCH_WHERE="tab"
}

# New workspace: create it UNFOCUSED, find its terminal surface (poll — it may
# not be registered the instant new-workspace returns), THEN switch the user in
# so a discovery failure never strands them in an empty focused workspace.
launcher_new_workspace_cmux() {
  step "creating a new cmux workspace…"
  WS_OUT="$("$CMUX" new-workspace --name "$LABEL" --cwd "$WORKTREE" --focus false 2>&1)"
  WORKSPACE_REF="$(echo "$WS_OUT" | grep -oE 'workspace:[0-9]+' | head -1)"
  if [ -z "$WORKSPACE_REF" ]; then
    echo "  ⚠ could not parse new workspace ref; cmux output was:" >&2
    echo "$WS_OUT" >&2
    LAUNCH_WS=""; LAUNCH_SFC=""; return
  fi
  step "  new workspace: $WORKSPACE_REF"
  SURFACE_REF=""
  for _ in $(seq 1 20); do
    SURFACE_REF="$("$CMUX" tree --workspace "$WORKSPACE_REF" 2>/dev/null \
      | awk '/surface .*\[terminal\]/ { for(i=1;i<=NF;i++) if($i ~ /^surface:/){print $i; exit} }')"
    [ -n "$SURFACE_REF" ] && break
    sleep 0.5
  done
  if [ -z "$SURFACE_REF" ]; then
    echo "  ⚠ no terminal surface found in the new workspace — skipping launch" >&2
    LAUNCH_WS="$WORKSPACE_REF"; LAUNCH_SFC=""; return
  fi
  # Surface exists — now safe to switch the user into the new workspace.
  "$CMUX" select-workspace --workspace "$WORKSPACE_REF" >/dev/null 2>&1
  LAUNCH_WS="$WORKSPACE_REF"; LAUNCH_SFC="$SURFACE_REF"; LAUNCH_LABEL="agent surface"; LAUNCH_WHERE="workspace"
}

# Rename the tab, launch Claude in the worktree, submit. --title (not a bare
# positional) so a $LABEL starting with '-' can't be misparsed as a flag.
launcher_launch_agent_cmux() {
  LB_READY=0
  "$CMUX" rename-tab --surface "$LAUNCH_SFC" --workspace "$LAUNCH_WS" --title "$LABEL" >/dev/null 2>&1
  "$CMUX" send --surface "$LAUNCH_SFC" --workspace "$LAUNCH_WS" "$LAUNCH_CMD" >/dev/null 2>&1
  "$CMUX" send-key --surface "$LAUNCH_SFC" --workspace "$LAUNCH_WS" enter >/dev/null 2>&1
}

# Wait for the input prompt to be ready (a fixed sleep is unreliable — a fresh
# claude can spend seconds loading MCP servers, and an Enter sent too early is
# swallowed). Sets LB_READY=1 on confirmed ready.
launcher_wait_ready_cmux() {
  local screen
  for _ in $(seq 1 30); do
    sleep 1
    screen="$("$CMUX" read-screen --surface "$LAUNCH_SFC" --workspace "$LAUNCH_WS" 2>/dev/null)"
    case "$screen" in
      *"❯"*|*"bypass permissions"*|*"shift+tab to cycle"*) LB_READY=1; break ;;
    esac
  done
}

# Send + submit the kickoff, then verify it actually submitted (input line should
# no longer hold it); retry one Enter if it's still sitting there. Reports
# readiness honestly using the LAUNCH_LABEL / LAUNCH_WHERE set by new_tab/new_workspace.
launcher_send_kickoff_cmux() {
  local after
  "$CMUX" send --surface "$LAUNCH_SFC" --workspace "$LAUNCH_WS" "$KICKOFF" >/dev/null 2>&1
  sleep 1
  "$CMUX" send-key --surface "$LAUNCH_SFC" --workspace "$LAUNCH_WS" enter >/dev/null 2>&1
  sleep 2
  after="$("$CMUX" read-screen --surface "$LAUNCH_SFC" --workspace "$LAUNCH_WS" 2>/dev/null)"
  case "$after" in
    *"Read docs/handoff.md"*)
      # Still sitting on the input line un-submitted → retry one Enter.
      "$CMUX" send-key --surface "$LAUNCH_SFC" --workspace "$LAUNCH_WS" enter >/dev/null 2>&1 ;;
  esac
  if [ "$LB_READY" = "1" ]; then
    step "  $LAUNCH_LABEL: $LAUNCH_SFC (Claude ready, briefed)"
  else
    step "  $LAUNCH_LABEL: $LAUNCH_SFC (Claude launched; readiness not confirmed — check the $LAUNCH_WHERE)"
  fi
}

# Right pane (workspace target only): render the handoff in cmux's live-reload
# markdown viewer. Best-effort — sets VIEWER_OK=1 only when it actually renders.
launcher_open_viewer_cmux() {
  local PANE_OUT RIGHT_PANE
  PANE_OUT="$("$CMUX" new-pane --type terminal --direction right --workspace "$LAUNCH_WS" --focus false 2>&1)"
  RIGHT_PANE="$(echo "$PANE_OUT" | grep -oE 'pane:[0-9]+' | head -1)"
  if [ -n "$RIGHT_PANE" ]; then
    if "$CMUX" open "$HANDOFF_DST" --pane "$RIGHT_PANE" --workspace "$LAUNCH_WS" --no-focus >/dev/null 2>&1; then
      VIEWER_OK=1
      step "  handoff viewer: $RIGHT_PANE"
    else
      echo "  ⚠ opened right pane but could not render the handoff viewer" >&2
    fi
  else
    echo "  ⚠ could not create right pane for handoff viewer; cmux output was:" >&2
    echo "$PANE_OUT" >&2
  fi
}

# --- herdr backend -----------------------------------------------------------
# Signatures below are the LIVE-VERIFIED herdr 0.7.1 invocations from the plan's
# ## Spike Findings (U1) — do not re-guess flags against group help.
_launcher_herdr_todo() { HERDR_NOTE="herdr backend not yet implemented (${1:-launch}) — later units wire this"; step "  ⚠ $HERDR_NOTE"; }

# Extract a dotted field (e.g. result.agent.pane_id) from herdr JSON on stdin.
# jq when present (Spike Findings), python3 as the guaranteed-portable fallback.
_herdr_json() {
  local path="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r ".$path // empty" 2>/dev/null
  else
    JPATH="$path" python3 -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
    for k in os.environ["JPATH"].split("."):
        d = d[k]
    sys.stdout.write("" if d is None else str(d))
except Exception:
    sys.stdout.write("")
' 2>/dev/null
  fi
}

# Pick the first pane id from `herdr pane list --workspace` JSON on stdin — the
# new workspace's root terminal pane (used only to confirm the workspace
# materialized before we switch the user in). jq when present, python3 fallback.
_herdr_first_pane() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.result.panes[0].pane_id // empty' 2>/dev/null
  else
    python3 -c '
import sys, json
try:
    print(json.load(sys.stdin)["result"]["panes"][0]["pane_id"])
except Exception:
    pass
' 2>/dev/null
  fi
}

# Tab target: unlike cmux (create a surface, THEN send `claude`), herdr's
# `agent start` both creates the tab/pane and execs claude in one call (Spike
# Findings (b)), so there is no surface to pre-create here. Resolve the workspace
# to launch into and mark the precondition met (LAUNCH_SFC non-empty) so the
# shared launch guard proceeds; launcher_launch_agent_herdr replaces LAUNCH_SFC
# with the real pane id it captures.
launcher_new_tab_herdr() {
  step "opening a herdr agent tab…"
  local ws="${HERDR_WORKSPACE_ID:-}"
  if [ -z "$ws" ]; then
    echo "  ⚠ HERDR_WORKSPACE_ID is not set — cannot resolve a herdr workspace to launch into" >&2
    LAUNCH_WS=""; LAUNCH_SFC=""; return
  fi
  LAUNCH_WS="$ws"
  LAUNCH_SFC="pending"        # sentinel: real pane id set by launcher_launch_agent_herdr
  LAUNCH_LABEL="agent tab"; LAUNCH_WHERE="tab"
  step "  target workspace: $ws"
}

# Workspace target: create a brand-new herdr workspace, then let the shared
# launch region brief the agent into it via the U3 verbs. Mirrors the cmux
# workspace block's ordering (Spike Findings (f)): create UNFOCUSED → confirm a
# terminal pane materialized (poll `pane list`) → only THEN focus the user in, so
# a discovery failure never strands them in an empty focused workspace. Sets
# WORKSPACE_REF (summary) + LAUNCH_WS (the workspace agent start launches into);
# LAUNCH_SFC is a sentinel the agent-launch verb replaces with the real pane id.
launcher_new_workspace_herdr() {
  step "creating a new herdr workspace…"
  local out ws pane
  out="$("$HERDR" workspace create --cwd "$WORKTREE" --label "$LABEL" --no-focus 2>/dev/null)"
  ws="$(printf '%s' "$out" | _herdr_json 'result.workspace.workspace_id')"
  if [ -z "$ws" ]; then
    echo "  ⚠ could not capture the herdr workspace id; workspace create output was:" >&2
    echo "$out" >&2
    LAUNCH_WS=""; LAUNCH_SFC=""; return
  fi
  WORKSPACE_REF="$ws"; LAUNCH_WS="$ws"
  step "  new workspace: $ws"
  # Confirm the workspace has a terminal pane before switching the user in (the
  # pane may not register the instant `workspace create` returns — poll, same as
  # the cmux surface poll).
  pane=""
  for _ in $(seq 1 20); do
    pane="$("$HERDR" pane list --workspace "$ws" 2>/dev/null | _herdr_first_pane)"
    [ -n "$pane" ] && break
    sleep 0.5
  done
  if [ -z "$pane" ]; then
    echo "  ⚠ no terminal pane found in the new herdr workspace — skipping launch" >&2
    LAUNCH_SFC=""; return
  fi
  LEFT_PANE="$pane"           # root pane; agent start splits its OWN pane (Spike (b))
  LAUNCH_SFC="pending"        # sentinel: real agent pane set by launcher_launch_agent_herdr
  LAUNCH_LABEL="agent surface"; LAUNCH_WHERE="workspace"
  # Pane exists — now safe to switch the user into the new workspace (best-effort;
  # a focus failure must never fail the launch).
  "$HERDR" workspace focus "$ws" >/dev/null 2>&1 || true
}

launcher_find_left_pane_herdr() { _launcher_herdr_todo find_left_pane; }

# Launch claude in the worktree via `agent start`, capturing the pane id the
# later verbs (wait/send/read) consume. KTD-8: direct `-- claude` exec by default
# (spike verified claude resolves on herdr's inherited PATH); a `$SHELL -lc` login
# wrap is the guarded fallback for an env where claude isn't on that PATH.
launcher_launch_agent_herdr() {
  LB_READY=0
  local out pane
  if command -v claude >/dev/null 2>&1; then
    out="$("$HERDR" agent start "$LABEL" --cwd "$WORKTREE" --workspace "$LAUNCH_WS" --no-focus \
             -- claude --name "$LABEL" 2>/dev/null)"
  else
    out="$("$HERDR" agent start "$LABEL" --cwd "$WORKTREE" --workspace "$LAUNCH_WS" --no-focus \
             -- "$SHELL" -lc "claude --name '$LABEL'" 2>/dev/null)"
  fi
  pane="$(printf '%s' "$out" | _herdr_json 'result.agent.pane_id')"
  if [ -z "$pane" ]; then
    echo "  ⚠ could not capture the herdr agent pane id; agent start output was:" >&2
    echo "$out" >&2
    HERDR_PANE=""; LAUNCH_SFC=""; SURFACE_REF=""; return
  fi
  HERDR_PANE="$pane"; LAUNCH_SFC="$pane"; SURFACE_REF="$pane"
  step "  herdr agent pane: $pane"
}

# Block on herdr's first-class readiness wait (Spike Findings (c): `agent wait
# --status idle` fires reliably for a fresh claude — the 30× read-screen poll is
# NOT on the herdr path). Sets LB_READY=1 on confirmed idle, 0 on timeout.
launcher_wait_ready_herdr() {
  LB_READY=0
  [ -n "${HERDR_PANE:-}" ] || return
  if "$HERDR" agent wait "$HERDR_PANE" --status idle --timeout 30000 >/dev/null 2>&1; then
    LB_READY=1
  fi
}

# Fire the kickoff with EXACTLY ONE submit (KTD-4 / R7): `agent send` STAGES the
# literal text (does NOT press Enter), then a single `pane send-keys … Enter`
# submits. This stage-only behavior of `agent send` was verified LIVE against
# herdr 0.7.1 twice (U1 spike + a standalone probe on 2026-07-05: sent text to a
# `read`-blocked pane with no Enter → the read did NOT complete), overriding older
# lore that `agent send` auto-submits. Safety net (adapted from the cmux path): if
# a read shows the kickoff still staged, retry one Enter — never a second send.
launcher_send_kickoff_herdr() {
  local after
  [ -n "${HERDR_PANE:-}" ] || return
  "$HERDR" agent send "$HERDR_PANE" "$KICKOFF" >/dev/null 2>&1     # stage literal text
  "$HERDR" pane send-keys "$HERDR_PANE" Enter >/dev/null 2>&1      # single submit
  sleep 2
  after="$("$HERDR" pane read "$HERDR_PANE" --source recent --lines 20 2>/dev/null | _herdr_json 'result.read.text')"
  case "$after" in
    *"Read docs/handoff.md"*)
      # Still staged on the input line → retry one Enter (no extra `agent send`).
      "$HERDR" pane send-keys "$HERDR_PANE" Enter >/dev/null 2>&1 ;;
  esac
  if [ "$LB_READY" = "1" ]; then
    step "  $LAUNCH_LABEL: $HERDR_PANE (Claude ready, briefed)"
  else
    step "  $LAUNCH_LABEL: $HERDR_PANE (Claude launched; readiness not confirmed — check the $LAUNCH_WHERE)"
  fi
}

# Right-pane handoff viewer (workspace target only). herdr has NO native markdown
# viewer (Spike Findings (d)), so: split a right pane off the agent pane and render
# the handoff statically with a pager (glow, then bat). BEST-EFFORT — VIEWER_OK=1
# only when a pager actually renders; a missing pager / failed split leaves
# VIEWER_OK=0 and the launch STILL succeeds (R5 / KTD-6). Also closes the leftover
# root shell `agent start` orphaned (Spike (b): `agent start --workspace` splits a
# fresh pane and leaves the workspace's original root pane a bare idle shell) so the
# workspace ends up a clean agent-left / viewer-right pair (parity with cmux).
launcher_open_viewer_herdr() {
  local split view
  local left="${HERDR_PANE:-}"
  [ -n "$left" ] || return    # agent launch produced no pane → nothing to view against
  if [ -n "${LEFT_PANE:-}" ] && [ "$LEFT_PANE" != "$left" ]; then
    "$HERDR" pane close "$LEFT_PANE" >/dev/null 2>&1 || true   # drop the orphan root shell
  fi
  split="$("$HERDR" pane split "$left" --direction right --no-focus 2>/dev/null)"
  view="$(printf '%s' "$split" | _herdr_json 'result.pane.pane_id')"
  if [ -z "$view" ]; then
    echo "  ⚠ could not create a right pane for the handoff viewer — continuing without it" >&2
    return                    # VIEWER_OK stays 0 — the launch already succeeded
  fi
  if command -v glow >/dev/null 2>&1; then
    "$HERDR" pane run "$view" "glow '$HANDOFF_DST'" >/dev/null 2>&1 && VIEWER_OK=1
  elif command -v bat >/dev/null 2>&1; then
    "$HERDR" pane run "$view" "bat --paging=always '$HANDOFF_DST'" >/dev/null 2>&1 && VIEWER_OK=1
  fi
  if [ "$VIEWER_OK" = "1" ]; then
    step "  handoff viewer: $view"
  else
    echo "  ⚠ opened a right pane but no markdown pager (glow/bat) is available — skipping the handoff render" >&2
  fi
}

# ---- test hook --------------------------------------------------------------
# When sourced by the bats suite (SPINOFF_TEST_SOURCE=1), stop here: load the
# functions above so they can be exercised in isolation, but run none of the
# main worktree/launch work below.
[ -n "${SPINOFF_TEST_SOURCE:-}" ] && return 0

# ---- args -------------------------------------------------------------------
NAME=""
LABEL=""                     # short display name for the cmux tab/workspace (see derivation below)
HANDOFF_SRC=""
REPO=""                      # explicit target repo (when the originating cwd isn't inside it)
BASE=""                      # empty => current HEAD
PREFIX="feature"
TARGET="tab"                 # tab => surface in current workspace; workspace => new workspace
LAUNCHER="auto"              # launch backend: herdr | cmux | auto (auto => detect, see resolve_launcher)
SESSION_TRANSCRIPT=""        # explicit originating-session transcript (set by the skill when backgrounded)
SESSION_CWD=""               # cwd of the originating session, for the resume one-liner
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --handoff) HANDOFF_SRC="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --branch-prefix) PREFIX="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --launcher) LAUNCHER="$2"; shift 2 ;;
    --session-transcript) SESSION_TRANSCRIPT="$2"; shift 2 ;;
    --session-cwd) SESSION_CWD="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ---- validate --launcher ----------------------------------------------------
case "$LAUNCHER" in
  herdr|cmux|auto) ;;
  *) die "invalid --launcher '$LAUNCHER' (expected: herdr | cmux | auto)" ;;
esac

[ -n "$NAME" ] || die "missing --name <kebab-feature-name>"
# A curated --label is passed to `herdr agent start "$LABEL"` as a BARE positional
# (before flags), so a leading '-' would be misparsed as an option — the hazard the
# cmux path sidesteps with `--title`. Reject it early with a clear message rather
# than letting `agent start` fail obscurely. (The default label, set later from the
# repo basename + name, can't start with '-', so this only guards user input.)
case "$LABEL" in -*) die "--label must not start with '-' (got: $LABEL)" ;; esac
[ -n "$HANDOFF_SRC" ] || die "missing --handoff <path-to-handoff.md>"
[ -f "$HANDOFF_SRC" ] || die "handoff file not found: $HANDOFF_SRC"
case "$TARGET" in
  tab|workspace) ;;
  *) die "invalid --target '$TARGET' (expected: tab | workspace)" ;;
esac

# Prefer cmux on PATH (Homebrew, Linux); fall back to the macOS app bundle path.
CMUX="$(command -v cmux 2>/dev/null)"
[ -n "$CMUX" ] || CMUX="/Applications/cmux.app/Contents/Resources/bin/cmux"

# Resolve herdr the same way (KTD-2): a missing binary means the herdr backend is
# unavailable regardless of HERDR_ENV. No app-bundle fallback — herdr is PATH-only.
HERDR="$(command -v herdr 2>/dev/null)"

# ---- resolve target repo (--repo) before any cwd-relative git/IO ------------
# The originating /start session's cwd is often NOT inside the target repo (e.g.
# run from ~), so `--repo` names it explicitly. Relative file args are read AFTER
# this cd (handoff at finalize ~line 161, transcript at discovery ~line 138), so
# pin them absolute FIRST; then cd so every cwd-relative git call below resolves
# against the intended repo. The main-tree walk and `git -C "$MAIN_ROOT"` calls
# are unchanged — they just inherit the corrected cwd.
if [ -n "$REPO" ]; then
  [ -d "$REPO" ] || die "--repo path not found: $REPO"
  HANDOFF_SRC="$(abspath "$HANDOFF_SRC")"
  [ -n "$SESSION_TRANSCRIPT" ] && SESSION_TRANSCRIPT="$(abspath "$SESSION_TRANSCRIPT")"
  cd "$REPO" || die "could not cd into --repo: $REPO"
  # Under --repo the transcript auto-discovery fallback searches the TARGET repo's
  # project dir (not the originating session's), so an omitted --session-transcript
  # yields a wrong resume link. Warn — symmetric with the missing-file warning below.
  [ -z "$SESSION_TRANSCRIPT" ] && echo "  ⚠ --repo set without --session-transcript — the resume link will be derived from the target repo and may point at the wrong session. Pass --session-transcript <abs-path>." >&2
fi

# ---- locate repo + current branch ------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "could not resolve a git repo from $(pwd) — pass --repo <path-to-target-repo> (the originating /start session's cwd may be outside the target repo)"
# If invoked from inside a worktree, resolve to the MAIN working tree so
# worktrees nest under the primary repo, not under another worktree.
COMMON_GIT="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$COMMON_GIT" in
  /*) MAIN_ROOT="$(dirname "$COMMON_GIT")" ;;          # absolute .git dir
  *)  MAIN_ROOT="$REPO_ROOT" ;;
esac
[ -d "$MAIN_ROOT/.git" ] || MAIN_ROOT="$REPO_ROOT"

CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
BRANCH="$PREFIX/$NAME"
WORKTREE="$MAIN_ROOT/worktrees/$NAME"

# Display name for the cmux tab/workspace: a short label that captures BOTH the
# workspace (repo) this was forked from AND the work it's for, so a glance at the
# tab tells you where it came from and what it's for. The skill passes a curated
# short --label; absent that, default to <repo>/<name>.
[ -n "$LABEL" ] || LABEL="$(basename "$MAIN_ROOT")/$NAME"

step "repo:        $MAIN_ROOT"
step "new branch:  $BRANCH"
step "worktree:    $WORKTREE"
step "label:       $LABEL"

[ -e "$WORKTREE" ] && die "worktree path already exists: $WORKTREE"
if git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  die "branch already exists: $BRANCH (pick a different --name)"
fi

# ---- resolve base -----------------------------------------------------------
if [ -n "$BASE" ]; then
  case "$BASE" in
    origin/*) step "fetching ${BASE#origin/} for clean base…"
              git -C "$MAIN_ROOT" fetch origin "${BASE#origin/}" --quiet 2>/dev/null ;;
  esac
  BASE_REF="$BASE"
else
  BASE_REF="$CUR_BRANCH"          # branch off current HEAD
fi
step "base ref:    $BASE_REF"

# Stale-base guard: branching off a local branch that's behind its remote
# silently reproduces old state (this is exactly how a spinoff lands on a stale
# layout). origin/* bases are fetched above, so skip them; a local branch with no
# upstream can't be compared, so skip silently. Warn loudly but never block —
# branching off local HEAD stays valid when intended.
case "$BASE_REF" in
  origin/*) ;;
  *)
    if BASE_UP="$(git -C "$MAIN_ROOT" rev-parse --abbrev-ref "$BASE_REF@{upstream}" 2>/dev/null)"; then
      BEHIND="$(git -C "$MAIN_ROOT" rev-list --count "$BASE_REF..$BASE_REF@{upstream}" 2>/dev/null)"
      if [ -n "$BEHIND" ] && [ "$BEHIND" -gt 0 ] 2>/dev/null; then
        echo "  ⚠ base '$BASE_REF' is $BEHIND commit(s) behind '$BASE_UP' — the new worktree may start from stale state. Consider --base origin/<branch> for a fresh base." >&2
      fi
    fi
    ;;
esac

# ---- create worktree --------------------------------------------------------
step "creating worktree…"
git -C "$MAIN_ROOT" worktree add -b "$BRANCH" "$WORKTREE" "$BASE_REF" \
  || die "git worktree add failed (see error above)"

# ---- optional per-repo bootstrap hook ---------------------------------------
# Some repos need a one-time setup in a fresh worktree before it can build
# (generate an env file, link a config, etc). This is repo-specific, so it's
# opt-in via the SPINOFF_BOOTSTRAP_CMD env var rather than baked in. Example:
#   export SPINOFF_BOOTSTRAP_CMD='pnpm build-config:stage'
# Runs in the new worktree via a login shell so PATH/shims resolve. Non-fatal —
# the new Claude session can always run setup itself, so a failure just hints.
if [ -n "${SPINOFF_BOOTSTRAP_CMD:-}" ]; then
  step "running bootstrap: $SPINOFF_BOOTSTRAP_CMD"
  if ( cd "$WORKTREE" && exec "$SHELL" -lc "$SPINOFF_BOOTSTRAP_CMD" ) >/dev/null 2>&1; then
    echo "  ✓ bootstrap done"
  else
    echo "  ℹ bootstrap failed — the new session can run it manually if needed"
  fi
fi

# ---- discover originating session transcript --------------------------------
# The originating session is the one that invoked /start. When the skill runs the
# mechanical work in a BACKGROUND AGENT (the default), it resolves its own
# transcript in the main session and passes it via --session-transcript, because
# auto-discovery from inside a background agent can resolve to the AGENT's own
# transcript and silently break the resume link. Auto-discovery (env var, then
# newest .jsonl) stays as the fallback for manual/foreground runs.
#
# Resume cwd: the resume one-liner must `cd` into a dir whose Claude project
# matches the transcript (claude -r resolves the session within the cwd's
# project). The skill passes --session-cwd (the originating session's cwd); we
# fall back to REPO_ROOT when it's absent.
SESSION_LINE="(session transcript not found)"
PROJ_KEY="$(echo "$REPO_ROOT" | sed 's#/#-#g')"
PROJ_DIR="$HOME/.claude/projects/$PROJ_KEY"
TRANSCRIPT=""
# A non-empty but non-existent --session-transcript is dangerous: silently falling
# through to newest-.jsonl auto-discovery inside a background agent is exactly the
# mis-resolution this flag exists to prevent. Warn loudly rather than fall through quietly.
if [ -n "$SESSION_TRANSCRIPT" ] && [ ! -f "$SESSION_TRANSCRIPT" ]; then
  echo "  ⚠ --session-transcript '$SESSION_TRANSCRIPT' not found — falling back to auto-discovery (resume link may point at the wrong session)" >&2
fi
if [ -n "$SESSION_TRANSCRIPT" ] && [ -f "$SESSION_TRANSCRIPT" ]; then
  TRANSCRIPT="$SESSION_TRANSCRIPT"          # explicit, set by the skill (backgrounded path)
elif [ -n "${CLAUDE_TRANSCRIPT_PATH:-}" ] && [ -f "${CLAUDE_TRANSCRIPT_PATH:-}" ]; then
  TRANSCRIPT="$CLAUDE_TRANSCRIPT_PATH"
elif [ -n "${CLAUDE_SESSION_ID:-}" ] && [ -f "$PROJ_DIR/$CLAUDE_SESSION_ID.jsonl" ]; then
  TRANSCRIPT="$PROJ_DIR/$CLAUDE_SESSION_ID.jsonl"
elif [ -d "$PROJ_DIR" ]; then
  TRANSCRIPT="$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1)"
fi
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  UUID="$(basename "$TRANSCRIPT" .jsonl)"
  RESUME_CWD="${SESSION_CWD:-$REPO_ROOT}"
  SESSION_LINE="Transcript: \`$TRANSCRIPT\`
Resume:     \`cd $RESUME_CWD && claude -r $UUID\`"
fi
step "source session: ${TRANSCRIPT:-not found}"

# ---- finalize handoff into worktree -----------------------------------------
mkdir -p "$WORKTREE/docs"
HANDOFF_DST="$WORKTREE/docs/handoff.md"
# Substitute the <!-- SESSION --> placeholder with the (multiline) session block.
# Done in Python: awk -v mangles embedded newlines, and sed multiline replacement
# is painful. Falls through to a plain copy if Python is somehow unavailable.
SESSION_BLOCK="$SESSION_LINE" python3 - "$HANDOFF_SRC" "$HANDOFF_DST" <<'PY' 2>/dev/null || cp "$HANDOFF_SRC" "$HANDOFF_DST"
import os, sys
src, dst = sys.argv[1], sys.argv[2]
block = os.environ.get("SESSION_BLOCK", "")
text = open(src).read()
if "<!-- SESSION -->" in text:
    text = text.replace("<!-- SESSION -->", block)
# Self-declaring directional stance: a one-line banner so the framing survives
# even when the receiving session never sees the kickoff (a /start-workspace
# markdown viewer, or a human reading the doc later). Idempotent — skipped if a
# banner is already present (e.g. the authoring agent wrote one per SKILL Step 1).
banner = "> This handoff is directional — author intent and a starting point, enough to orient and begin, not a spec to execute literally. The code and tests are the source of truth: validate against them and expect to refine."
marker = "This handoff is directional"
if marker not in text:
    lines = text.split("\n")
    out, inserted = [], False
    for line in lines:
        out.append(line)
        if not inserted and line.startswith("# "):
            out.append("")
            out.append(banner)
            inserted = True
    text = "\n".join(out) if inserted else banner + "\n\n" + text
open(dst, "w").write(text)
PY
# Safety net: if the placeholder was missing (so the block never got inserted),
# append a Source-session section so the link is never lost.
grep -q "Resume:" "$HANDOFF_DST" 2>/dev/null || {
  printf '\n## Source session\n%s\n' "$SESSION_LINE" >> "$HANDOFF_DST"
}
step "handoff:     $HANDOFF_DST"

# ---- carry over the whole docs/ tree ----------------------------------------
# A fresh worktree only materializes COMMITTED content, so uncommitted/WIP docs a
# handoff references simply aren't there unless copied. Copy the entire docs/
# tree recursively (preserving subdirs) rather than a name/recency-filtered slice
# — an assessment, spec, or nested docs/plans/… file the handoff points at must
# land too. Skip handoff.md (the script writes that itself) and never clobber a
# file already present in the worktree (committed content wins over a WIP copy).
CARRIED=0
if [ -d "$REPO_ROOT/docs" ]; then
  while IFS= read -r -d '' f; do
    rel="${f#"$REPO_ROOT/docs/"}"
    [ "$rel" = "handoff.md" ] && continue        # script writes this itself
    dst="$WORKTREE/docs/$rel"
    [ -e "$dst" ] && continue                     # no-clobber: committed wins
    mkdir -p "$(dirname "$dst")"
    cp "$f" "$dst" 2>/dev/null && CARRIED=$((CARRIED+1))
  done < <(find "$REPO_ROOT/docs" -type f -print0 2>/dev/null)
fi
step "carried docs: $CARRIED file(s) from docs/"

# ---- carry over root-level config dotfiles (conservative allowlist) ----------
# The briefed session should run against real config, but a fresh worktree only
# has committed content — an uncommitted .env never materializes. Carry a small
# allowlist (NOT a blanket cp .[^.]* — that would sweep .git, .DS_Store, editor
# state). Fully-qualify each glob against $REPO_ROOT so a bare pattern can't
# pre-expand against the cwd. No-clobber, same as docs. Names accumulate in an
# ARRAY (not a space-joined string) so a filename with whitespace can't split
# into bogus exclude lines or a garbled footnote.
DOTS=0; CARRIED_DOTS=()
for f in "$REPO_ROOT"/.env "$REPO_ROOT"/.env.* "$REPO_ROOT"/.envrc \
         "$REPO_ROOT"/.tool-versions "$REPO_ROOT"/.nvmrc; do
  [ -f "$f" ] || continue                       # skips unmatched literal globs
  base="$(basename "$f")"
  dst="$WORKTREE/$base"
  [ -e "$dst" ] && continue                     # no-clobber: committed wins
  cp "$f" "$dst" 2>/dev/null && { DOTS=$((DOTS+1)); CARRIED_DOTS+=("$base"); }
done
if [ "$DOTS" -gt 0 ]; then
  # Secret guard: keep carried dotfiles out of `git add`. git reads the COMMON
  # (shared) info/exclude even from a linked worktree — there is no per-worktree
  # exclude — so ROOT-ANCHOR each pattern ("/name") to match only the dotfile at
  # a worktree root, never a same-named file nested elsewhere in the repo or a
  # sibling worktree. Then verify the pattern actually landed before the handoff
  # claims protection (an empty/unwritable exclude must not produce a false note).
  excl="$(git -C "$WORKTREE" rev-parse --git-path info/exclude 2>/dev/null)"
  guarded=0
  if [ -n "$excl" ]; then
    for base in "${CARRIED_DOTS[@]}"; do
      grep -qxF "/$base" "$excl" 2>/dev/null || printf '/%s\n' "$base" >> "$excl"
    done
    guarded=1
    for base in "${CARRIED_DOTS[@]}"; do
      grep -qxF "/$base" "$excl" 2>/dev/null || guarded=0
    done
  fi
  note_files="$(printf '%s ' "${CARRIED_DOTS[@]}")"; note_files="${note_files% }"
  if [ "$guarded" = "1" ]; then
    printf '\n> **Security note:** carried local config (%s) into this worktree — secrets now live in a second on-disk location. Kept out of git via the repo'"'"'s shared exclude (info/exclude, root-anchored); never commit them.\n' \
      "$note_files" >> "$HANDOFF_DST"
  else
    printf '\n> **Security note:** carried local config (%s) into this worktree but could NOT write the git exclude — these files are VISIBLE to git. Add them to .gitignore and never commit them.\n' \
      "$note_files" >> "$HANDOFF_DST"
  fi
fi
step "carried dotfiles: $DOTS config file(s)"

# ---- launch a briefed Claude via the resolved backend -----------------------
WORKSPACE_REF=""
SURFACE_REF=""
VIEWER_OK=0          # set when the handoff markdown viewer actually renders
LB_READY=0           # set to 1 when the input prompt was confirmed ready
LEFT_PANE=""; WS=""  # cmux discovery scratch (set by the cmux verbs)
HERDR_PANE=""        # herdr agent pane id (set by launcher_launch_agent_herdr)
# Backend-neutral refs the launch verbs hand off to each other:
LAUNCH_WS=""; LAUNCH_SFC=""; LAUNCH_LABEL=""; LAUNCH_WHERE=""
LAUNCH_CMD="cd '$WORKTREE' && claude --name '$LABEL'"
# Short pointer, not the full directional prose. A ~1080-char single-line paste
# overruns the TUI input line and the launched session gets a truncated kickoff.
# The "treat the handoff as directional" framing already lives authoritatively in
# every generated handoff (the banner injected above + the handoff body), so the
# kickoff only needs to point at it. Keep the first line's "Read docs/handoff.md"
# substring in sync with the resubmit-guard match below.
KICKOFF="Read docs/handoff.md — it's the brief for this worktree (treat it as directional: orient and validate against the code, don't execute literally). Get oriented, then recommend the next compound-engineering step (/ce-brainstorm if ambiguous, /ce-plan if clear) with a one-line rationale, and wait for my direction."

# Detect the backend once (KTD-2), then drive the launch through the neutral
# verbs. resolve_launcher's precedence (herdr live > cmux > none) subsumes the old
# CMUX_WORKSPACE_ID gate; LAUNCHER=none reproduces the previous no-op fallback
# (worktree + handoff still produced, summary prints the manual line).
resolve_launcher
if [ "$LAUNCHER" = "none" ]; then
  step "not inside cmux/herdr (or the CLI is missing) — skipping launch automation"
else
  step "launcher:    $LAUNCHER"
  if [ "$TARGET" = "workspace" ]; then
    launcher_new_workspace     # sets WORKSPACE_REF + LAUNCH_SFC (workspace target)
  else
    launcher_new_tab           # sets SURFACE_REF + LAUNCH_SFC (tab target)
  fi
  # Only brief once a surface actually materialized (byte-identical to the old
  # "if [ -n "$SURFACE_REF" ]" guards). The viewer is workspace-only, best-effort.
  if [ -n "$LAUNCH_SFC" ]; then
    launcher_launch_agent
    launcher_wait_ready
    launcher_send_kickoff
    [ "$TARGET" = "workspace" ] && launcher_open_viewer
  fi
fi

# ---- summary ----------------------------------------------------------------
echo
echo "════════════════════════════════════════════════════════"
echo "✓ Spinoff complete"
echo "  branch:    $BRANCH  (from $BASE_REF)"
echo "  worktree:  $WORKTREE"
echo "  handoff:   $HANDOFF_DST"
echo "  docs:      $CARRIED carried"
echo "  dotfiles:  $DOTS carried"
echo "  launcher:  $LAUNCHER"
# Describe the launched session honestly: name the backend ACTUALLY used
# ("herdr tab" / "cmux tab" / "herdr:  workspace …" / "cmux:  workspace …"),
# only claim "briefed" when readiness was confirmed, and only claim the viewer
# when it actually rendered (R9). The label is driven by $LAUNCHER / $TARGET —
# never hard-code "cmux" here (a herdr run must not report itself as cmux).
if [ "$LB_READY" = "1" ]; then SESS_STATE="open + briefed"; else SESS_STATE="launched (readiness not confirmed — check the surface)"; fi
VIEWER_NOTE=""; [ "$VIEWER_OK" = "1" ] && VIEWER_NOTE=" (handoff viewer alongside)"
if [ -n "$SURFACE_REF" ] && [ -n "$WORKSPACE_REF" ]; then
  echo "  $LAUNCHER:      workspace $WORKSPACE_REF + agent $SURFACE_REF — new Claude session $SESS_STATE$VIEWER_NOTE"
elif [ -n "$SURFACE_REF" ]; then
  echo "  $LAUNCHER tab:  $SURFACE_REF — new Claude session $SESS_STATE"
elif [ -n "$WORKSPACE_REF" ]; then
  # Workspace was created (and focused) but no agent surface launched — don't claim
  # "not created" and strand the user in an empty focused workspace.
  echo "  $LAUNCHER:      workspace $WORKSPACE_REF created, but no agent surface launched — start Claude in it manually:"
  echo "             $LAUNCH_CMD"
elif [ "$LAUNCHER" = none ]; then
  echo "  launch:    not automated (not inside cmux/herdr) — start manually:"
  echo "             $LAUNCH_CMD"
else
  echo "  $LAUNCHER:      not created — start manually:"
  echo "             $LAUNCH_CMD"
fi
echo "════════════════════════════════════════════════════════"

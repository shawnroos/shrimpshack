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
# verbs that dispatch on the resolved $LAUNCHER. Three backends implement them —
# cmux and herdr through their CLIs, ghostty through its AppleScript dictionary.
# The *_cmux verbs still issue byte-identical CLI calls to the pre-seam script (a
# herdr-absent run behaves exactly as before). LAUNCHER=none reproduces the
# original "not inside cmux" manual-line fallback: worktree and handoff are still
# produced, only the launch is skipped.

# Liveness probes. herdr: the binary resolves AND `status server` reports running
# (a stale HERDR_ENV=1 must not win — R8). cmux: the binary is executable.
# ghostty: it has NO scripting CLI, so the thing that has to exist is the .app
# bundle AppleScript targets plus osascript to talk to it. Deliberately asks
# osascript NOTHING — a probe must never be what raises the macOS Automation
# dialog. $GHOSTTY_APP is resolved next to $HERDR / $CMUX, below.
_herdr_probe() { [ -n "${HERDR:-}" ] && "$HERDR" status server 2>/dev/null | grep -qi 'running'; }
_cmux_probe()  { [ -n "${CMUX:-}" ] && [ -x "$CMUX" ]; }
_ghostty_probe() { [ -n "${GHOSTTY_APP:-}" ] && command -v osascript >/dev/null 2>&1; }

# resolve_launcher — collapse env + flag into a single $LAUNCHER (KTD-2).
# Precedence for `auto`: herdr (live) > cmux > ghostty > none. A forced --launcher
# herdr|cmux|ghostty skips the env-keyed detection but STILL probes the chosen
# backend, falling back to auto-detection (never hard-erroring) on probe failure (R8).
resolve_launcher() {
  case "$LAUNCHER" in
    herdr) if _herdr_probe; then LAUNCHER=herdr; return; fi
           echo "  ⚠ --launcher herdr requested but the herdr server isn't reachable — falling back to auto-detection" >&2 ;;
    cmux)  if _cmux_probe; then LAUNCHER=cmux; return; fi
           echo "  ⚠ --launcher cmux requested but the cmux CLI isn't available — falling back to auto-detection" >&2 ;;
    ghostty) if _ghostty_probe; then LAUNCHER=ghostty; return; fi
           echo "  ⚠ --launcher ghostty requested but Ghostty.app / osascript isn't available — falling back to auto-detection" >&2 ;;
  esac
  if   [ "${HERDR_ENV:-}" = 1 ] && _herdr_probe;          then LAUNCHER=herdr
  elif [ -n "${CMUX_WORKSPACE_ID:-}" ] && _cmux_probe;    then LAUNCHER=cmux
  # ghostty is checked LAST, and only when NO multiplexer announced itself in the
  # environment at all. Two separate reasons, both load-bearing:
  #  * ghostty's own vars are set even when a multiplexer owns the session —
  #    verified live: HERDR_ENV=1 and GHOSTTY_SURFACE_ID are BOTH present inside
  #    herdr-running-in-ghostty. Probing ghostty any earlier steals every
  #    multiplexer session and opens bare windows beside the user's layout (R6).
  #  * an announcement that is PRESENT but switched off (HERDR_ENV=0) still means
  #    this session belongs to a multiplexer whose server merely isn't up. A bare
  #    new ghostty window is the wrong recovery there, so that resolves to `none`
  #    (worktree + manual line). `--launcher ghostty` forces it when that
  #    conservative call is wrong.
  elif [ -z "${HERDR_ENV:-}" ] && [ -z "${CMUX_WORKSPACE_ID:-}" ] \
       && { [ -n "${GHOSTTY_SURFACE_ID:-}" ] || [ "${TERM_PROGRAM:-}" = ghostty ] || [ -n "${GHOSTTY_RESOURCES_DIR:-}" ]; } \
       && _ghostty_probe;                                  then LAUNCHER=ghostty
  else                                                         LAUNCHER=none
  fi
}

# --- neutral verb dispatchers (case-on-$LAUNCHER, KTD-1) ----------------------
launcher_new_tab()        { case "$LAUNCHER" in cmux) launcher_new_tab_cmux ;;        herdr) launcher_new_tab_herdr ;;        ghostty) launcher_new_tab_ghostty ;;        esac; }
launcher_new_workspace()  { case "$LAUNCHER" in cmux) launcher_new_workspace_cmux ;;  herdr) launcher_new_workspace_herdr ;;  ghostty) launcher_new_workspace_ghostty ;;  esac; }
launcher_new_split()      { case "$LAUNCHER" in cmux) launcher_new_split_cmux ;;      herdr) launcher_new_split_herdr ;;      ghostty) launcher_new_split_ghostty ;;      esac; }
launcher_find_left_pane() { case "$LAUNCHER" in cmux) launcher_find_left_pane_cmux ;; herdr) launcher_find_left_pane_herdr ;; ghostty) launcher_find_left_pane_ghostty ;; esac; }
launcher_launch_agent()   { case "$LAUNCHER" in cmux) launcher_launch_agent_cmux ;;   herdr) launcher_launch_agent_herdr ;;   ghostty) launcher_launch_agent_ghostty ;;   esac; }
launcher_wait_ready()     { case "$LAUNCHER" in cmux) launcher_wait_ready_cmux ;;     herdr) launcher_wait_ready_herdr ;;     ghostty) launcher_wait_ready_ghostty ;;     esac; }
launcher_open_viewer()    { case "$LAUNCHER" in cmux) launcher_open_viewer_cmux ;;    herdr) launcher_open_viewer_herdr ;;    ghostty) launcher_open_viewer_ghostty ;;    esac; }

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

# Split target: a new surface split off the ORIGINATING surface, which arrives as
# --from-surface. It is NOT read from the environment: the skill runs this script
# through a background agent that no longer holds CMUX_SURFACE_ID, so reading it
# there would split whatever happened to be focused (KTD-2).
# `new-split` is the verb for this — it takes an explicit `--surface` to split FROM,
# where `new-pane` can only split the focused pane. Direction is passed as a
# variable positional (cmux supports left natively — KTD-5), and --focus false
# keeps the user where they are until the launch is confirmed.
launcher_new_split_cmux() {
  step "splitting the originating cmux surface ($SPLIT_DIRECTION of $FROM_SURFACE)…"
  local out
  WS="${CMUX_WORKSPACE_ID:-}"
  # Two explicit call lines rather than one array-built call: the CLI-drift test
  # reads this file statically, and a call assembled in an array is invisible to it.
  if [ -n "$WS" ]; then
    out="$("$CMUX" new-split "$SPLIT_DIRECTION" --surface "$FROM_SURFACE" --workspace "$WS" --focus false 2>&1)"
  else
    echo "  ⚠ CMUX_WORKSPACE_ID is not set — splitting against cmux's current workspace" >&2
    out="$("$CMUX" new-split "$SPLIT_DIRECTION" --surface "$FROM_SURFACE" --focus false 2>&1)"
  fi
  SURFACE_REF="$(printf '%s' "$out" | grep -oE 'surface:[0-9]+' | head -1)"
  if [ -z "$SURFACE_REF" ]; then
    echo "  ⚠ could not parse the new split's surface ref; cmux output was:" >&2
    echo "$out" >&2
  fi
  LAUNCH_WS="$WS"; LAUNCH_SFC="$SURFACE_REF"; LAUNCH_LABEL="split surface"; LAUNCH_WHERE="split"
}

# Rename the tab, launch Claude in the worktree, submit. --title (not a bare
# positional) so a $LABEL starting with '-' can't be misparsed as a flag.
# The launch carries the brief, so a successful launch IS a successful briefing —
# KICKOFF_OK is set here rather than by a later submit step. Errors are NOT
# discarded: swallowing them is why a deleted herdr subcommand went unnoticed for
# weeks while every run still reported success.
launcher_launch_agent_cmux() {
  LB_READY=0
  local err
  "$CMUX" rename-tab --surface "$LAUNCH_SFC" --workspace "$LAUNCH_WS" --title "$LABEL" >/dev/null 2>&1
  if ! err="$("$CMUX" send --surface "$LAUNCH_SFC" --workspace "$LAUNCH_WS" "$LAUNCH_CMD" 2>&1)"; then
    KICKOFF_OK=0
    echo "  ⚠ cmux send failed while launching the briefed session: $err" >&2
    return
  fi
  if ! err="$("$CMUX" send-key --surface "$LAUNCH_SFC" --workspace "$LAUNCH_WS" enter 2>&1)"; then
    KICKOFF_OK=0
    echo "  ⚠ cmux send-key failed while launching the briefed session: $err" >&2
    return
  fi
  KICKOFF_OK=1
  step "  $LAUNCH_LABEL: $LAUNCH_SFC (launched with the brief)"
}

# Wait for the input prompt to be ready (a fixed sleep is unreliable — a fresh
# claude can spend seconds loading MCP servers, and an Enter sent too early is
# swallowed). Sets LB_READY=1 on confirmed ready.
# The poll count is derived from the same ceiling as the herdr path (a 1s sleep per
# iteration), so both backends tolerate an equally slow boot. Unlike herdr's blocking
# wait this does pay ~1s per iteration, but it breaks the instant the prompt shows —
# a fast boot still exits after a second or two.
launcher_wait_ready_cmux() {
  local screen
  for _ in $(seq 1 "$(( SPINOFF_READY_TIMEOUT_MS / 1000 + 1 ))"); do
    sleep 1
    screen="$("$CMUX" read-screen --surface "$LAUNCH_SFC" --workspace "$LAUNCH_WS" 2>/dev/null)"
    case "$screen" in
      *"❯"*|*"bypass permissions"*|*"shift+tab to cycle"*) LB_READY=1; break ;;
    esac
  done
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

# First pane id belonging to <tab_id> from `herdr pane list` JSON on stdin.
_herdr_pane_in_tab() {
  local tab="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg t "$tab" 'first(.result.panes[] | select(.tab_id==$t) | .pane_id) // empty' 2>/dev/null
  else
    TAB="$tab" python3 -c '
import sys, json, os
try:
    d = json.load(sys.stdin); t = os.environ["TAB"]
    for p in d["result"]["panes"]:
        if p.get("tab_id") == t:
            print(p["pane_id"]); break
except Exception:
    pass
' 2>/dev/null
  fi
}

# Resolve the ORIGINATING session's CURRENT workspace from the LIVE herdr server,
# not the HERDR_WORKSPACE_ID env var — that var is frozen at session-spawn and lags
# the workspace the session actually lives in now (the "spinoff spawned from space A
# lands in space B" bug). The launcher (bg agent) inherits the originating session's
# HERDR_PANE_ID, so `pane get` on it reports the workspace that pane REALLY belongs
# to now. Falls back to the env var only if the live probe yields nothing.
# Sets HERDR_WS_SOURCE=live|frozen so callers can label honestly and a future
# wrong-workspace recurrence is diagnosable (was it the live pane or the stale env?).
_herdr_current_workspace() {
  local ws=""
  HERDR_WS_SOURCE="frozen"
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    ws="$("$HERDR" pane get "$HERDR_PANE_ID" 2>/dev/null | _herdr_json 'result.pane.workspace_id')"
    [ -n "$ws" ] && HERDR_WS_SOURCE="live"
  fi
  if [ -z "$ws" ]; then
    ws="${HERDR_WORKSPACE_ID:-}"
    [ -n "$ws" ] && echo "  ⚠ could not resolve the workspace from a live pane — falling back to the possibly-stale HERDR_WORKSPACE_ID=$ws" >&2
  fi
  printf '%s' "$ws"
}

# Tab target: create a NEW, named tab and capture its single root pane; the shared
# launch verb then runs claude INTO that pane. CRITICAL: `agent start --workspace`
# does NOT open a fresh tab — it SPLITS a pane in the CURRENT tab (re-verified live
# 2026-07-06; the original "split lands in a fresh tab" reading was wrong). So the
# tab must be pre-created with `tab create --label` (a real new tab, named for the
# session, in the session's LIVE workspace) and claude launched into its root pane
# via `pane run` — one tab, one pane, no split, no leftover root shell.
launcher_new_tab_herdr() {
  step "opening a herdr agent tab…"
  local ws out tab pane
  ws="$(_herdr_current_workspace)"
  if [ -z "$ws" ]; then
    echo "  ⚠ could not resolve the current herdr workspace (no live pane, no HERDR_WORKSPACE_ID)" >&2
    LAUNCH_WS=""; LAUNCH_SFC=""; return
  fi
  LAUNCH_WS="$ws"
  step "  target workspace: $ws (${HERDR_WS_SOURCE:-frozen})"
  out="$("$HERDR" tab create --workspace "$ws" --label "$LABEL" --no-focus 2>/dev/null)"
  tab="$(printf '%s' "$out" | _herdr_json 'result.tab.tab_id')"
  if [ -z "$tab" ]; then
    echo "  ⚠ could not create a herdr tab; tab create output was:" >&2
    echo "$out" >&2
    LAUNCH_SFC=""; return
  fi
  # Its root pane: prefer the tab-create payload; else poll pane list for this tab
  # (the pane_id field is absent on some responses).
  pane="$(printf '%s' "$out" | _herdr_json 'result.tab.pane_id')"
  if [ -z "$pane" ]; then
    for _ in $(seq 1 20); do
      pane="$("$HERDR" pane list --workspace "$ws" 2>/dev/null | _herdr_pane_in_tab "$tab")"
      [ -n "$pane" ] && break
      sleep 0.5
    done
  fi
  if [ -z "$pane" ]; then
    echo "  ⚠ created herdr tab $tab but could not resolve its pane — skipping launch" >&2
    LAUNCH_SFC=""; return
  fi
  LAUNCH_RUN_PANE="$pane"      # the single pane claude runs in (no split)
  LAUNCH_SFC="$pane"          # real pane id — satisfies the shared launch guard
  LAUNCH_LABEL="agent tab"; LAUNCH_WHERE="tab"
  step "  new herdr tab: $tab (pane $pane)"
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
  LEFT_PANE="$pane"           # root pane of the new workspace's default tab
  LAUNCH_RUN_PANE="$pane"     # claude runs INTO this pane (no split)
  LAUNCH_SFC="$pane"          # real pane id — satisfies the shared launch guard
  LAUNCH_LABEL="agent surface"; LAUNCH_WHERE="workspace"
  # Pane exists — now safe to switch the user into the new workspace (best-effort;
  # a focus failure must never fail the launch).
  "$HERDR" workspace focus "$ws" >/dev/null 2>&1 || true
}

# Split target: a new pane beside the ORIGINATING pane, which arrives as
# --from-surface (never from the env — the background agent the skill runs this in
# has no HERDR_PANE_ID; KTD-2). Two constraints straight off `herdr pane --help`:
#
#  * `pane split --direction` accepts ONLY right|down. There is no left. A left
#    split is therefore split-right-then-swap: `pane swap` exchanges the two panes'
#    positions, putting the new one on the left (KTD-5). The swap is the only step
#    here inferred from --help rather than measured live, so its failure is reported
#    and NON-fatal: a session on the wrong side still beats no session.
#  * --no-focus, so the user stays in their pane until the launch is confirmed.
#
# LAUNCH_WS is deliberately left empty: every herdr launch verb addresses a PANE id,
# and resolving a workspace here would call `pane get` on a HERDR_PANE_ID the
# background agent doesn't have — a warning about a value nothing reads.
launcher_new_split_herdr() {
  step "splitting the originating herdr pane ($SPLIT_DIRECTION of $FROM_SURFACE)…"
  local out pane err
  out="$("$HERDR" pane split "$FROM_SURFACE" --direction right --no-focus 2>&1)"
  pane="$(printf '%s' "$out" | _herdr_json 'result.pane.pane_id')"
  if [ -z "$pane" ]; then
    echo "  ⚠ could not split the herdr pane '$FROM_SURFACE'; pane split output was:" >&2
    echo "$out" >&2
    LAUNCH_SFC=""; return
  fi
  if [ "$SPLIT_DIRECTION" = left ]; then
    if ! err="$("$HERDR" pane swap --source-pane "$pane" --target-pane "$FROM_SURFACE" 2>&1)"; then
      echo "  ⚠ the split succeeded but the swap that puts it on the LEFT failed: $err" >&2
      echo "    continuing — the briefed session lands on the right instead." >&2
    fi
  fi
  LAUNCH_RUN_PANE="$pane"      # the pane claude runs in (no further split)
  LAUNCH_SFC="$pane"           # real pane id — satisfies the shared launch guard
  LAUNCH_LABEL="agent split"; LAUNCH_WHERE="split"
  step "  new herdr pane: $pane (split off $FROM_SURFACE)"
}

launcher_find_left_pane_herdr() { _launcher_herdr_todo find_left_pane; }

# Launch claude by running it INTO the pre-created pane (the new tab's root, or the
# new workspace's root) with `pane run` — command+Enter into the pane's interactive
# shell, so claude resolves on PATH exactly like the cmux `send "claude"` path (no
# exec-env concern, and no split: `agent start --workspace/--tab` would add a SECOND
# pane). herdr still detects the launched claude as an agent, so `agent wait --status
# idle` works (re-verified live 2026-07-06). HERDR_PANE is that same pane.
launcher_launch_agent_herdr() {
  LB_READY=0
  local pane="${LAUNCH_RUN_PANE:-}"
  if [ -z "$pane" ]; then
    echo "  ⚠ no herdr pane resolved to launch claude into" >&2
    HERDR_PANE=""; LAUNCH_SFC=""; SURFACE_REF=""; return
  fi
  # The brief rides this command as claude's positional prompt (read from the brief
  # file), so a successful run IS a successful briefing. Errors are surfaced, not
  # discarded — silent failure here is what shipped unbriefed sessions as successes.
  local err
  if ! err="$("$HERDR" pane run "$pane" "$LAUNCH_CMD" 2>&1)"; then
    KICKOFF_OK=0
    echo "  ⚠ herdr pane run failed while launching the briefed session: $err" >&2
    HERDR_PANE="$pane"; LAUNCH_SFC="$pane"; SURFACE_REF="$pane"
    return
  fi
  HERDR_PANE="$pane"; LAUNCH_SFC="$pane"; SURFACE_REF="$pane"
  KICKOFF_OK=1
  step "  herdr agent pane: $pane (launched with the brief)"
}

# Readiness for the herdr path. Sets LB_READY=1 only when claude's input prompt is
# actually drawn and unblocked.
#
# Both of the traps below were measured live against herdr 0.7.1 + claude 2.1.212.
#
# 1. `agent wait <pane> --status idle` does NOT wait for the agent to EXIST. On an
#    unregistered pane it returns `agent_not_found` and exits 1 in ~0.4s — the
#    --timeout only governs a STATUS TRANSITION on an already-registered agent.
#    `pane run` returns as soon as the command hits the shell, so claude is always
#    still starting here: a single `agent wait` fails instantly, whatever the ceiling.
#
# 2. `agent_status: idle` does NOT mean "ready for input". A spinoff worktree is a
#    NEW project path, so a repo with .mcp.json greets a fresh claude with a trust
#    modal ("N new MCP servers found in this project"), and the agent registers as
#    **idle** while that modal blocks the prompt.
#
# Together these are the real "staged but unsubmitted" cause: readiness came back
# false in 0.4s, the old code sent anyway, the text was typed at the pane, the tty
# buffered it, and claude picked it up on first stdin read — leaving the brief in the
# input box, never submitted. So: read readiness off the SCREEN, dismiss the modal,
# and only then report ready.
#
# Match claude's own footer, NEVER a bare "❯" — that is also the SHELL prompt, i.e.
# a guaranteed false positive before claude has drawn at all.
launcher_wait_ready_herdr() {
  LB_READY=0
  [ -n "${HERDR_PANE:-}" ] || return
  local deadline screen
  deadline=$(( $(date +%s) + SPINOFF_READY_TIMEOUT_MS / 1000 ))
  while :; do
    # NB: `pane read` emits RAW TEXT, not JSON (only `agent read` is JSON — and that
    # one 404s until the agent registers). Piping this through _herdr_json yields an
    # empty string forever, which is exactly why the old resubmit guard below never
    # fired even once. Read it raw.
    screen="$("$HERDR" pane read "$HERDR_PANE" --source visible 2>/dev/null)"
    case "$screen" in
      *"shift+tab to cycle"*|*"bypass permissions"*|*"? for shortcuts"*) LB_READY=1; return ;;
      *"new MCP servers found"*|*"Select any you wish to enable"*)
        # Confirm the pre-checked default (Enter). The spinoff is a worktree of a repo
        # the user already works in, so this reproduces the parent repo's state rather
        # than granting anything new — but it IS a trust prompt, so it's disclosed in
        # the output, never silent. SPINOFF_MCP_MODAL=reject Escapes out instead
        # (session gets no MCP servers); =abort leaves it up and fails the brief.
        case "${SPINOFF_MCP_MODAL:-accept}" in
          reject) "$HERDR" pane send-keys "$HERDR_PANE" Escape >/dev/null 2>&1
                  step "  … MCP trust modal: rejected all (SPINOFF_MCP_MODAL=reject)" ;;
          abort)  step "  … MCP trust modal is up and SPINOFF_MCP_MODAL=abort — not briefing"; return ;;
          *)      "$HERDR" pane send-keys "$HERDR_PANE" Enter >/dev/null 2>&1
                  step "  … MCP trust modal: accepted the pre-checked default (new worktree = new project path)" ;;
        esac
        sleep 2 ;;
    esac
    [ "$(date +%s)" -ge "$deadline" ] && return
    sleep 1
  done
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

# --- ghostty backend ---------------------------------------------------------
# Ghostty has NO scripting CLI (the `ghostty` binary only launches the app), so this
# backend is driven entirely through its AppleScript dictionary (Ghostty.sdef) —
# KTD-3. That is strictly better than keystroke driving for this job because every
# creation verb RETURNS a handle: `new window` → window, `new tab in <window>` → tab,
# `split <terminal> direction …` → terminal, and a terminal reports its own `pid` and
# `tty`. Nothing has to be scraped or guessed.
#
# Two rules below are load-bearing, both established by live testing (2026-08-03,
# Ghostty on macOS 15) rather than reasoning:
#
# 1. AppleScript text is passed as ARGV, never interpolated. The dictionary script is
#    staged verbatim into a temp file from a QUOTED heredoc (bash expands nothing in
#    it) and invoked as `osascript <file> <verb> <args…>`, where the script reads
#    `item N of argv`. Verified: text containing apostrophes, double quotes,
#    backticks, `$`, backslashes and newlines crosses that boundary byte-identically.
#    Interpolating $LAUNCH_CMD into `osascript -e` puts the worktree path, the label
#    and a `$(cat …)` through AppleScript's own string escaping instead, which is
#    exactly the class of quoting failure this design removes.
# 2. `command:` REPLACES the shell, so the surface configuration carries
#    `sh -lc '<LAUNCH_CMD>'` — $LAUNCH_CMD contains `&&` and `$(cat …)`, which need a
#    shell to mean anything. _ghostty_sh_c re-escapes the payload's own single quotes
#    so the wrapper survives however ghostty tokenizes the string.
#
# Also measured, so nobody re-derives it:
#   * a terminal's `id` is a UUID; the ghostty-exported GHOSTTY_SURFACE_ID is a hex
#     pointer and does NOT match it. So --from-surface is resolved against BOTH `id`
#     and `tty` — `$(tty)` from the originating session is the reliable handle.
#   * `working directory of <terminal>` reads back EMPTY once `command:` is set; it
#     confirms nothing.
#   * `close` works on a terminal, not on a window (a window doesn't understand it).
#   * there is no read-screen verb at all — see launcher_wait_ready_ghostty for what
#     that costs.
GHOSTTY_SCPT=""          # staged AppleScript path (see _ghostty_stage)
GHOSTTY_SCPT_DIR=""      # its temp dir, removed on exit
GHOSTTY_TERM=""          # terminal id of the launched agent surface
GHOSTTY_PLACE=""         # where launch_agent should create it: window | tab | split

# Stage the dictionary script once per run. Quoted heredoc: NOTHING in it is expanded
# by bash — every value the script needs arrives in argv.
#
# MUST be called from the MAIN shell, never from inside a `$(…)`. Every _ghostty_run
# call is a command substitution, so a subshell's assignments to GHOSTTY_SCPT* would
# vanish AND the EXIT trap registered there would delete the staged file the instant
# that subshell returned — measured, not theorised: the first live run failed with
# "No such file or directory" on a path it had just written. So the three verbs stage
# up front, in the main shell, and _ghostty_run only ever READS the path.
_ghostty_stage() {
  [ -n "$GHOSTTY_SCPT" ] && [ -f "$GHOSTTY_SCPT" ] && return 0
  GHOSTTY_SCPT_DIR="$(mktemp -d 2>/dev/null)" || { echo "  ⚠ could not stage the ghostty AppleScript (mktemp failed)" >&2; return 1; }
  trap 'rm -rf "$GHOSTTY_SCPT_DIR"' EXIT
  GHOSTTY_SCPT="$GHOSTTY_SCPT_DIR/spinoff-ghostty.applescript"
  cat > "$GHOSTTY_SCPT" <<'APPLESCRIPT'
-- Resolve a terminal from the handle the caller passed. Accepts either the
-- terminal's own id (a UUID) or its tty path, because the env var ghostty exports
-- (GHOSTTY_SURFACE_ID) matches NEITHER — it is a hex pointer. Comparisons are
-- wrapped in try because a terminal can die between the list and the read.
on findTerminal(theRef)
	tell application "Ghostty"
		repeat with tt in terminals
			try
				if (id of tt as text) is theRef then return tt
			end try
			try
				if (tty of tt as text) is theRef then return tt
			end try
		end repeat
	end tell
	return missing value
end findTerminal

-- Every verb reports the new terminal the same way, one key=value per line, so the
-- shell side parses one shape. pid is the started-signal (KTD-7).
on describe(t)
	tell application "Ghostty"
		return "terminal=" & (id of t as text) & linefeed & "pid=" & (pid of t as text) & linefeed & "tty=" & (tty of t as text)
	end tell
end describe

on run argv
	set verb to item 1 of argv
	tell application "Ghostty"
		if verb is "new-window" then
			set w to new window with configuration {command:(item 2 of argv), initial working directory:(item 3 of argv)}
			set t to focused terminal of selected tab of w
			return "window=" & (id of w as text) & linefeed & my describe(t)

		else if verb is "new-tab" then
			-- No window to put a tab in (every ghostty window closed) → make one.
			if (count of windows) is 0 then
				set w to new window with configuration {command:(item 2 of argv), initial working directory:(item 3 of argv)}
				set t to focused terminal of selected tab of w
				return "window=" & (id of w as text) & linefeed & my describe(t)
			end if
			set w to front window
			set tb to new tab in w with configuration {command:(item 2 of argv), initial working directory:(item 3 of argv)}
			set t to focused terminal of tb
			return "window=" & (id of w as text) & linefeed & "tab=" & (id of tb as text) & linefeed & my describe(t)

		else if verb is "split" then
			set t0 to my findTerminal(item 2 of argv)
			if t0 is missing value then return "error=surface-not-found"
			set cfg to {command:(item 4 of argv), initial working directory:(item 5 of argv)}
			-- direction is an enumerated constant, not a string, so it can't come
			-- straight from argv. left is native here (unlike herdr) — KTD-5.
			if (item 3 of argv) is "left" then
				set t to split t0 direction left with configuration cfg
			else
				set t to split t0 direction right with configuration cfg
			end if
			-- Focus is NOT restored here. Measured: ghostty focuses a new split
			-- asynchronously, AFTER the Apple event that created it returns, so a
			-- `focus t0` in this same tell block is silently overridden (it worked
			-- as a separate event, and not once inside this one — with or without a
			-- delay). The caller issues the `focus` verb below as its own event.
			return my describe(t)

		else if verb is "focus" then
			set t to my findTerminal(item 2 of argv)
			if t is missing value then return "error=surface-not-found"
			focus t
			return "focused=" & (id of t as text)

		else if verb is "pid" then
			set t to my findTerminal(item 2 of argv)
			if t is missing value then return "error=surface-not-found"
			return my describe(t)
		end if
		return "error=unknown-verb"
	end tell
end run
APPLESCRIPT
  [ -s "$GHOSTTY_SCPT" ] || { echo "  ⚠ staged ghostty AppleScript is empty: $GHOSTTY_SCPT" >&2; return 1; }
  return 0
}

# The Automation-denial latch. macOS remembers a denial, so once -1743 comes back
# there is nothing to retry — but _ghostty_run always executes inside a command
# substitution, so it cannot set a shell variable the caller would see. The latch is
# therefore a FILE beside the staged script: written in the subshell, read by anyone.
_ghostty_deny_flag() { printf '%s' "${GHOSTTY_SCPT_DIR:-}/tcc-denied"; }
_ghostty_denied()    { [ -n "${GHOSTTY_SCPT_DIR:-}" ] && [ -f "$(_ghostty_deny_flag)" ]; }

# Wrap a shell command line for the surface configuration's `command:` key, which
# replaces the shell outright. The payload's own single quotes are re-escaped the
# POSIX way ('\'') so the wrapper stays a single argument.
_ghostty_sh_c() { local s=${1//\'/\'\\\'\'}; printf "sh -lc '%s'" "$s"; }

# Read one key=value line out of a verb's output.
_ghostty_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# Invoke one verb against the already-staged script. Failures are REPORTED, never
# discarded (KD-4) — swallowing backend errors is how a deleted subcommand shipped as
# success for weeks. A denied Automation permission is named with its remedy and
# latched, and every later verb short-circuits instead of retrying into the same wall.
_ghostty_run() {
  local out
  _ghostty_denied && return 1
  [ -n "$GHOSTTY_SCPT" ] && [ -f "$GHOSTTY_SCPT" ] || { echo "  ⚠ ghostty AppleScript was not staged — cannot run verb '$1'" >&2; return 1; }
  if ! out="$(osascript "$GHOSTTY_SCPT" "$@" 2>&1)"; then
    case "$out" in
      *-1743*|*"Not authorized to send Apple events"*)
        : > "$(_ghostty_deny_flag)" 2>/dev/null || true
        echo "  ⚠ macOS blocked this process from controlling Ghostty (Apple event error -1743, 'Not authorized to send Apple events')." >&2
        echo "    Fix: System Settings → Privacy & Security → Automation → allow this app to control Ghostty, then re-run." >&2
        echo "    Not retrying: a denial is remembered until you change it." >&2 ;;
      *)
        echo "  ⚠ ghostty AppleScript verb '$1' failed: $out" >&2 ;;
    esac
    return 1
  fi
  printf '%s' "$out"
  # The script reports its own recoverable failures in-band (an unresolvable
  # surface, an unknown verb) — pass them to the caller AND fail, so no caller
  # mistakes an error payload for a handle.
  case "$out" in error=*) return 1 ;; esac
  return 0
}

# ghostty has no pane tree to walk: a terminal is addressed by its own handle, so
# there is no "find the left pane" step. A documented no-op, like the herdr one —
# the dispatcher stays uniform across backends.
launcher_find_left_pane_ghostty() { : ; }

# The three placement verbs create NOTHING. On ghostty the surface and the launch are
# the same act — the window/tab/split is born running $LAUNCH_CMD from its surface
# configuration — so creating anything here would open a window BEFORE the shared
# launch region's "is the brief file non-empty?" guard has had its say, which is the
# exact "session exists but is unbriefed" window this design removes. They record the
# placement and hand back a sentinel that satisfies the region's did-a-surface-appear
# gate; launcher_launch_agent_ghostty replaces it with the real terminal id.
launcher_new_workspace_ghostty() {
  step "new ghostty window queued (the briefed launch creates it)…"
  GHOSTTY_PLACE=window
  LAUNCH_WS=""; LAUNCH_SFC="ghostty:pending"
  LAUNCH_LABEL="agent surface"; LAUNCH_WHERE="workspace"
}

launcher_new_tab_ghostty() {
  step "new ghostty tab queued (the briefed launch creates it)…"
  GHOSTTY_PLACE=tab
  LAUNCH_WS=""; LAUNCH_SFC="ghostty:pending"
  LAUNCH_LABEL="agent tab"; LAUNCH_WHERE="tab"
}

launcher_new_split_ghostty() {
  step "ghostty split queued ($SPLIT_DIRECTION of $FROM_SURFACE)…"
  GHOSTTY_PLACE=split
  LAUNCH_WS=""; LAUNCH_SFC="ghostty:pending"
  LAUNCH_LABEL="agent split"; LAUNCH_WHERE="split"
}

# The launch: create the recorded placement with $LAUNCH_CMD in its surface
# configuration. Creating IS briefing here, so KICKOFF_OK is set from whether a
# terminal handle came back — there is no separate send to fail silently.
launcher_launch_agent_ghostty() {
  LB_READY=0
  local cmd out win pid
  # Staged HERE, in the main shell — see _ghostty_stage. A staging failure is a
  # launch failure, and it must leave LAUNCH_SFC alone (below) so the run reports
  # itself unbriefed rather than as a clean worktree-only spinoff.
  if ! _ghostty_stage; then
    KICKOFF_OK=0
    SURFACE_REF=""
    return
  fi
  cmd="$(_ghostty_sh_c "$LAUNCH_CMD")"
  case "$GHOSTTY_PLACE" in
    window) out="$(_ghostty_run new-window "$cmd" "$WORKTREE")" ;;
    tab)    out="$(_ghostty_run new-tab "$cmd" "$WORKTREE")" ;;
    split)
      out="$(_ghostty_run split "$FROM_SURFACE" "$SPLIT_DIRECTION" "$cmd" "$WORKTREE")"
      # A handle that matches no live terminal is a wrong handle, not a missing one —
      # so say which one failed and what a working one looks like, then open a TAB
      # rather than guessing at some other terminal. LAUNCH_WHERE is corrected so the
      # summary reports the tab it actually opened.
      case "$out" in
        *error=surface-not-found*)
          echo "  ⚠ --from-surface '$FROM_SURFACE' matches no live ghostty terminal (expected a terminal id or its tty, e.g. /dev/ttys004) — opening a new TAB instead of a split" >&2
          LAUNCH_LABEL="agent tab"; LAUNCH_WHERE="tab"
          out="$(_ghostty_run new-tab "$cmd" "$WORKTREE")" ;;
        *)
          # Put the user back in the pane they started from. The dictionary has no
          # unfocused split, and restoring focus inside the split's own Apple event
          # does nothing (ghostty focuses the new surface after that event returns),
          # so this has to be a SECOND event — verified live. Best-effort: a session
          # that lands focused is a nuisance, not a failure.
          _ghostty_run focus "$FROM_SURFACE" >/dev/null || \
            echo "  ⚠ split created but focus could not be returned to '$FROM_SURFACE' — the new pane has focus" >&2 ;;
      esac ;;
    *) echo "  ⚠ no ghostty placement was recorded — nothing to launch" >&2; out="" ;;
  esac
  GHOSTTY_TERM="$(_ghostty_field "$out" terminal)"
  if [ -z "$GHOSTTY_TERM" ]; then
    KICKOFF_OK=0
    echo "  ⚠ ghostty returned no terminal handle — the briefed session did not launch" >&2
    # LAUNCH_SFC deliberately keeps its sentinel. Clearing it would make
    # BRIEF_ATTEMPTED=0, and the summary would then print "✓ Spinoff complete" for a
    # run that failed to brief anything — the exact false-success this script exists
    # to refuse. SURFACE_REF stays empty so the summary prints the manual recovery.
    SURFACE_REF=""
    return
  fi
  LAUNCH_SFC="$GHOSTTY_TERM"; SURFACE_REF="$GHOSTTY_TERM"
  win="$(_ghostty_field "$out" window)"
  # Only the workspace target owns its window; a tab/split lands in one the user
  # already had, and claiming it in the summary would read as "we made you a window".
  if [ "$LAUNCH_WHERE" = workspace ] && [ -n "$win" ]; then WORKSPACE_REF="$win"; LAUNCH_WS="$win"; fi
  pid="$(_ghostty_field "$out" pid)"
  KICKOFF_OK=1
  step "  $LAUNCH_LABEL: $GHOSTTY_TERM (pid ${pid:-unknown}, launched with the brief)"
}

# Readiness on ghostty is the pid the terminal reports (KTD-7) — the started signal.
# It normally resolves on the first poll, since the creation verb already returned one.
#
# There is deliberately no screen read here, and that has a cost worth stating: the
# dictionary exposes NO way to read a terminal's contents, so R12's MCP-trust-modal
# handling — the thing that answers "N new MCP servers found in this project" on a
# fresh worktree path — cannot run on this backend. The brief is unaffected (it rode
# the launch), so what's lost is MCP servers, not the briefing: the session sits on
# the trust prompt until the user answers it. When the pid never appears, LB_READY
# stays 0 and the summary's "prompt never confirmed — MCP servers may not be enabled"
# line is the honest report.
launcher_wait_ready_ghostty() {
  LB_READY=0
  [ -n "$GHOSTTY_TERM" ] || return
  _ghostty_stage || return
  local deadline out pid
  deadline=$(( $(date +%s) + SPINOFF_READY_TIMEOUT_MS / 1000 ))
  while :; do
    out="$(_ghostty_run pid "$GHOSTTY_TERM")"
    _ghostty_denied && return                  # permission denial: reported already, no retry
    pid="$(_ghostty_field "$out" pid)"
    case "$pid" in
      ''|0|"missing value") ;;
      *) LB_READY=1; return ;;
    esac
    [ "$(date +%s)" -ge "$deadline" ] && return
    sleep 1
  done
}

# Right-hand handoff viewer (workspace target only). Same shape as the herdr one:
# ghostty has no markdown viewer either, so split a terminal off the agent's and
# render the handoff with a pager (glow, then bat). BEST-EFFORT — VIEWER_OK=1 only
# when a pager actually runs; the launch has already succeeded by this point and must
# never be failed by a missing viewer.
launcher_open_viewer_ghostty() {
  local pager out view
  [ -n "$GHOSTTY_TERM" ] || return
  _ghostty_stage || return
  if command -v glow >/dev/null 2>&1; then
    pager="glow '$HANDOFF_DST'"
  elif command -v bat >/dev/null 2>&1; then
    pager="bat --paging=always '$HANDOFF_DST'"
  else
    echo "  ⚠ no markdown pager (glow/bat) available — skipping the handoff viewer" >&2
    return
  fi
  out="$(_ghostty_run split "$GHOSTTY_TERM" right "$(_ghostty_sh_c "$pager")" "$WORKTREE")" || return
  view="$(_ghostty_field "$out" terminal)"
  if [ -n "$view" ]; then
    VIEWER_OK=1
    # Leave the user in the agent, not in the pager — the equivalent of the other
    # backends' --no-focus on the viewer split. Separate Apple event, for the reason
    # given in the split verb. Best-effort.
    _ghostty_run focus "$GHOSTTY_TERM" >/dev/null || true
    step "  handoff viewer: $view"
  else
    echo "  ⚠ split a viewer terminal but ghostty returned no handle for it — continuing without the handoff render" >&2
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
TARGET="tab"                 # tab => surface in current workspace; workspace => new workspace; split => beside --from-surface
LAUNCHER="auto"              # launch backend: herdr | cmux | ghostty | auto (auto => detect, see resolve_launcher)
SPLIT_DIRECTION="right"      # --target split only: which side of --from-surface (right | left)
FROM_SURFACE=""              # the ORIGINATING pane/surface to split off (see the validation note below)
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
    --split-direction) SPLIT_DIRECTION="$2"; shift 2 ;;
    --from-surface) FROM_SURFACE="$2"; shift 2 ;;
    --launcher) LAUNCHER="$2"; shift 2 ;;
    --session-transcript) SESSION_TRANSCRIPT="$2"; shift 2 ;;
    --session-cwd) SESSION_CWD="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ---- validate --launcher ----------------------------------------------------
case "$LAUNCHER" in
  herdr|cmux|ghostty|auto) ;;
  *) die "invalid --launcher '$LAUNCHER' (expected: herdr | cmux | ghostty | auto)" ;;
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
  tab|workspace|split) ;;
  *) die "invalid --target '$TARGET' (expected: tab | workspace | split)" ;;
esac
case "$SPLIT_DIRECTION" in
  right|left) ;;
  *) die "invalid --split-direction '$SPLIT_DIRECTION' (expected: right | left)" ;;
esac
# A split has to know WHAT to split, and that can only arrive as --from-surface: the
# skill runs this script through a background agent, which no longer holds
# HERDR_PANE_ID / CMUX_SURFACE_ID / GHOSTTY_SURFACE_ID, so reading the originating
# surface from the environment splits whatever happened to be focused — or nothing
# (KTD-2). Rather than guess a surface, fall back to the tab target, LOUDLY: the user
# asked for a pane beside theirs and is going to go looking for it.
if [ "$TARGET" = split ] && [ -z "$FROM_SURFACE" ]; then
  echo "  ⚠ --target split needs --from-surface <id>, and nothing was passed — opening a TAB instead of a split." >&2
  echo "    The originating surface cannot be inherited from the environment here; pass it explicitly." >&2
  TARGET=tab
fi

# Prefer cmux on PATH (Homebrew, Linux); fall back to the macOS app bundle path.
CMUX="$(command -v cmux 2>/dev/null)"
[ -n "$CMUX" ] || CMUX="/Applications/cmux.app/Contents/Resources/bin/cmux"

# Resolve herdr the same way (KTD-2): a missing binary means the herdr backend is
# unavailable regardless of HERDR_ENV. No app-bundle fallback — herdr is PATH-only.
HERDR="$(command -v herdr 2>/dev/null)"

# Resolve ghostty the same way — except ghostty ships no scripting CLI, so the thing
# that has to resolve is the .app bundle AppleScript targets. Prefer the bundle
# GHOSTTY_RESOURCES_DIR points INTO (correct even for a non-standard install
# location), then the two standard ones. Empty => the ghostty backend is unavailable,
# whatever TERM_PROGRAM says.
GHOSTTY_APP=""
case "${GHOSTTY_RESOURCES_DIR:-}" in
  */Ghostty.app/*) _g="${GHOSTTY_RESOURCES_DIR%%/Ghostty.app/*}/Ghostty.app"
                   [ -d "$_g" ] && GHOSTTY_APP="$_g" ;;
esac
if [ -z "$GHOSTTY_APP" ]; then
  for _g in /Applications/Ghostty.app "$HOME/Applications/Ghostty.app"; do
    [ -d "$_g" ] && { GHOSTTY_APP="$_g"; break; }
  done
fi

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
KICKOFF_OK=0         # set to 1 ONLY when the launch carrying the brief actually succeeded
# Readiness ceiling. A boot slower than this is a hard failure (kickoff withheld,
# reported loudly, non-zero exit) rather than a silently-unbriefed tab. Generous by
# design: herdr's `agent wait` returns the instant the agent is idle, so a fast boot
# pays nothing. Env-overridable — the deliberate-fail test sets it to 1.
SPINOFF_READY_TIMEOUT_MS="${SPINOFF_READY_TIMEOUT_MS:-180000}"
SPINOFF_RETRY_TIMEOUT_MS="${SPINOFF_RETRY_TIMEOUT_MS:-5000}"
LEFT_PANE=""; WS=""  # cmux discovery scratch (set by the cmux verbs)
HERDR_PANE=""        # herdr agent pane id (set by launcher_launch_agent_herdr)
# Backend-neutral refs the launch verbs hand off to each other:
LAUNCH_WS=""; LAUNCH_SFC=""; LAUNCH_LABEL=""; LAUNCH_WHERE=""; LAUNCH_RUN_PANE=""; HERDR_WS_SOURCE=""
# Short pointer, not the full directional prose. The "treat the handoff as
# directional" framing already lives authoritatively in every generated handoff
# (the banner injected above + the handoff body), so the brief only points at it.
KICKOFF="Read docs/handoff.md — it's the brief for this worktree (treat it as directional: orient and validate against the code, don't execute literally). Get oriented, then recommend the next compound-engineering step (/ce-brainstorm if ambiguous, /ce-plan if clear) with a one-line rationale, and wait for my direction."

# The brief rides the LAUNCH itself as claude's positional prompt, instead of being
# typed into an already-running TUI afterward. That removes the whole staged-send
# failure class: there is no window in which a session exists but is unbriefed, and
# no Enter to be swallowed by a booting app.
#
# It travels as a FILE PATH, never inline. The brief contains apostrophes, quotes and
# punctuation, and the command string is re-parsed by a shell (cmux `send`, herdr
# `pane run`) and, for ghostty, by AppleScript first. Passing the path means only the
# path crosses those boundaries — verified byte-identical against hostile input.
#
# The file lives in the worktree, which is freshly created per run, so the path is
# unique per spinoff without a random suffix, and it PERSISTS: the manual-recovery
# line printed on failure has to stay runnable after the script exits.
BRIEF_FILE="${SPINOFF_BRIEF_FILE:-$WORKTREE/.spinoff-brief}"
printf '%s\n' "$KICKOFF" > "$BRIEF_FILE" 2>/dev/null || true
# Keep it out of git the same way carried dotfiles are (root-anchored, shared exclude).
_brief_excl="$(git -C "$WORKTREE" rev-parse --git-path info/exclude 2>/dev/null)"
[ -n "$_brief_excl" ] && { grep -qxF '/.spinoff-brief' "$_brief_excl" 2>/dev/null || printf '/.spinoff-brief\n' >> "$_brief_excl"; }

LAUNCH_CMD="cd '$WORKTREE' && claude --name '$LABEL' \"\$(cat '$BRIEF_FILE')\""
# Recovery line for the summary: never references the brief file, so it stays
# runnable even if that file is gone.
MANUAL_CMD="cd '$WORKTREE' && claude --name '$LABEL'"

# Detect the backend once (KTD-2), then drive the launch through the neutral
# verbs. resolve_launcher's precedence (herdr live > cmux > none) subsumes the old
# CMUX_WORKSPACE_ID gate; LAUNCHER=none reproduces the previous no-op fallback
# (worktree + handoff still produced, summary prints the manual line).
resolve_launcher
if [ "$LAUNCHER" = "none" ]; then
  step "not inside cmux/herdr (or the CLI is missing) — skipping launch automation"
else
  step "launcher:    $LAUNCHER"
  case "$TARGET" in
    workspace) launcher_new_workspace ;;   # sets WORKSPACE_REF + LAUNCH_SFC
    split)     launcher_new_split ;;       # sets SURFACE_REF + LAUNCH_SFC beside --from-surface
    *)         launcher_new_tab ;;         # sets SURFACE_REF + LAUNCH_SFC
  esac
  # Only launch once a surface actually materialized. The viewer is workspace-only,
  # best-effort.
  if [ -n "$LAUNCH_SFC" ]; then
    # Refuse to launch an unbriefable session. An unreadable or empty brief file
    # would produce `claude ""` — a session that opens with no idea why it exists,
    # which is precisely the outcome this design removes. Fail before launching.
    if [ ! -s "$BRIEF_FILE" ]; then
      KICKOFF_OK=0
      echo "  ⚠ brief file is missing or empty ($BRIEF_FILE) — refusing to launch an unbriefed session" >&2
    else
      launcher_launch_agent
      # Readiness is no longer a briefing gate — the brief is already submitted by
      # the launch. It still runs because it is what dismisses the MCP trust modal
      # a fresh project path raises, which is what gets MCP servers enabled for the
      # new session. A session that never draws is now a WARNING, not a failure.
      launcher_wait_ready
      [ "$TARGET" = "workspace" ] && launcher_open_viewer
    fi
  fi
fi

# ---- summary ----------------------------------------------------------------
# Did we actually try to brief a session? (Launcher resolved AND a surface came up.)
# Only then can an unsubmitted kickoff be a failure — a LAUNCHER=none run is a
# legitimate worktree-only spinoff and still "complete".
BRIEF_ATTEMPTED=0
[ "$LAUNCHER" != "none" ] && [ -n "$LAUNCH_SFC" ] && BRIEF_ATTEMPTED=1

# NEVER render an unbriefed session as success. The skill mandates relaying this
# block verbatim, so a failure formatted as a success line inside a ✓ block is a
# failure that reaches the user as "done" — which is exactly how the staged-kickoff
# bug survived. Header + exit code both tell the truth.
echo
echo "════════════════════════════════════════════════════════"
if [ "$BRIEF_ATTEMPTED" = "1" ] && [ "$KICKOFF_OK" != "1" ]; then
  echo "⚠ Spinoff INCOMPLETE — worktree is ready, session is NOT briefed"
else
  echo "✓ Spinoff complete"
fi
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
if [ "$KICKOFF_OK" = "1" ]; then SESS_STATE="open + briefed"; else SESS_STATE="NOT briefed — the launch did not carry the brief"; fi
# Readiness is now advisory: the brief is submitted by the launch, so a session that
# never drew is briefed but may not have had its MCP trust modal answered.
[ "$KICKOFF_OK" = "1" ] && [ "$LB_READY" != "1" ] && SESS_STATE="$SESS_STATE (prompt never confirmed — MCP servers may not be enabled)"
VIEWER_NOTE=""; [ "$VIEWER_OK" = "1" ] && VIEWER_NOTE=" (handoff viewer alongside)"
if [ -n "$SURFACE_REF" ] && [ -n "$WORKSPACE_REF" ]; then
  echo "  $LAUNCHER:      workspace $WORKSPACE_REF + agent $SURFACE_REF — new Claude session $SESS_STATE$VIEWER_NOTE"
elif [ -n "$SURFACE_REF" ]; then
  # Name the target that was actually used, not always "tab": a split reports a
  # split, and a split that FELL BACK to a tab reports the tab it really opened
  # (the verbs correct LAUNCH_WHERE when they fall back).
  echo "  $LAUNCHER ${LAUNCH_WHERE:-tab}:  $SURFACE_REF — new Claude session $SESS_STATE"
elif [ -n "$WORKSPACE_REF" ]; then
  # Workspace was created (and focused) but no agent surface launched — don't claim
  # "not created" and strand the user in an empty focused workspace.
  echo "  $LAUNCHER:      workspace $WORKSPACE_REF created, but no agent surface launched — start Claude in it manually:"
  echo "             $MANUAL_CMD"
elif [ "$LAUNCHER" = none ]; then
  echo "  launch:    not automated (not inside cmux/herdr) — start manually:"
  echo "             $MANUAL_CMD"
else
  echo "  $LAUNCHER:      not created — start manually:"
  echo "             $MANUAL_CMD"
fi
echo "════════════════════════════════════════════════════════"

# The worktree/branch/handoff are real and worth keeping — but an unbriefed session
# is NOT a completed spinoff. Say so OUTSIDE the block (so it survives a summary
# relay), hand over the exact recovery, and exit non-zero so a caller that only
# checks status can't mistake this for success.
if [ "$BRIEF_ATTEMPTED" = "1" ] && [ "$KICKOFF_OK" != "1" ]; then
  echo
  echo "⚠ THE NEW SESSION WAS NOT BRIEFED." >&2
  echo "  The brief travels as an argument to the launch command, so this means the launch" >&2
  echo "  itself did not complete — the failure is reported above, not swallowed." >&2
  echo "  The worktree, branch and handoff are intact. To brief it by hand, run this in the tab:" >&2
  echo >&2
  echo "    Read docs/handoff.md and get oriented, then recommend the next step." >&2
  exit 3
fi

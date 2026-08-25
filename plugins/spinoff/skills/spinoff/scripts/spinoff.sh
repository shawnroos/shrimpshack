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
# Single-quote a value for safe re-parsing by ANOTHER shell. $LAUNCH_CMD is a string
# that cmux/herdr type into a live shell (and ghostty runs via sh -lc), so a naked
# apostrophe in a label or a repo path — "Shawn's spinoff", /Users/x/Shawn's projects/
# — terminated the quoting and made the whole command a syntax error. The CLI accepted
# the text, so the run reported "✓ complete … briefed" while the pane sat on a
# continuation prompt with no claude at all. Escape, never trust the input.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ---- launcher seam (KTD-1 / KTD-2) ------------------------------------------
# The launch region near the bottom is backend-neutral: it calls launcher_*
# verbs that dispatch on the resolved $LAUNCHER. Three backends implement them —
# cmux and herdr through their CLIs, ghostty through its AppleScript dictionary.
# The *_cmux verbs still issue byte-identical CLI calls to the pre-seam script (a
# herdr-absent run behaves exactly as before). LAUNCHER=none reproduces the
# original "not inside cmux" manual-line fallback: worktree and handoff are still
# produced, only the launch is skipped.

# ---- binary resolution (R1-R3, R15, KTD-2) -----------------------------------
# The three LAUNCHER binaries — herdr, cmux, and the osascript the ghostty backend
# talks through — resolve to an ABSOLUTE path, never to "whatever the caller's PATH
# happened to hold". Scoped deliberately to those three: git, grep, sed and python3
# still ride PATH, because a checkout without them is broken in ways this guard can't
# rescue, and widening the blast radius was explicitly out of scope. The spinoff skill
# runs this script
# from a BACKGROUND agent, and a detached agent shell does not inherit the login
# shell's PATH — so on a machine where herdr is installed and its server is live,
# `command -v herdr` came back empty, $HERDR was empty, the herdr probe failed, and
# the run silently resolved LAUNCHER=none: worktree created, session never launched.
#
# Mirror image of the R8 decision recorded below. That one keeps a STALE HERDR_ENV=1
# from winning (announced but dead). This one keeps a LIVE HERDR_ENV=1 from LOSING to
# a binary we merely failed to find. Both are the same principle: the environment's
# announcement and the binary's reachability are separate facts, and neither one alone
# is allowed to decide.
#
# Order (R3): explicit override, then PATH, then a list of known install locations.
#
# Every candidate — the override included — must be a regular file AND executable
# (R15). `-x` alone is true of a DIRECTORY, so HERDR_BIN=/opt/homebrew/bin would have
# "resolved" and reproduced the original bug one layer down, with a launch that runs a
# directory. A SET override that fails the test resolves to EMPTY and deliberately
# does NOT fall through to PATH: someone who named a binary meant that binary, and
# quietly driving a different one is worse than not launching. The rejected value is
# recovered by resolve_bin_rejected below so a diagnostic can name it.
#
# The candidate directory list is read from $SPINOFF_BIN_PATHS (colon-separated), in
# the same spirit as $SPINOFF_READY_TIMEOUT_MS further down: an env knob whose reason
# to exist is that the behavior is otherwise untestable. Without it a stripped-PATH
# regression test still finds /opt/homebrew/bin/herdr on this machine, never reaches
# the unresolvable path, and passes for the wrong reason (KTD-10).
_bin_usable() { [ -n "${1:-}" ] && [ -f "$1" ] && [ -x "$1" ]; }

# _resolve_bin_scan <colon-list> <suffix> — echo the first usable candidate, or fail.
# Splitting is pure parameter expansion, deliberately: a resolver whose whole purpose
# is to not depend on PATH must not itself shell out to `tr`/`sed` to do the splitting.
# (Measured: with PATH scrubbed, a tr-based split died with "tr: command not found" and
# resolved nothing — the failure it exists to prevent, one level down.) Every test it
# uses is a shell builtin.
_resolve_bin_scan() {
  local rest="${1:-}" suffix="${2:-}" head
  while [ -n "$rest" ]; do
    head="${rest%%:*}"
    if [ "$head" = "$rest" ]; then rest=""; else rest="${rest#*:}"; fi
    [ -n "$head" ] || continue
    head="${head%/}$suffix"
    if _bin_usable "$head"; then printf '%s' "$head"; return 0; fi
  done
  return 1
}

# The default candidate directories, in ONE place. Both resolve_bin (which walks them)
# and _bin_search_locations (which names them in the ⚠) read this: two copies of the
# literal would let the diagnostic claim it searched somewhere resolution never looked
# the moment the default changes.
# `${VAR-default}`, NOT `${VAR:-default}`: an explicitly EMPTY SPINOFF_BIN_PATHS must
# mean "no known locations", not "give me the defaults back". The knob exists so a test
# can guarantee nothing resolves; with `:-` a caller that set it to "" would silently
# get /opt/homebrew/bin and resolve the host's real herdr, passing for the wrong reason.
_bin_paths() { printf '%s' "${SPINOFF_BIN_PATHS-/opt/homebrew/bin:/usr/local/bin:${HOME:-}/.local/bin}"; }

# resolve_bin <name> <override> [extra-candidates]
#   <override>         explicit path from the env (may be empty); wins outright (R2)
#   [extra-candidates] colon-separated FULL paths tried after the standard dirs, for
#                      the non-PATH installs (the cmux app bundle, /usr/bin/osascript)
# Echoes a validated ABSOLUTE path, or nothing. Never fails, never writes to stderr —
# deciding what an empty result MEANS belongs to the caller, not to resolution.
# The result is pinned absolute through abspath() for the same reason the handoff and
# transcript args are: resolution happens BEFORE the `--repo` cd below, so a relative
# candidate (a relative PATH entry, a relative override) would silently stop resolving
# the moment the cwd moves.
resolve_bin() {
  local name="$1" override="${2:-}" extra="${3:-}"
  local cand
  if [ -n "$override" ]; then
    _bin_usable "$override" && abspath "$override"
    return 0
  fi
  cand="$(command -v "$name" 2>/dev/null)"
  if _bin_usable "${cand:-}"; then abspath "$cand"; return 0; fi
  if cand="$(_resolve_bin_scan "$(_bin_paths)" "/$name")"; then
    abspath "$cand"; return 0
  fi
  if cand="$(_resolve_bin_scan "$extra" "")"; then abspath "$cand"; return 0; fi
  return 0
}

# resolve_bin_rejected <resolved> <override> — echo the override that was thrown out.
# The caller derives this rather than resolve_bin exporting it, because resolve_bin is
# consumed through command substitution and a subshell cannot set a variable its caller
# would see. The contract makes the derivation exact: a set override that passed the
# R15 test yields a non-empty path, so "override set AND result empty" is precisely the
# rejected case.
resolve_bin_rejected() { [ -n "${2:-}" ] && [ -z "${1:-}" ] && printf '%s' "$2"; return 0; }

# Liveness probes. herdr: the binary resolves AND `status server` reports running
# (a stale HERDR_ENV=1 must not win — R8). cmux: the binary is executable.
# ghostty: it has NO scripting CLI, so the thing that has to exist is the .app
# bundle AppleScript targets plus osascript to talk to it. Deliberately asks
# osascript NOTHING — a probe must never be what raises the macOS Automation
# dialog, which is why this checks the RESOLVED $OSASCRIPT (already validated as a
# regular executable file by resolve_bin) instead of running it. $GHOSTTY_APP and
# $OSASCRIPT are resolved next to $HERDR / $CMUX, below.
# herdr must NEVER be piped into an early-exiting reader to decide liveness. `grep -q`
# exits the instant it matches and closes the pipe, so herdr dies mid-write and exits
# non-zero — and under the `set -o pipefail` at the top of this file that non-zero
# becomes the pipeline's status, so the probe returns FALSE on a match that already
# succeeded. Measured 80-94 failures per 300 against a live server before this change.
#
# Do not look for one exit code: the signature is not stable across herdr releases.
# Observed 101 (a Rust broken-pipe panic, `failed printing to stdout`) on 0.8.0, and
# 141 (plain SIGPIPE, no stderr at all) on 0.8.2. Capture first, then test the text —
# that is correct for any of them, because no exit status reaches a conditional.
#
# The match is an exact `status: running` LINE, not a substring: the old
# `grep -qi running` also accepted "not running". herdr prints several lines, so the
# line may not be the first one.
_herdr_probe() {
  [ -n "${HERDR:-}" ] || return 1
  local _err
  _err="$(mktemp 2>/dev/null)" || _err="${TMPDIR:-/tmp}/spinoff-herdr-probe.$$"
  HERDR_PROBE_ERR_LOST=0
  if : > "$_err" 2>/dev/null; then
    HERDR_PROBE_OUT="$("$HERDR" status server 2>"$_err" || true)"
    HERDR_PROBE_ERR="$(cat "$_err" 2>/dev/null || true)"
    rm -f "$_err"
  else
    # No writable scratch file. Keep stdout (the match input) intact, but record that
    # stderr was DROPPED rather than let the report claim herdr printed nothing —
    # that would be a fresh false assertion, the class this change exists to remove.
    HERDR_PROBE_OUT="$("$HERDR" status server 2>/dev/null || true)"
    HERDR_PROBE_ERR=""
    HERDR_PROBE_ERR_LOST=1
  fi
  # Wrapping both sides in newlines lets one pattern match an exact line anywhere.
  case $'\n'"$HERDR_PROBE_OUT"$'\n' in
    *$'\nstatus: running\n'*) return 0 ;;
    *) return 1 ;;
  esac
}
_cmux_probe()  { [ -n "${CMUX:-}" ] && [ -x "$CMUX" ]; }
_ghostty_probe() { [ -n "${GHOSTTY_APP:-}" ] && [ -n "${OSASCRIPT:-}" ]; }

# The exit-5 evidence, split into a predicate and a printer because the two report
# sites need the presence answer BEFORE they print — one leads with a header, the
# other with a sentence — and each words the empty case for its own register.
_herdr_probe_said_something() {
  [ -n "${HERDR_PROBE_OUT:-}" ] || [ -n "${HERDR_PROBE_ERR:-}" ] || [ "${HERDR_PROBE_ERR_LOST:-0}" = 1 ]
}
# Pads EVERY line, not the string. herdr answers with five lines, so padding once left
# four of them flush against the margin and broke the block SKILL.md relays verbatim.
_herdr_probe_evidence() {
  local pad="$1" _l
  if [ -n "${HERDR_PROBE_OUT:-}" ]; then
    while IFS= read -r _l; do printf '%s%s\n' "$pad" "$_l" >&2; done <<<"$HERDR_PROBE_OUT"
  fi
  if [ -n "${HERDR_PROBE_ERR:-}" ]; then
    while IFS= read -r _l; do printf '%s%s\n' "$pad" "$_l" >&2; done <<<"$HERDR_PROBE_ERR"
  fi
  [ "${HERDR_PROBE_ERR_LOST:-0}" = 1 ] \
    && printf '%s(stderr could not be captured — no writable scratch file)\n' "$pad" >&2
  return 0
}

# ---- announced-but-unresolvable record (R5, R6, R17, KTD-3, KTD-8, KTD-9) ----
# An environment that DELIBERATELY announces a multiplexer, plus a binary we could not
# find, is a FAILED launch — not the "you're not in a multiplexer" skip. The two used
# to collapse into one line ("not inside cmux/herdr (or the CLI is missing) — skipping
# launch automation") at exit 0, so a background agent relaying the run said "done"
# for a spinoff that never launched anything. Splitting them is the whole point of
# this change: the unannounced session stays quiet and successful (R7), the announced
# one gets a named binary, the places searched, the override that fixes it, and a
# non-zero exit (R5/R6).
#
# Three deliberate restrictions, each one a case that MUST stay silent:
#  * KTD-3 — the check reads the RESOLVED variable ($HERDR / $CMUX), never the
#    resolution attempt. Under SPINOFF_TEST_SOURCE the resolver tests inject those
#    values directly, so the check is inert there and those six tests keep passing.
#  * KTD-9 — only HERDR_ENV=1 and CMUX_WORKSPACE_ID count as announcements. A process
#    sets those to say a multiplexer OWNS this session. Ghostty's TERM_PROGRAM /
#    GHOSTTY_RESOURCES_DIR / GHOSTTY_SURFACE_ID are set for every Ghostty window
#    whether or not a launch is wanted, and osascript does not exist off macOS at all
#    — keying a loud failure on either would turn ordinary sessions into exit-4
#    failures (R14).
#  * KTD-8 — recording is NOT acting. Resolution only records WHAT the environment
#    announced and which announced backend was unresolvable; the warning, the
#    INCOMPLETE header and the non-zero exit fire later, and only once
#    resolve_launcher has settled on `none`. Without that split, a session announcing
#    both herdr and cmux where only cmux resolves would launch perfectly and still
#    exit non-zero (R17) — the herdr→cmux fallthrough right below is pinned as
#    correct by the "HERDR_ENV set but server dead + cmux present -> cmux" test.
# HERDR_ENV=0 (R8) never reaches the recorder at all — it isn't `=1`. A resolvable
# binary whose probe merely failed DOES reach it and records only $ANNOUNCED_*, never
# $LOUD_*. That is now a LOUD exit 5, not a silent exit 0: $ANNOUNCED_* alone is
# enough to fail the run, and $LOUD_* only chooses which failure it is.
HERDR_PROBE_OUT="" # what the last _herdr_probe read on stdout — the exit-5 evidence
HERDR_PROBE_ERR="" # and on stderr, where herdr reports an unreachable server
HERDR_PROBE_ERR_LOST=0 # 1 when stderr was dropped, so the report says so
LOUD_BIN=""        # binary an announcement asked for that resolution could not find
LOUD_ANNOUNCE=""   # the env var that announced it, rendered for a human
LOUD_OVERRIDE=""   # the env var that pins it explicitly
LOUD_REJECTED=""   # a SET override that was thrown out by the R15 test (different fix)
LOUD_SEARCHED=""   # every location resolution tried, in order
ANNOUNCED_BIN=""   # a backend the env announced, whether or not it resolved
ANNOUNCED_BY=""    # the env var that announced it, rendered for a human

# _bin_search_locations [extra-candidates] — the list resolve_bin walks, rendered for
# a human. It lives here rather than inside resolve_bin because resolve_bin is consumed
# through command substitution and must stay silent: deciding what an empty result
# MEANS, and how to describe it, belongs to the caller (R3).
_bin_search_locations() {
  printf '$PATH (%s), then $SPINOFF_BIN_PATHS (%s)' \
    "${PATH:-<empty>}" \
    "$(_bin_paths)"
  [ -n "${1:-}" ] && printf ', then %s' "$1"
  return 0
}

# _record_loud <name> <resolved> <announce-text> <override-var> <rejected> [extras]
# Records nothing when the binary resolved. First announcement wins: precedence runs
# herdr → cmux, so the diagnostic names the backend the environment asked for first.
#
# $ANNOUNCED_* is recorded SEPARATELY and unconditionally, including when the binary
# resolved fine. The two answer different questions, and the gate reads them in that
# order: $ANNOUNCED_* is "did anything announce itself at all" and DECIDES whether a
# no-launch run is a failure; $LOUD_* is "which announced backend could not be found"
# and only SELECTS which failure (exit 4, binary missing) versus the other (exit 5,
# resolved but unusable). Without the split, a herdr that resolves but whose server is
# down fell through to a line claiming nothing announced — false, and the same
# lying-message defect this change exists to remove.
#
# The two records use DIFFERENT precedence and can name different backends:
# $ANNOUNCED_* is first-announced-wins, $LOUD_* is first-unresolved-wins. A session
# announcing herdr (resolved, server dead) and cmux (binary missing) ends with
# ANNOUNCED_BIN=herdr and LOUD_BIN=cmux. That run exits 4 and names cmux only —
# correct, because fixing CMUX_BIN restores a launch. All wording in the loud path
# therefore comes from $LOUD_BIN whenever it is set, so the two records can never
# describe different backends in the same run.
_record_loud() {
  if [ -z "$ANNOUNCED_BIN" ]; then ANNOUNCED_BIN="$1"; ANNOUNCED_BY="$3"; fi
  [ -z "${2:-}" ] || return 0      # it resolved — not an announced-and-missing case
  [ -z "$LOUD_BIN" ] || return 0   # already recorded a higher-precedence announcement
  LOUD_BIN="$1"; LOUD_ANNOUNCE="$3"; LOUD_OVERRIDE="$4"; LOUD_REJECTED="${5:-}"
  LOUD_SEARCHED="$(_bin_search_locations "${6:-}")"
  return 0
}

# resolve_launcher — collapse env + flag into a single $LAUNCHER (KTD-2).
# Precedence for `auto`: herdr (live) > cmux > ghostty > none. A forced --launcher
# herdr|cmux|ghostty skips the env-keyed detection but STILL probes the chosen
# backend, falling back to auto-detection (never hard-erroring) on probe failure (R8).
resolve_launcher() {
  case "$LAUNCHER" in
    herdr) if _herdr_probe; then LAUNCHER=herdr; return; fi
           echo "  ⚠ --launcher herdr requested but herdr did not report a running server — falling back to auto-detection" >&2 ;;
    cmux)  if _cmux_probe; then LAUNCHER=cmux; return; fi
           echo "  ⚠ --launcher cmux requested but the cmux CLI isn't available — falling back to auto-detection" >&2 ;;
    ghostty) if _ghostty_probe; then LAUNCHER=ghostty; return; fi
           echo "  ⚠ --launcher ghostty requested but Ghostty.app / osascript isn't available — falling back to auto-detection" >&2 ;;
  esac
  # Record, don't act (KTD-8). This runs BEFORE the detection below so the record is
  # taken from the announcements as they stand, and is read only after $LAUNCHER has
  # settled — a run that goes on to launch through another announced backend never
  # looks at it (R17).
  # An explicit --launcher is a LOUDER launch request than any env var — the user named
  # the backend — so record it FIRST and let it win $ANNOUNCED_* precedence, so the
  # diagnosis names what they actually asked for. Only a forced launcher whose probe
  # FAILED reaches this line; a successful one returned above and never lands here.
  #
  # Without this, the flag route stayed open into the exact defect the env route was
  # just closed against: `--launcher herdr` in a session announcing nothing launched
  # nothing, printed "no multiplexer announced this session" — false, the user had just
  # named one — and exited 0 with a tick. Closing one route and leaving the other is
  # the enumeration this gate exists to stop doing.
  # A forced backend that can carry a REAL cause is recorded first: it names a binary,
  # so it produces either an actionable exit-4 ("set CMUX_BIN") or an exit-5 naming the
  # backend the user chose. Either way the diagnosis is about the thing they asked for.
  case "${FORCED_LAUNCHER:-auto}" in
    herdr) _record_loud herdr "${HERDR:-}" '--launcher herdr' HERDR_BIN "${HERDR_REJECTED:-}" ;;
    cmux)  _record_loud cmux "${CMUX:-}" '--launcher cmux' CMUX_BIN "${CMUX_REJECTED:-}" \
                        /Applications/cmux.app/Contents/Resources/bin/cmux ;;
  esac
  [ "${HERDR_ENV:-}" = 1 ] \
    && _record_loud herdr "${HERDR:-}" 'HERDR_ENV=1' HERDR_BIN "${HERDR_REJECTED:-}"
  [ -n "${CMUX_WORKSPACE_ID:-}" ] \
    && _record_loud cmux "${CMUX:-}" 'CMUX_WORKSPACE_ID' CMUX_BIN "${CMUX_REJECTED:-}" \
                    /Applications/cmux.app/Contents/Resources/bin/cmux
  # Any OTHER forced backend announces itself LAST, and only if nothing else has. This
  # is the KTD-9 note at the ghostty resolution coming due — ghostty's ENV vars stay
  # excluded (set for every Ghostty window, they announce nothing) while the FLAG is a
  # deliberate request and belongs in the loud path.
  #
  # It defers deliberately. `--launcher ghostty` is what SKILL.md tells you to reach for
  # when herdr's server is dead, so that exact run has BOTH a forced ghostty and a live
  # HERDR_ENV=1. Recording ghostty first would replace herdr's diagnosis — which hands
  # over `herdr status server`, the one command that separates a stopped server from a
  # server did not report running — with a ghostty message that has no remedy at all.
  # The exit code is 5 either way, so nothing checking status would have caught that.
  # Whatever announced a cause worth acting on keeps the message.
  #
  # The `*)` is a catch-all rather than a `ghostty)` arm on purpose: a backend added to
  # the --launcher validation and the probe case but forgotten here would otherwise
  # announce nothing and exit 0 having launched nothing — the very defect this gate
  # closes, re-opened by omission. Default-deny here too.
  case "${FORCED_LAUNCHER:-auto}" in
    auto|herdr|cmux) ;;
    *) [ -z "$ANNOUNCED_BIN" ] \
         && { ANNOUNCED_BIN="$FORCED_LAUNCHER"; ANNOUNCED_BY="--launcher $FORCED_LAUNCHER"; } ;;
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
  # Guarded: --launcher cmux only probes the BINARY, so this is reachable with the
  # env var unset, and `set -u` would abort mid-run leaving an orphan worktree and
  # no summary block for the skill to relay.
  WS="${CMUX_WORKSPACE_ID:-}"
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
# Workspace flag as an array: the split fallback runs with no workspace (cmux
# resolves "current"), and passing `--workspace ""` instead of omitting it made the
# fallback apply to one of four calls.
launcher_launch_agent_cmux() {
  LB_READY=0
  local err
  local -a WSA=(); [ -n "${LAUNCH_WS:-}" ] && WSA=(--workspace "$LAUNCH_WS")
  # Not silenced. This call spent a release discarding its own errors, so a rename
  # that never landed was indistinguishable from one that did.
  local rerr
  if ! rerr="$("$CMUX" rename-tab --surface "$LAUNCH_SFC" "${WSA[@]}" --title "$LABEL" 2>&1)"; then
    echo "  ⚠ cmux surface could not be named: $rerr" >&2
    note_unnamed "cmux $LAUNCH_WHERE surface $LAUNCH_SFC"
  fi
  if ! err="$("$CMUX" send --surface "$LAUNCH_SFC" "${WSA[@]}" "$LAUNCH_CMD" 2>&1)"; then
    KICKOFF_OK=0
    echo "  ⚠ cmux send failed while launching the briefed session: $err" >&2
    return
  fi
  if ! err="$("$CMUX" send-key --surface "$LAUNCH_SFC" "${WSA[@]}" enter 2>&1)"; then
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
  local -a WSR=(); [ -n "${LAUNCH_WS:-}" ] && WSR=(--workspace "$LAUNCH_WS")
  local screen
  for _ in $(seq 1 "$(( SPINOFF_READY_TIMEOUT_MS / 1000 + 1 ))"); do
    sleep 1
    screen="$("$CMUX" read-screen --surface "$LAUNCH_SFC" "${WSR[@]}" 2>/dev/null)"
    case "$screen" in
      *"trust this folder"*|*"Is this a project you created"*)
        # See the herdr path: the folder-trust prompt blocks a fresh worktree before
        # claude will process a command-line prompt.
        case "${SPINOFF_FOLDER_TRUST:-accept}" in
          reject) "$CMUX" send-key --surface "$LAUNCH_SFC" "${WSR[@]}" escape >/dev/null 2>&1
                  step "  … folder-trust prompt: declined (SPINOFF_FOLDER_TRUST=reject)" ;;
          abort)  step "  … folder-trust prompt is up and SPINOFF_FOLDER_TRUST=abort — leaving it for you"; return ;;
          *)      "$CMUX" send-key --surface "$LAUNCH_SFC" "${WSR[@]}" enter >/dev/null 2>&1
                  step "  … folder-trust prompt: accepted for this worktree" ;;
        esac
        # Let the screen redraw before the next poll, or the same prompt is re-read
        # and a second Enter lands in the session.
        sleep 2 ;;
      *"new MCP servers found"*|*"Select any you wish to enable"*)
        # Mirrors the herdr arm. cmux previously had no MCP handling at all, while the
        # launch region's comment claimed readiness is what enables MCP servers — true
        # of herdr, false here, so an MCP modal burned the full ceiling on cmux.
        case "${SPINOFF_MCP_MODAL:-accept}" in
          reject) "$CMUX" send-key --surface "$LAUNCH_SFC" "${WSR[@]}" escape >/dev/null 2>&1
                  step "  … MCP trust modal: rejected all (SPINOFF_MCP_MODAL=reject)" ;;
          abort)  step "  … MCP trust modal is up and SPINOFF_MCP_MODAL=abort — leaving it"; return ;;
          *)      "$CMUX" send-key --surface "$LAUNCH_SFC" "${WSR[@]}" enter >/dev/null 2>&1
                  step "  … MCP trust modal: accepted the pre-checked default (new worktree = new project path)" ;;
        esac
        sleep 2 ;;
      *"bypass permissions"*|*"shift+tab to cycle"*|*"? for shortcuts"*) LB_READY=1; break ;;
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
      # R14 applies to every backend. Whether rename-tab accepts a PANE ref (this
      # is `new-pane`, not `new-surface`) is unverified, so attempt it and report
      # the surface honestly when it does not take, rather than assume either way.
      local verr
      if ! verr="$("$CMUX" rename-tab --surface "$RIGHT_PANE" --workspace "$LAUNCH_WS" --title "$VIEWER_LABEL" 2>&1)"; then
        note_unnamed "cmux handoff viewer pane $RIGHT_PANE"
      fi
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
  # Recover the live/frozen label: the helper runs in a subshell, so its own
  # assignment cannot escape. Derive it here instead of always reporting "frozen".
  if [ -n "$ws" ] && [ "$ws" != "${HERDR_WORKSPACE_ID:-}" ]; then HERDR_WS_SOURCE=live; else HERDR_WS_SOURCE="${HERDR_WS_SOURCE:-frozen}"; fi
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
  # Name the pane BEFORE the launch: afterwards it holds a live shell writing its
  # own title, and `pane rename` claims no pin against that. This runs for the tab
  # and workspace targets too, not only the split — a pane's label is a distinct
  # object from the tab's and the workspace's, and it is unnamed on all three today.
  # The label is a bare variadic positional here, so it must stay ONE quoted word;
  # an end-of-options `--` is NOT consumed and would land in the label.
  local rout rlabel
  if ! rout="$("$HERDR" pane rename "$pane" "$LABEL" 2>&1)"; then
    echo "  ⚠ herdr pane could not be named: $rout" >&2
    note_unnamed "herdr $LAUNCH_WHERE pane $pane"
  else
    # Same variable carries the success body — the reply echoes what it stored.
    rlabel="$(printf '%s' "$rout" | _herdr_json 'result.pane.label')"
    if [ "$rlabel" != "$LABEL" ]; then
      echo "  ⚠ herdr pane $pane reports the name '$rlabel', not '$LABEL'" >&2
      note_unnamed "herdr $LAUNCH_WHERE pane $pane"
    fi
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
      *"trust this folder"*|*"Is this a project you created"*)
        # DIFFERENT modal from the MCP one below, and the one that actually blocks a
        # fresh worktree: claude asks whether it trusts the FOLDER before it will
        # process anything, including a prompt supplied on the command line. Found by
        # a real end-to-end run — every stub in the suite emits a ready footer, so no
        # test could have surfaced it. The default option is "Yes, I trust this
        # folder"; a worktree of a repo the user already works in is the same trust
        # they have already given, but it IS a trust prompt, so it is disclosed.
        case "${SPINOFF_FOLDER_TRUST:-accept}" in
          reject) "$HERDR" pane send-keys "$HERDR_PANE" Escape >/dev/null 2>&1
                  step "  … folder-trust prompt: declined (SPINOFF_FOLDER_TRUST=reject) — session will not run here" ;;
          abort)  step "  … folder-trust prompt is up and SPINOFF_FOLDER_TRUST=abort — leaving it for you"; return ;;
          *)      "$HERDR" pane send-keys "$HERDR_PANE" Enter >/dev/null 2>&1
                  step "  … folder-trust prompt: accepted for this worktree (same trust as the parent repo)" ;;
        esac
        sleep 2 ;;
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
    # A fixed name, not the work label: the viewer holds the brief, not the work, and
    # two identically-named splits side by side is the problem this convention fixes.
    "$HERDR" pane rename "$view" "$VIEWER_LABEL" >/dev/null 2>&1 \
      || note_unnamed "herdr handoff viewer pane $view"
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

		else if verb is "set-title" then
			-- argv: set-title <terminal-ref> <tab|surface> <title>
			-- `name` is read-only on window, tab and terminal (sdef access="r"), so
			-- the title is set through `perform action`, which also pins it against
			-- the shell's own OSC writes. Set and read back in ONE event: the tab
			-- handle then never crosses the shell boundary, and there is no second
			-- event for the title to change under.
			set t to my findTerminal(item 2 of argv)
			if t is missing value then return "error=surface-not-found"
			set theScope to item 3 of argv
			set theTitle to item 4 of argv
			if theScope is "tab" then
				perform action ("set_tab_title:" & theTitle) on t
				-- A terminal exposes no back-pointer to its tab, so the tab is found
				-- by scanning. Reading the terminal's name here would never match:
				-- a tab-scope set leaves it at the shell's own title.
				repeat with w in windows
					repeat with tb in tabs of w
						try
							repeat with tt in terminals of tb
								if (id of tt as text) is (id of t as text) then
									return "name=" & (name of tb as text)
								end if
							end repeat
						end try
					end repeat
				end repeat
				return "error=tab-not-found"
			else
				perform action ("set_surface_title:" & theTitle) on t
				return "name=" & (name of t as text)
			end if

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
  # The RESOLVED osascript, not a bare `osascript` — see the resolver note at the top:
  # a background agent's PATH may not contain /usr/bin. `${OSASCRIPT:-}` because this
  # function is also reachable when the script is SOURCED for tests, where the
  # resolution region below never runs and `set -u` would abort on a bare read.
  if ! out="$("${OSASCRIPT:-}" "$GHOSTTY_SCPT" "$@" 2>&1)"; then
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
  # Named AFTER the launch because on ghostty creation IS the launch — there is no
  # surface to name before it. Read LAUNCH_WHERE here, not GHOSTTY_PLACE: a split
  # whose --from-surface did not resolve fell back to a tab above and rewrote it.
  _ghostty_name_surface
}

# Sets the title and confirms it landed. `perform action` returns true when it did
# nothing — measured on a terminal created ~1s earlier, where the title stayed at the
# shell's own — so the returned name is the only evidence. The first attempt missing
# is the expected path, not the exception, which is why this polls rather than
# retrying once immediately.
_ghostty_name_surface() {
  local scope=tab
  [ "$LAUNCH_WHERE" = split ] && scope=surface
  if ! _ghostty_probe_titles; then
    note_unnamed "ghostty $LAUNCH_WHERE terminal $GHOSTTY_TERM (no set_tab_title action on this Ghostty)"
    return
  fi
  _ghostty_set_title "$GHOSTTY_TERM" "$scope" "$LABEL" && return
  case "$_GST_STATE" in
    dead)
      KICKOFF_OK=0
      # Clear the handle too: launcher_wait_ready_ghostty guards on it being
      # non-empty, and a dead-but-set handle makes it poll for a pid that can
      # never come until the 180s ceiling — three silent minutes confirming a
      # death the run has already diagnosed.
      GHOSTTY_TERM=""
      echo "  ⚠ the ghostty terminal that was just launched no longer exists — the session did not survive" >&2
      return ;;
  esac
  echo "  ⚠ ghostty $LAUNCH_WHERE could not be named (reports '${_GST_OBSERVED:-}')" >&2
  note_unnamed "ghostty $LAUNCH_WHERE terminal $GHOSTTY_TERM"
}

# Sets a title and returns 0 only when the backend reports the title actually landed.
# Sets $_GST_STATE to `dead` when the handle no longer resolves, so a caller that
# cares about liveness can tell that apart from a title that would not stick.
# Retries because `perform action` returns true when it did nothing: measured on a
# terminal created ~1s earlier, where the title stayed at the shell's own. A first
# miss is the expected path, not the exception.
_ghostty_set_title() {
  local term="$1" scope="$2" want="$3" out i=0
  _GST_STATE=ok; _GST_OBSERVED=""
  while [ "$i" -lt 3 ]; do
    out="$(_ghostty_run set-title "$term" "$scope" "$want")"
    # A dead handle is reported on the FIRST reply, not after the retries: retrying
    # something already gone only delays the report.
    case "$out" in
      *error=surface-not-found*) _GST_STATE=dead; return 1 ;;
    esac
    _GST_OBSERVED="$(_ghostty_field "$out" name)"
    [ "$_GST_OBSERVED" = "$want" ] && return 0
    i=$((i+1)); sleep 1
  done
  _GST_STATE=mismatch
  return 1
}

# Probed through the resolved bundle, never a bare `ghostty` on PATH: this script
# resolves only GHOSTTY_APP (a .app directory) and osascript, and a background
# agent's PATH may not carry /usr/bin at all. A probe that cannot RUN is not the
# same as an action that is absent — only the latter means "no naming support".
_ghostty_probe_titles() {
  local bin="${GHOSTTY_APP:-}/Contents/MacOS/ghostty" actions
  [ -x "$bin" ] || return 0
  actions="$("$bin" +list-actions 2>/dev/null)" || return 0
  case "$actions" in *set_tab_title*) return 0 ;; *) return 1 ;; esac
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
    # Fixed name, same reason as the herdr viewer. Its own surface, so surface scope.
    # Goes through the shared setter: a bare `_ghostty_field … || note_unnamed` could
    # never fire, because _ghostty_field ends in `head` and always exits 0.
    _ghostty_set_title "$view" surface "$VIEWER_LABEL" \
      || note_unnamed "ghostty handoff viewer terminal $view"
    # Leave the user in the agent, not in the pager — the equivalent of the other
    # backends' --no-focus on the viewer split. Separate Apple event, for the reason
    # given in the split verb. Best-effort.
    _ghostty_run focus "$GHOSTTY_TERM" >/dev/null || true
    step "  handoff viewer: $view"
  else
    echo "  ⚠ split a viewer terminal but ghostty returned no handle for it — continuing without the handoff render" >&2
  fi
}

# _announced_unlaunched — the default-deny gate, as a function so it can be tested.
# True when something announced a backend and nothing launched. It reads ONLY the
# announcement and the settled launcher: no backend name, no probe. That is the whole
# invariant, and keeping it in one testable place is what lets a test prove it with a
# backend name that does not exist yet — which is the only way to tell this apart from
# an implementation that enumerates the causes it happens to know about.
_announced_unlaunched() { [ "$LAUNCHER" = none ] && [ -n "$ANNOUNCED_BIN" ]; }

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
# Keep what the user asked for. resolve_launcher overwrites $LAUNCHER with what it
# actually settled on, and by the time the loud gate runs there is otherwise no way to
# tell "detection found nothing" from "the user named a backend and it didn't work".
FORCED_LAUNCHER="$LAUNCHER"

[ -n "$NAME" ] || die "missing --name <kebab-feature-name>"
# $LABEL reaches `herdr pane rename "$pane" "$LABEL"` as a BARE positional. Measured
# on herdr 0.8.0 a leading '-' is in fact accepted there as a positional, so this
# guard is belt-and-braces against a future backend that parses it as a flag, not a
# live hazard. Kept because the label now reaches more positional call sites, not
# fewer. NOTE: this runs before the default is derived, so it guards user input only —
# `--name '---'` de-kebabs to nothing and falls back to a raw '---' label that never
# passes through here.
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

# ---- resolve the launcher binaries (R1-R3, R15) ------------------------------
# All three go through resolve_bin: $*_BIN override, then PATH, then $SPINOFF_BIN_PATHS,
# then the tool's own non-PATH install location. See the long note at the resolver
# itself for WHY absolute resolution is mandatory here (a background agent's PATH is
# not the login shell's) and why a set-but-invalid override resolves to empty.
#
# The scalar `CMUX="…"` / `HERDR="…"` spelling is load-bearing, not style:
# cli-drift.test.sh extracts every backend call site by grepping for the literal
# spellings ("$CMUX", "$HERDR"), so array-ifying these silently zeroes that extraction
# and the drift gate stops protecting anything (KTD-6 — already cost 4 verified calls
# once, see the f0b5d35 commit message).

# cmux: PATH (Homebrew, Linux), then the macOS app bundle path.
CMUX="$(resolve_bin cmux "${CMUX_BIN:-}" /Applications/cmux.app/Contents/Resources/bin/cmux)"
CMUX_REJECTED="$(resolve_bin_rejected "$CMUX" "${CMUX_BIN:-}")"

# herdr: a missing binary means the herdr backend is unavailable regardless of
# HERDR_ENV (KTD-2). No app-bundle fallback — herdr installs onto PATH only.
HERDR="$(resolve_bin herdr "${HERDR_BIN:-}")"
HERDR_REJECTED="$(resolve_bin_rejected "$HERDR" "${HERDR_BIN:-}")"

# osascript: the ghostty backend's only transport (R4). /usr/bin/osascript is where
# macOS ships it, but it is resolved rather than hardcoded so $OSASCRIPT_BIN can pin it
# the same way as the other two. No paired *_REJECTED scalar here, deliberately: ghostty
# is excluded from the loud path (KTD-9 — its env vars are set for every Ghostty window
# rather than as a launch request), so nothing would ever read one. If ghostty is ever
# promoted to a deliberate announcement, add it then.
OSASCRIPT="$(resolve_bin osascript "${OSASCRIPT_BIN:-}" /usr/bin/osascript)"

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

# Display name for every surface this run opens. The convention is `Ticket: Title`;
# the skill resolves the ticket and passes the whole thing as --label. Absent that,
# the default is the de-kebabed name with NO repo token: the pre-colon slot is
# reserved for a real ticket, so a label without one is the signal that the work is
# untracked. The raw-$NAME fallback is load-bearing — a label that resolved to
# empty would pin a blank tab, which reads worse than any default.
if [ -z "$LABEL" ]; then
  _lbl="${NAME//-/ }"
  _lbl="${_lbl#"${_lbl%%[![:space:]]*}"}"
  _lbl="${_lbl%"${_lbl##*[![:space:]]}"}"
  if [ -n "$_lbl" ]; then
    LABEL="$(printf '%s' "${_lbl:0:1}" | tr '[:lower:]' '[:upper:]')${_lbl:1}"
  else
    LABEL="$NAME"
  fi
  unset _lbl
fi

step "repo:        $MAIN_ROOT"
step "new branch:  $BRANCH"
step "worktree:    $WORKTREE"
step "label:       $LABEL"   # requested, not yet applied — surfaces are named at launch

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
# One human-readable surface descriptor per line, appended by every backend that
# fails to name a surface and read by the summary. Declared here, once, because
# three producers write it — without a single declared shape they invent three.
UNNAMED_SURFACES=""
VIEWER_LABEL="Handoff"
note_unnamed() { UNNAMED_SURFACES="${UNNAMED_SURFACES}${UNNAMED_SURFACES:+$'\n'}  - $1"; }
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

LAUNCH_CMD="cd $(shq "$WORKTREE") && claude --name $(shq "$LABEL") \"\$(cat $(shq "$BRIEF_FILE"))\""
# Recovery line for the summary: never references the brief file, so it stays
# runnable even if that file is gone.
MANUAL_CMD="cd $(shq "$WORKTREE") && claude --name $(shq "$LABEL")"

# Detect the backend once (KTD-2), then drive the launch through the neutral
# verbs. resolve_launcher's precedence (herdr live > cmux > none) subsumes the old
# CMUX_WORKSPACE_ID gate; LAUNCHER=none reproduces the previous no-op fallback
# (worktree + handoff still produced, summary prints the manual line).
resolve_launcher

# Now — and only now — is the recorded announcement actually a failure (KTD-8).
#
# The gate is DEFAULT-DENY, and that shape is the point. It asks one question — did
# the environment announce a backend, and did nothing launch? — and any yes is a
# failure. It does NOT enumerate the reasons a launch can fail to happen. An earlier
# version of this block enumerated, and the case it forgot (a resolvable herdr whose
# server is down) exited 0 with no ⚠ for two releases: indistinguishable from a
# session that simply isn't in a multiplexer. Enumerating known-bad states is
# default-allow, and the unenumerated state leaks by construction. So the cause is
# read INSIDE the gate, where it selects wording and exit code only — a reason nobody
# has thought of yet still lands here and still fails loudly, with generic wording.
#
# Three cases reach this line with $LAUNCHER = none and stay silent at exit 0, all
# three because nothing announced anything: an HERDR_ENV=0 session (R8 — it isn't
# `=1`, so it never reaches the recorder), a ghostty-only session (R14 — ghostty vars
# aren't announcements, KTD-9), and a session in no multiplexer at all (R7). A fourth
# case reaches this line with $LAUNCHER set: a run that launched through a DIFFERENT
# announced backend, which never enters the gate (R17).
#
# A forced --launcher that PASSES its probe returns from resolve_launcher before the
# record is taken, so it never enters the gate either. That early return is what keeps
# `--launcher ghostty` usable inside a herdr session; do not hoist the record above it.
ANNOUNCED_UNLAUNCHED=0
LAUNCH_UNRESOLVED=0
if _announced_unlaunched; then
  ANNOUNCED_UNLAUNCHED=1
fi
if [ "$ANNOUNCED_UNLAUNCHED" = 1 ] && [ -n "$LOUD_BIN" ]; then
  LAUNCH_UNRESOLVED=1
  echo "  ⚠ could not resolve \`$LOUD_BIN\`, and this session announced it ($LOUD_ANNOUNCE) —" >&2
  echo "    NOT launching, and NOT calling that a skip. The worktree and handoff are still made." >&2
  if [ -n "$LOUD_REJECTED" ]; then
    # A SET override that failed the R15 file+executable test. Different diagnosis,
    # different fix: don't tell someone to set a variable they already set. And do NOT
    # print the searched list here — a set override short-circuits PATH and
    # $SPINOFF_BIN_PATHS entirely (resolve_bin returns at the override), so claiming we
    # searched them would be false. Lying about where we looked is the same defect class
    # as lying about whether we launched.
    echo "    $LOUD_OVERRIDE is set to '$LOUD_REJECTED', which is not an executable file — fix or unset it." >&2
    echo "    (a set $LOUD_OVERRIDE wins outright, so \$PATH and \$SPINOFF_BIN_PATHS were not searched.)" >&2
  else
    echo "    searched: $LOUD_SEARCHED" >&2
    echo "    fix: set $LOUD_OVERRIDE to the binary's absolute path (e.g. $LOUD_OVERRIDE=/opt/homebrew/bin/$LOUD_BIN)," >&2
    echo "         or add its directory to \$SPINOFF_BIN_PATHS." >&2
  fi
elif [ "$ANNOUNCED_UNLAUNCHED" = 1 ]; then
  # The other side of the gate: the binary resolved, so there is nothing to fix on
  # $PATH — the backend itself would not take the launch. Today that means herdr's
  # server is not running (`_herdr_probe` matches a `status: running` line). The
  # first line is deliberately cause-NEUTRAL so it stays true if a future backend
  # reaches this branch for some other reason; the named remedy follows it as the
  # known cause rather than the definition of the failure.
  echo "  ⚠ \`$ANNOUNCED_BIN\` announced this session ($ANNOUNCED_BY) but would not take the launch —" >&2
  echo "    NOT launching, and NOT calling that a skip. The worktree and handoff are still made." >&2
  if [ "$ANNOUNCED_BIN" = herdr ]; then
    # Report the EVIDENCE, never a mechanism. The previous wording asserted the server
    # "did not answer THIS process" and blamed a detached shell — a cause nobody had
    # established. It sent three separate sessions hunting a socket-reachability
    # problem that did not exist, because `herdr status server` answers `running`
    # right before and after a failing run, which the message framed as CONFIRMING
    # the theory rather than refuting it. Print what herdr actually said and stop.
    echo "    the binary resolved fine; herdr did not report a running server." >&2
    if _herdr_probe_said_something; then
      echo "    herdr reported:" >&2
      _herdr_probe_evidence "      "
    else
      echo "    herdr printed nothing on stdout or stderr." >&2
    fi
    echo "    the probe needs a \`status: running\` line and did not get one. If the server is" >&2
    echo "    down, start it and re-run; otherwise use the manual line below." >&2
  elif [ "$ANNOUNCED_BIN" = ghostty ]; then
    # Ghostty has no server to be up or down: `_ghostty_probe` fails ONLY when the .app
    # or osascript did not resolve. Saying "the binary resolved fine" here would be
    # exactly backwards — a false cause in the message, which is the defect this whole
    # file exists to remove. Name the piece that is actually missing.
    if [ -z "${GHOSTTY_APP:-}" ]; then
      echo "    Ghostty.app was not found (looked where \$GHOSTTY_RESOURCES_DIR points," >&2
      echo "    then /Applications and ~/Applications)." >&2
    fi
    if [ -z "${OSASCRIPT:-}" ]; then
      echo "    osascript was not found — set \$OSASCRIPT_BIN to its absolute path." >&2
    fi
  else
    echo "    the backend did not pass its readiness probe." >&2
  fi
fi

if [ "$LAUNCHER" = "none" ]; then
  # Two ways to land here, and each gets its OWN wording. Collapsing them is the
  # original bug in miniature: "or the CLI is missing" covered a benign state and a
  # broken one at once, and a relay of this run said "done" when nothing launched.
  #  1. anything announced — the gate above already spoke with a named cause and this
  #     run is going to exit non-zero, so stay quiet here. Saying "skipping launch
  #     automation" beside a failing exit would re-create the exact skip-versus-failure
  #     conflation this block exists to remove, and it is the first line a user reads.
  #  2. genuinely nothing announced (R7) — the only case that gets the benign line,
  #     and the only one that is still a legitimate worktree-only spinoff at exit 0.
  if [ "$ANNOUNCED_UNLAUNCHED" = 1 ]; then
    :
  else
    step "no multiplexer announced this session — skipping launch automation"
  fi
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
# Only then can an unsubmitted kickoff be a failure. A LAUNCHER=none run is a
# legitimate worktree-only spinoff and still "complete" — but only when nothing
# announced a backend; when something did, $ANNOUNCED_UNLAUNCHED carries that failure.
BRIEF_ATTEMPTED=0
# Attempted means "a backend was resolved and we tried to launch", NOT "a surface
# came up". Gating on $LAUNCH_SFC meant every surface-creation failure — cmux
# new-surface, herdr tab create, a workspace whose pane never registers, a dead
# --from-surface — skipped the not-briefed gate and printed a tick. This flag and
# $ANNOUNCED_UNLAUNCHED can never both be 1: this one requires LAUNCHER != none and
# that one requires LAUNCHER = none, which is what keeps exit 3 disjoint from 4 and 5.
[ "$LAUNCHER" != "none" ] && BRIEF_ATTEMPTED=1

# NEVER render an unbriefed session as success. The skill mandates relaying this
# block verbatim, so a failure formatted as a success line inside a ✓ block is a
# failure that reaches the user as "done" — which is exactly how the staged-kickoff
# bug survived. Header + exit code both tell the truth.
echo
echo "════════════════════════════════════════════════════════"
if [ "$BRIEF_ATTEMPTED" = "1" ] && [ "$KICKOFF_OK" != "1" ]; then
  echo "⚠ Spinoff INCOMPLETE — worktree is ready, session is NOT briefed"
elif [ "${ANNOUNCED_UNLAUNCHED:-0}" = "1" ]; then
  # The header has to learn this flag too, not just the exit at the tail (KTD-5): in
  # the loud case $LAUNCHER is none, so BRIEF_ATTEMPTED stays 0, and teaching only the
  # tail would print "✓ Spinoff complete" alongside a non-zero exit — a block the skill
  # relays verbatim, claiming success for a run that launched nothing. It reads the
  # GENERALIZED flag, not the exit-4-specific one, so every announced-but-unlaunched
  # cause is covered by construction rather than by remembering to add each new one.
  echo "⚠ Spinoff INCOMPLETE — worktree is ready, no session was launched"
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
if [ "$KICKOFF_OK" != "1" ]; then
  SESS_STATE="NOT briefed — the launch did not carry the brief"
elif [ "$LB_READY" != "1" ]; then
  # The launch succeeded, but claude never drew a usable prompt. A real end-to-end
  # run showed exactly what that means: a modal (folder-trust) can sit in front of
  # the session, and claude does not process its command-line prompt until answered.
  # So an unconfirmed prompt is UNVERIFIED, never a success — claiming "briefed"
  # here is the same false-success class this change set out to remove.
  SESS_STATE="open + briefed (a dialog may still be up — answer it and the brief runs)"
else
  SESS_STATE="open + briefed"
fi
VIEWER_NOTE=""; [ "$VIEWER_OK" = "1" ] && VIEWER_NOTE=" (handoff viewer alongside)"
# Printed inside the relayed block, not via step() or a stderr warning: R12 puts
# this in the summary, and those two surfaces land above it and beside it.
if [ -n "$UNNAMED_SURFACES" ]; then
  echo "  went unnamed:"
  printf '%s\n' "$UNNAMED_SURFACES"
fi
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
  # Name the REAL cause. "not inside cmux/herdr" was a lie in the loud case — the
  # session was inside one and said so; what failed was finding the binary.
  if [ "${LAUNCH_UNRESOLVED:-0}" = "1" ]; then
    echo "  launch:    NOT automated — \`$LOUD_BIN\` could not be resolved (see the ⚠ above) — start manually:"
  else
    # Same split as the step line above, for the same reason: this block is the part
    # the skill relays VERBATIM to the user, so a false cause here outlives the run.
    # An announced-but-unusable backend must not read as "nothing announced".
    if [ -n "$ANNOUNCED_BIN" ]; then
      echo "  launch:    not automated ($ANNOUNCED_BIN announced via $ANNOUNCED_BY but not usable) — start manually:"
    else
      echo "  launch:    not automated (no multiplexer announced this session) — start manually:"
    fi
  fi
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
  echo "  The launch itself did not complete — the failure is reported above, not swallowed." >&2
  echo "  The worktree, branch and handoff are intact. To brief it by hand, run this in the tab:" >&2
  echo >&2
  echo "    Read docs/handoff.md and get oriented, then recommend the next step." >&2
  exit 3
fi

# The other way a run can fail to launch, and the reason this file grew a resolver:
# the environment named a backend and nothing launched. Same contract as above — say it
# OUTSIDE the block so it survives a summary relay, hand over the exact recovery, exit
# non-zero so a caller that only checks status can't read it as success.
#
# Two distinct codes because the two recoveries are distinct — one code cannot carry
# both fixes. 4: the binary wasn't reachable; nothing is wrong with the new session,
# the PATH is. 5: the binary was fine and the backend refused the launch; the PATH is
# irrelevant and the server is what needs starting. Telling someone to set HERDR_BIN
# when herdr is installed and merely stopped is the same unactionable answer this file
# exists to remove.
#
# Mutual exclusivity of 3, 4 and 5 holds by construction, not by assurance (KTD-4):
# 3 requires BRIEF_ATTEMPTED=1, which requires LAUNCHER != none. Both 4 and 5 require
# ANNOUNCED_UNLAUNCHED=1, which requires LAUNCHER = none — so neither can co-occur
# with 3. Between 4 and 5 the selector is $LOUD_BIN: 4 requires it non-empty, 5
# requires it empty, and one variable cannot be both.
if [ "${LAUNCH_UNRESOLVED:-0}" = "1" ]; then
  echo
  echo "⚠ NO SESSION WAS LAUNCHED — \`$LOUD_BIN\` could not be resolved." >&2
  echo "  This session announced it ($LOUD_ANNOUNCE), so this is a failure, not a skip." >&2
  echo "  The worktree, branch and handoff are intact. Fix the resolution (the ⚠ above names" >&2
  echo "  the paths searched and $LOUD_OVERRIDE) and re-run — but the worktree and branch" >&2
  echo "  already exist, so re-run with a NEW --name, or just start the session by hand in" >&2
  echo "  the worktree that is already there:" >&2
  echo >&2
  echo "    $MANUAL_CMD" >&2
  exit 4
fi

if [ "${ANNOUNCED_UNLAUNCHED:-0}" = "1" ]; then
  echo
  echo "⚠ NO SESSION WAS LAUNCHED — \`$ANNOUNCED_BIN\` would not take it." >&2
  echo "  This session announced it ($ANNOUNCED_BY), so this is a failure, not a skip." >&2
  if [ "$ANNOUNCED_BIN" = herdr ]; then
    echo "  The binary resolved; herdr did not report a running server. What it printed:" >&2
    if _herdr_probe_said_something; then
      _herdr_probe_evidence "    "
    else
      echo "    (nothing, on either stream)" >&2
    fi
    echo "  The probe needs a \`status: running\` line and did not get one. If the server is down," >&2
    echo "  start it, then re-run — but the worktree and branch already exist, so use a NEW --name," >&2
  elif [ "$ANNOUNCED_BIN" = ghostty ]; then
    echo "  Ghostty could not be driven: the ⚠ above names what was missing — the .app itself," >&2
    echo "  or osascript (\$OSASCRIPT_BIN pins it). There is no ghostty server to start. Fix" >&2
    echo "  that, then re-run — but the worktree and branch already exist, so re-run with a" >&2
    echo "  NEW --name," >&2
  else
    echo "  The backend did not pass its readiness probe. Fix that, then re-run — but the" >&2
    echo "  worktree and branch already exist, so re-run with a NEW --name," >&2
  fi
  echo "  or just start the session by hand in the worktree that is already there:" >&2
  echo >&2
  echo "    $MANUAL_CMD" >&2
  exit 5
fi

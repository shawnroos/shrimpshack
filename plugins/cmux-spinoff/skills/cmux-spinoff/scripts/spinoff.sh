#!/usr/bin/env bash
#
# spinoff.sh — fork the current workstream into a fresh worktree + a new cmux
# tab running a briefed Claude session. Driven by the cmux-spinoff skill.
#
# Mechanical only: the CALLER (Claude) supplies a synthesized handoff doc. This
# script handles worktree creation, env bootstrap, handoff finalization, doc
# carry-over, and cmux tab + Claude launch.
#
# Safe to read top-to-bottom before running. Prints each step. Never `git add -A`.

set -uo pipefail

# ---- args -------------------------------------------------------------------
NAME=""
HANDOFF_SRC=""
BASE=""                      # empty => current HEAD
PREFIX="feature"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --handoff) HANDOFF_SRC="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --branch-prefix) PREFIX="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

step() { echo "▸ $*"; }
die()  { echo "✗ $*" >&2; exit 1; }

[ -n "$NAME" ] || die "missing --name <kebab-feature-name>"
[ -n "$HANDOFF_SRC" ] || die "missing --handoff <path-to-handoff.md>"
[ -f "$HANDOFF_SRC" ] || die "handoff file not found: $HANDOFF_SRC"

CMUX="/Applications/cmux.app/Contents/Resources/bin/cmux"

# ---- locate repo + current branch ------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
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

step "repo:        $MAIN_ROOT"
step "new branch:  $BRANCH"
step "worktree:    $WORKTREE"

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

# ---- discover current session transcript ------------------------------------
# Prefer an explicit env var if Claude Code exposes one; else newest .jsonl for
# this project dir (project key = cwd with / -> -).
SESSION_LINE="(session transcript not found)"
PROJ_KEY="$(echo "$REPO_ROOT" | sed 's#/#-#g')"
PROJ_DIR="$HOME/.claude/projects/$PROJ_KEY"
TRANSCRIPT=""
if [ -n "${CLAUDE_TRANSCRIPT_PATH:-}" ] && [ -f "${CLAUDE_TRANSCRIPT_PATH:-}" ]; then
  TRANSCRIPT="$CLAUDE_TRANSCRIPT_PATH"
elif [ -n "${CLAUDE_SESSION_ID:-}" ] && [ -f "$PROJ_DIR/$CLAUDE_SESSION_ID.jsonl" ]; then
  TRANSCRIPT="$PROJ_DIR/$CLAUDE_SESSION_ID.jsonl"
elif [ -d "$PROJ_DIR" ]; then
  TRANSCRIPT="$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1)"
fi
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  UUID="$(basename "$TRANSCRIPT" .jsonl)"
  SESSION_LINE="Transcript: \`$TRANSCRIPT\`
Resume:     \`cd $REPO_ROOT && claude -r $UUID\`"
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
open(dst, "w").write(text)
PY
# Safety net: if the placeholder was missing (so the block never got inserted),
# append a Source-session section so the link is never lost.
grep -q "Resume:" "$HANDOFF_DST" 2>/dev/null || {
  printf '\n## Source session\n%s\n' "$SESSION_LINE" >> "$HANDOFF_DST"
}
step "handoff:     $HANDOFF_DST"

# ---- carry over recent plan/brainstorm docs ---------------------------------
CARRIED=0
if [ -d "$REPO_ROOT/docs" ]; then
  # files modified in last 6h matching planning patterns, top-level of docs/
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    [ "$base" = "handoff.md" ] && continue
    cp "$f" "$WORKTREE/docs/$base" 2>/dev/null && CARRIED=$((CARRIED+1))
  done < <(find "$REPO_ROOT/docs" -maxdepth 1 -type f -mmin -360 \
            \( -iname '*plan*' -o -iname '*brainstorm*' -o -iname '*requirement*' -o -iname '*notes*' \) \
            -print0 2>/dev/null)
fi
step "carried docs: $CARRIED recent plan/brainstorm file(s)"

# ---- cmux: open new tab on left agent pane + launch Claude ------------------
SURFACE_REF=""
LAUNCH_CMD="cd '$WORKTREE' && claude"
KICKOFF="Read docs/handoff.md — it's the brief for this worktree. Get oriented (goal, decisions, open questions, starting point), confirm you understand, then wait for my direction."

if [ -n "${CMUX_WORKSPACE_ID:-}" ] && [ -x "$CMUX" ]; then
  step "opening cmux tab on the left agent surface…"
  # Identify the left-hand agent pane: the lowest-indexed pane in this workspace
  # that holds terminal surfaces (the markdown/browser pane is the other one).
  WS="$CMUX_WORKSPACE_ID"
  LEFT_PANE="$("$CMUX" tree --workspace "$WS" 2>/dev/null \
    | awk '/pane / { for(i=1;i<=NF;i++) if($i ~ /^pane:/){p=$i} }
           /surface .*\[terminal\]/ && p { print p; exit }')"
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
  if [ -n "$SURFACE_REF" ]; then
    "$CMUX" rename-tab --surface "$SURFACE_REF" --workspace "$WS" "$NAME" >/dev/null 2>&1
    # Launch Claude in the worktree dir.
    "$CMUX" send --surface "$SURFACE_REF" --workspace "$WS" "$LAUNCH_CMD" >/dev/null 2>&1
    "$CMUX" send-key --surface "$SURFACE_REF" --workspace "$WS" enter >/dev/null 2>&1

    # Wait until Claude's input prompt is actually ready before sending the
    # kickoff. A fixed sleep is unreliable: a fresh claude can spend several
    # seconds loading MCP servers, and an Enter sent too early is swallowed (the
    # text lands but never submits). Poll read-screen for the prompt chrome
    # (the "❯" input marker) — up to ~30s — then type + submit.
    READY=0
    for _ in $(seq 1 30); do
      sleep 1
      SCREEN="$("$CMUX" read-screen --surface "$SURFACE_REF" --workspace "$WS" 2>/dev/null)"
      case "$SCREEN" in
        *"❯"*|*"bypass permissions"*|*"shift+tab to cycle"*) READY=1; break ;;
      esac
    done
    "$CMUX" send --surface "$SURFACE_REF" --workspace "$WS" "$KICKOFF" >/dev/null 2>&1
    sleep 1
    "$CMUX" send-key --surface "$SURFACE_REF" --workspace "$WS" enter >/dev/null 2>&1
    # Verify the kickoff actually submitted (input line should no longer hold it).
    sleep 2
    AFTER="$("$CMUX" read-screen --surface "$SURFACE_REF" --workspace "$WS" 2>/dev/null)"
    case "$AFTER" in
      *"Read docs/handoff.md"*)
        # Still sitting on the input line un-submitted → retry one Enter.
        "$CMUX" send-key --surface "$SURFACE_REF" --workspace "$WS" enter >/dev/null 2>&1 ;;
    esac
    if [ "$READY" = "1" ]; then
      step "  new surface: $SURFACE_REF (Claude ready, briefed)"
    else
      step "  new surface: $SURFACE_REF (Claude launched; readiness not confirmed — check the tab)"
    fi
  else
    echo "  ⚠ could not parse new surface ref; cmux output was:" >&2
    echo "$CREATE_OUT" >&2
  fi
else
  step "not inside cmux (or cmux CLI missing) — skipping tab automation"
fi

# ---- summary ----------------------------------------------------------------
echo
echo "════════════════════════════════════════════════════════"
echo "✓ Spinoff complete"
echo "  branch:    $BRANCH  (from $BASE_REF)"
echo "  worktree:  $WORKTREE"
echo "  handoff:   $HANDOFF_DST"
echo "  docs:      $CARRIED carried"
if [ -n "$SURFACE_REF" ]; then
  echo "  cmux tab:  $SURFACE_REF — new Claude session open + briefed"
else
  echo "  cmux tab:  not created — start manually:"
  echo "             $LAUNCH_CMD"
fi
echo "════════════════════════════════════════════════════════"

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

# ---- args -------------------------------------------------------------------
NAME=""
LABEL=""                     # short display name for the cmux tab/workspace (see derivation below)
HANDOFF_SRC=""
REPO=""                      # explicit target repo (when the originating cwd isn't inside it)
BASE=""                      # empty => current HEAD
PREFIX="feature"
TARGET="tab"                 # tab => surface in current workspace; workspace => new workspace
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
    --session-transcript) SESSION_TRANSCRIPT="$2"; shift 2 ;;
    --session-cwd) SESSION_CWD="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

step() { echo "▸ $*"; }
die()  { echo "✗ $*" >&2; exit 1; }
# Make a path absolute against the CURRENT cwd. Used to pin relative file args
# (handoff, transcript) BEFORE a `--repo` cd changes cwd out from under them —
# they're read later (post-cd), so a relative path would otherwise be lost.
abspath() { case "$1" in ""|/*) printf '%s' "$1" ;; *) printf '%s/%s' "$(pwd -P)" "$1" ;; esac; }

[ -n "$NAME" ] || die "missing --name <kebab-feature-name>"
[ -n "$HANDOFF_SRC" ] || die "missing --handoff <path-to-handoff.md>"
[ -f "$HANDOFF_SRC" ] || die "handoff file not found: $HANDOFF_SRC"
case "$TARGET" in
  tab|workspace) ;;
  *) die "invalid --target '$TARGET' (expected: tab | workspace)" ;;
esac

# Prefer cmux on PATH (Homebrew, Linux); fall back to the macOS app bundle path.
CMUX="$(command -v cmux 2>/dev/null)"
[ -n "$CMUX" ] || CMUX="/Applications/cmux.app/Contents/Resources/bin/cmux"

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

# ---- cmux: launch a briefed Claude (tab in current workspace, or new workspace)
WORKSPACE_REF=""
SURFACE_REF=""
VIEWER_OK=0          # set when the handoff markdown viewer actually renders
LB_READY=0           # set to 1 by launch_and_brief when the prompt was confirmed ready
LAUNCH_CMD="cd '$WORKTREE' && claude --name '$LABEL'"
KICKOFF="Read docs/handoff.md — it's the brief for this worktree. Treat the whole handoff as directional: it conveys author intent and a starting point — enough to orient and begin — not a definitive spec to execute literally. The code and tests are the source of truth; validate the handoff's claims against them as you go, and expect to refine. Where the code contradicts the handoff, follow the code — that's expected here, not a failure. (This isn't license to ignore it: the handoff still carries real decisions and facts worth trusting; the stance is orient-and-validate, not distrust.) Get oriented (goal, decisions, open questions, starting point), then recommend the next step in the compound-engineering flow: /ce-brainstorm if scope or approach is still ambiguous, /ce-plan if it's clear enough to plan, or a more specific CE command if one fits better — each with a one-line rationale grounded in the handoff. The 'Recommended next step' section is itself just a starting suggestion; validate it against what you read rather than echoing it. Give me your recommendation, then wait for my direction."

# launch_and_brief <workspace-ref> <surface-ref> <surface-label> <where>
# Renames the tab, launches Claude in the worktree, waits for the input prompt to
# be ready (a fixed sleep is unreliable — a fresh claude can spend seconds loading
# MCP servers, and an Enter sent too early is swallowed), then sends + submits the
# kickoff and verifies it actually submitted. Reports readiness using <surface-label>
# (e.g. "new surface" / "agent surface") and <where> (e.g. "tab" / "workspace") for
# the not-confirmed hint. Sets LB_READY=1 on confirmed ready.
launch_and_brief() {
  local ws="$1" sfc="$2" label="${3:-surface}" where="${4:-tab}" screen after
  LB_READY=0
  # --title (not a bare positional) so a $LABEL starting with '-' can't be
  # misparsed as a flag — matches the new-workspace --name call's robustness.
  "$CMUX" rename-tab --surface "$sfc" --workspace "$ws" --title "$LABEL" >/dev/null 2>&1
  "$CMUX" send --surface "$sfc" --workspace "$ws" "$LAUNCH_CMD" >/dev/null 2>&1
  "$CMUX" send-key --surface "$sfc" --workspace "$ws" enter >/dev/null 2>&1
  for _ in $(seq 1 30); do
    sleep 1
    screen="$("$CMUX" read-screen --surface "$sfc" --workspace "$ws" 2>/dev/null)"
    case "$screen" in
      *"❯"*|*"bypass permissions"*|*"shift+tab to cycle"*) LB_READY=1; break ;;
    esac
  done
  "$CMUX" send --surface "$sfc" --workspace "$ws" "$KICKOFF" >/dev/null 2>&1
  sleep 1
  "$CMUX" send-key --surface "$sfc" --workspace "$ws" enter >/dev/null 2>&1
  # Verify the kickoff actually submitted (input line should no longer hold it).
  sleep 2
  after="$("$CMUX" read-screen --surface "$sfc" --workspace "$ws" 2>/dev/null)"
  case "$after" in
    *"Read docs/handoff.md"*)
      # Still sitting on the input line un-submitted → retry one Enter.
      "$CMUX" send-key --surface "$sfc" --workspace "$ws" enter >/dev/null 2>&1 ;;
  esac
  if [ "$LB_READY" = "1" ]; then
    step "  $label: $sfc (Claude ready, briefed)"
  else
    step "  $label: $sfc (Claude launched; readiness not confirmed — check the $where)"
  fi
}

# NB: cmux automation is gated on CMUX_WORKSPACE_ID, which the script relies on
# inheriting from the (possibly background-agent) environment that launched it —
# the same background-context dependency the explicit --session-transcript pass
# guards against. Empirically the var is inherited by dispatched agents today; if a
# future runtime stops passing it, this whole block silently no-ops (worktree +
# handoff still produced) and the skill should pass the workspace id explicitly.
if [ -n "${CMUX_WORKSPACE_ID:-}" ] && [ -x "$CMUX" ]; then
  if [ "$TARGET" = "workspace" ]; then
    # New workspace: briefed Claude on the left, handoff markdown viewer on the right.
    # Create it UNFOCUSED — we only switch the user into it once a surface has actually
    # launched, so a discovery failure never strands them in an empty focused workspace.
    step "creating a new cmux workspace…"
    WS_OUT="$("$CMUX" new-workspace --name "$LABEL" --cwd "$WORKTREE" --focus false 2>&1)"
    WORKSPACE_REF="$(echo "$WS_OUT" | grep -oE 'workspace:[0-9]+' | head -1)"
    if [ -n "$WORKSPACE_REF" ]; then
      step "  new workspace: $WORKSPACE_REF"
      # The fresh workspace has one terminal surface — find its ref. The surface may
      # not be registered the instant new-workspace returns, so poll (unlike the tab
      # path, which gets its ref straight from new-surface's own output). ~10s budget,
      # closer to launch_and_brief's 30s readiness window than the old 5s.
      SURFACE_REF=""
      for _ in $(seq 1 20); do
        SURFACE_REF="$("$CMUX" tree --workspace "$WORKSPACE_REF" 2>/dev/null \
          | awk '/surface .*\[terminal\]/ { for(i=1;i<=NF;i++) if($i ~ /^surface:/){print $i; exit} }')"
        [ -n "$SURFACE_REF" ] && break
        sleep 0.5
      done
      if [ -n "$SURFACE_REF" ]; then
        # Surface exists — now safe to switch the user into the new workspace.
        "$CMUX" select-workspace --workspace "$WORKSPACE_REF" >/dev/null 2>&1
        launch_and_brief "$WORKSPACE_REF" "$SURFACE_REF" "agent surface" "workspace"
        # Right pane: render the handoff in cmux's live-reload markdown viewer.
        PANE_OUT="$("$CMUX" new-pane --type terminal --direction right --workspace "$WORKSPACE_REF" --focus false 2>&1)"
        RIGHT_PANE="$(echo "$PANE_OUT" | grep -oE 'pane:[0-9]+' | head -1)"
        if [ -n "$RIGHT_PANE" ]; then
          if "$CMUX" open "$HANDOFF_DST" --pane "$RIGHT_PANE" --workspace "$WORKSPACE_REF" --no-focus >/dev/null 2>&1; then
            VIEWER_OK=1
            step "  handoff viewer: $RIGHT_PANE"
          else
            echo "  ⚠ opened right pane but could not render the handoff viewer" >&2
          fi
        else
          echo "  ⚠ could not create right pane for handoff viewer; cmux output was:" >&2
          echo "$PANE_OUT" >&2
        fi
      else
        echo "  ⚠ no terminal surface found in the new workspace — skipping launch" >&2
      fi
    else
      echo "  ⚠ could not parse new workspace ref; cmux output was:" >&2
      echo "$WS_OUT" >&2
    fi
  else
    # Tab: new surface on the current workspace's left agent pane.
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
      launch_and_brief "$WS" "$SURFACE_REF" "new surface" "tab"
    else
      echo "  ⚠ could not parse new surface ref; cmux output was:" >&2
      echo "$CREATE_OUT" >&2
    fi
  fi
else
  step "not inside cmux (or cmux CLI missing) — skipping cmux automation"
fi

# ---- summary ----------------------------------------------------------------
echo
echo "════════════════════════════════════════════════════════"
echo "✓ Spinoff complete"
echo "  branch:    $BRANCH  (from $BASE_REF)"
echo "  worktree:  $WORKTREE"
echo "  handoff:   $HANDOFF_DST"
echo "  docs:      $CARRIED carried"
# Describe the launched session honestly: only claim "briefed" when readiness was
# confirmed, and only claim the viewer when it actually rendered.
if [ "$LB_READY" = "1" ]; then SESS_STATE="open + briefed"; else SESS_STATE="launched (readiness not confirmed — check the surface)"; fi
VIEWER_NOTE=""; [ "$VIEWER_OK" = "1" ] && VIEWER_NOTE=" (handoff viewer alongside)"
if [ -n "$SURFACE_REF" ] && [ -n "$WORKSPACE_REF" ]; then
  echo "  cmux:      workspace $WORKSPACE_REF + agent $SURFACE_REF — new Claude session $SESS_STATE$VIEWER_NOTE"
elif [ -n "$SURFACE_REF" ]; then
  echo "  cmux tab:  $SURFACE_REF — new Claude session $SESS_STATE"
elif [ -n "$WORKSPACE_REF" ]; then
  # Workspace was created (and focused) but no agent surface launched — don't claim
  # "not created" and strand the user in an empty focused workspace.
  echo "  cmux:      workspace $WORKSPACE_REF created, but no agent surface launched — start Claude in it manually:"
  echo "             $LAUNCH_CMD"
else
  echo "  cmux:      not created — start manually:"
  echo "             $LAUNCH_CMD"
fi
echo "════════════════════════════════════════════════════════"

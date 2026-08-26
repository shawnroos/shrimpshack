#!/usr/bin/env bash
#
# gate.sh — PreToolUse(Bash). Stops a commit or a PR once when the change adds
# comment bloat, and lets the retry through.
#
# Every exit but one is 0 with no output. This runs ahead of every Bash call the
# session makes, so a bug here costs the user their commit; silence is the only
# safe failure. The single deny is the exception, and it is deliberately
# once-per-finding-set so it can interrupt but never refuse.

# No `set -e`: an unexpected non-zero from any probe below must fall through to
# a silent exit 0, not abort the script and surface as a hook error.
set -u

allow() { exit 0; }

# 1. Off switches, cheapest first.
[ -n "${COMMENT_CUT_GATE_OFF:-}" ] && allow

command -v jq >/dev/null 2>&1 || allow
command -v git >/dev/null 2>&1 || allow

PY=""
for c in python3 python; do
  command -v "$c" >/dev/null 2>&1 && "$c" -c '' >/dev/null 2>&1 && { PY="$c"; break; }
done
[ -n "$PY" ] || allow

CHECK="${CLAUDE_PLUGIN_ROOT:-}/tools/comment-cut/check.py"
[ -r "$CHECK" ] || allow

# 2. Read the payload. stdin is the only channel: $TOOL_INPUT is not
# interpolated for "command" hooks, so reading it here greps an empty string
# and the gate never fires.
PAYLOAD="$(cat 2>/dev/null)" || allow
[ -n "$PAYLOAD" ] || allow

CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)" || allow
[ -n "$CMD" ] || allow

# 3. Is this a landing command? Anchored so a mention inside another command --
# `git log --grep "commit"` -- does not fire.
SHAPE=""
if printf '%s' "$CMD" | grep -qE '(^|[;&|(] *)git +(-[^ ]+ +)*commit([[:space:]]|$)'; then
  SHAPE=commit
elif printf '%s' "$CMD" | grep -qE '(^|[;&|(] *)gh +pr +create([[:space:]]|$)'; then
  SHAPE=pr
fi
[ -n "$SHAPE" ] || allow

# 4. Repo gates. cd first: the hook's cwd is the session's, which is the repo
# for the commit we are about to judge.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || allow
[ -n "$ROOT" ] || allow
cd "$ROOT" 2>/dev/null || allow

# Opt-in, not opt-out. Without this the published hook would deny commits in
# every repo the user touches, including team repos where a personal comment
# bar has no standing. lint-router solved the same problem the same way.
[ -f "$ROOT/.comment-cut-gate" ] || allow

# 5. The file set this call is about to land. Three different sets; picking one
# and using it for all three gets two of them wrong, and check.py's own default
# is wrong for all three (it sweeps untracked scratch files).
case "$SHAPE" in
  commit)
    FILES="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)"
    # `commit -a` also lands tracked-but-unstaged edits.
    if printf '%s' "$CMD" | grep -qE 'git +(-[^ ]+ +)*commit +(-[^ -]*a|--all)'; then
      FILES="$FILES
$(git diff --name-only --diff-filter=ACM 2>/dev/null)"
    fi
    ;;
  pr)
    BASE="$(git merge-base origin/HEAD HEAD 2>/dev/null)" \
      || BASE="$(git merge-base origin/main HEAD 2>/dev/null)" || allow
    [ -n "$BASE" ] || allow
    FILES="$(git diff --name-only --diff-filter=ACM "$BASE"..HEAD 2>/dev/null)"
    ;;
esac

FILES="$(printf '%s\n' "$FILES" | grep -E '\.(ts|tsx|js|jsx|mjs|cjs)$' | sort -u)"
[ -n "$FILES" ] || allow

# 6. Scan. --porcelain is the only read-out that reports findings by exit code.
HITS="$(printf '%s\n' "$FILES" | tr '\n' '\0' | xargs -0 "$PY" "$CHECK" --porcelain 2>/dev/null)"
[ -n "$HITS" ] || allow

# 7. Keep only findings on lines this change actually adds. check.py walks whole
# files, so without this the gate denies on comments the author never touched --
# and the agent's natural response, cutting what the reason names, edits lines
# outside the change with nobody reviewing them.
case "$SHAPE" in
  commit) RANGE="--cached" ;;
  pr)     RANGE="$BASE..HEAD" ;;
esac

ADDED="$(git diff -U0 $RANGE -- $FILES 2>/dev/null | awk '
  /^\+\+\+ b\// { f = substr($0, 7); next }
  /^@@ / {
    split($3, h, ",")
    start = h[1] + 0; if (start < 0) start = -start
    count = (length(h) > 1 ? h[2] + 0 : 1)
    for (i = 0; i < count; i++) print f ":" (start + i)
  }')"
[ -n "$ADDED" ] || allow

SURVIVORS="$(printf '%s\n' "$HITS" | while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  key="${hit%:*}"
  printf '%s\n' "$ADDED" | grep -qxF "$key" && printf '%s\n' "$hit"
done)"
[ -n "$SURVIVORS" ] || allow

# 8. Deny once per distinct finding set. The marker lives in the git dir --
# resolved, never assumed to be "$ROOT/.git", which is a file in a worktree.
DIGEST="$(printf '%s' "$SURVIVORS" | cksum | tr -d ' \n')"
GITDIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || allow
[ -n "$GITDIR" ] || allow
MARKER="$GITDIR/comment-cut-gate.last"

[ -r "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$DIGEST" ] && allow

# A marker we cannot write is a gate that would deny the same set forever.
printf '%s' "$DIGEST" > "$MARKER" 2>/dev/null || allow

REASON="comment-cut: this change adds comment bloat on lines it touches.

$SURVIVORS

The bar: keep only what the code cannot say -- a measured constant, a
non-obvious ordering constraint, a footgun that fails silently, a deliberate
deviation. Everything else goes. Run /comment-cut:cut for the full pass.

This detector is advisory and mechanical; a clean run is not evidence the bar
was met. Re-issue the same command to proceed, whether or not you cut them."

jq -n --arg r "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}' 2>/dev/null || allow

exit 0

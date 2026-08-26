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

# 2. Read the payload. stdin is the only channel: $TOOL_INPUT is not
# interpolated for "command" hooks, so reading it here greps an empty string
# and the gate never fires. `read` is a builtin; `cat` would fork on every
# Bash call in the session. It returns non-zero at EOF with PAYLOAD set, so
# the emptiness check below is the real guard.
IFS= read -r -d '' PAYLOAD
[ -n "${PAYLOAD:-}" ] || allow

CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)" || allow
[ -n "$CMD" ] || allow

# 3. Is this a landing command? Anchored so a mention inside another command --
# `git log --grep "commit"` -- does not fire.
SHAPE=""
if printf '%s' "$CMD" | grep -qE '(^|[;&|(] *)git +((-[^ ]+|[A-Za-z._-]+=[^ ]+) +)*commit([[:space:]]|$)'; then
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

# Resolved, never assumed to be "$ROOT/.git" -- that is a file in a worktree.
GITDIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || allow
[ -n "$GITDIR" ] || allow

# 5. The file set this call is about to land. Three different sets; picking one
# and using it for all three gets two of them wrong, and check.py's own default
# is wrong for all three (it sweeps untracked scratch files).
case "$SHAPE" in
  commit)
    # Finishing a merge stages the incoming branch's whole delta, so --cached
    # reads someone else's comments as added by this commit. Not ours to judge.
    [ -e "$GITDIR/MERGE_HEAD" ] && allow

    FILES="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)"
    # `commit -a` also lands tracked-but-unstaged edits. The flag can sit
    # anywhere in the invocation, so match the whole command -- but only as a
    # whole word, or `--allow-empty` reads as `--all` and denies falsely.
    if printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(-[^ -]*a[^ -]*|--all)([[:space:]]|$)'; then
      ALL_FLAG=1
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

# Word-splitting on $FILES loses a path containing a space, and the resulting
# empty pathspec silently produces no findings at all.
FILE_ARR=()
while IFS= read -r _f; do [ -n "$_f" ] && FILE_ARR+=("$_f"); done <<< "$FILES"
[ "${#FILE_ARR[@]}" -gt 0 ] || allow

PY=""
for c in python3 python; do
  command -v "$c" >/dev/null 2>&1 && "$c" -c '' >/dev/null 2>&1 && { PY="$c"; break; }
done
[ -n "$PY" ] || allow

CHECK="${CLAUDE_PLUGIN_ROOT:-}/tools/comment-cut/check.py"
[ -r "$CHECK" ] || allow

# 6. Scan. --porcelain is the only read-out that reports findings by exit code.
#
# A plain `git commit` lands the INDEX, not the worktree. Scanning the worktree
# would name a line the commit does not contain whenever a file was staged clean
# and then edited. Materialise the indexed content and scan that instead.
SCANDIR=""
if [ "$SHAPE" = commit ] && [ -z "${ALL_FLAG:-}" ]; then
  SCANDIR="$(mktemp -d "${TMPDIR:-/tmp}/comment-cut-idx.XXXXXX")" || allow
  trap 'rm -rf "$SCANDIR"' EXIT
  git checkout-index --prefix="$SCANDIR/" -- "${FILE_ARR[@]}" 2>/dev/null || allow
  HITS="$( (cd "$SCANDIR" && printf '%s\0' "${FILE_ARR[@]}" \
    | xargs -0 "$PY" "$CHECK" --porcelain 2>/dev/null) )"
else
  HITS="$(printf '%s\0' "${FILE_ARR[@]}" | xargs -0 "$PY" "$CHECK" --porcelain 2>/dev/null)"
fi
[ -n "$HITS" ] || allow

# 7. Keep only findings on lines this change actually adds. check.py walks whole
# files, so without this the gate denies on comments the author never touched --
# and the agent's natural response, cutting what the reason names, edits lines
# outside the change with nobody reviewing them.
case "$SHAPE" in
  commit) RANGE="${ALL_FLAG:+HEAD}"; RANGE="${RANGE:---cached}" ;;
  pr)     RANGE="$BASE..HEAD" ;;
esac

# --src-prefix/--dst-prefix pin what the awk key expects: diff.noprefix or
# diff.mnemonicPrefix would otherwise yield no matches, and the gate would
# silently never fire for that user. --no-ext-diff/--no-textconv stop a
# configured diff driver replacing the hunk format entirely.
ADDED="$(git -c core.quotePath=false diff -U0 --no-ext-diff --no-textconv \
  --src-prefix=a/ --dst-prefix=b/ $RANGE -- "${FILE_ARR[@]}" 2>/dev/null | awk '
  # git appends a TAB after the path when it contains a space, so the key would
  # otherwise carry a trailing tab and never match a finding.
  /^\+\+\+ b\// { f = substr($0, 7); sub(/\t.*$/, "", f); next }
  /^@@ / {
    split($3, h, ",")
    start = h[1] + 0; if (start < 0) start = -start
    count = (length(h) > 1 ? h[2] + 0 : 1)
    for (i = 0; i < count; i++) printf "%s:%d\n", f, start + i
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
MARKER="$GITDIR/comment-cut-gate.last"

[ -r "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$DIGEST" ] && allow

REASON="comment-cut: this change adds comment bloat on lines it touches.

$SURVIVORS

The bar: keep only what the code cannot say -- a measured constant, a
non-obvious ordering constraint, a footgun that fails silently, a deliberate
deviation. Everything else goes. Run /comment-cut:cut for the full pass.

This detector is advisory and mechanical; a clean run is not evidence the bar
was met. Re-issue the same command to proceed, whether or not you cut them."

DECISION="$(jq -n --arg r "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}' 2>/dev/null)" || allow
[ -n "$DECISION" ] || allow

# Record only now. A marker written before the decision built would mark this
# finding set as already-shown and suppress it forever. A marker we cannot write
# means we allow rather than deny the same set on every retry.
printf '%s' "$DIGEST" > "$MARKER" 2>/dev/null || allow

printf '%s\n' "$DECISION"
exit 0

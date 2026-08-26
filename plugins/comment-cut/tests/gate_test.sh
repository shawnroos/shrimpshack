# gate_test.sh — the PreToolUse gate.
#
# Every assertion runs against a throwaway repo under a temp dir. Nothing here
# touches the operator's repos, git config, or the real global tools directory.
#
# The fail-open cases outnumber the deny cases on purpose: this hook runs ahead
# of every Bash call in a session, so "denies when it should" matters less than
# "is silent every other time".

_g="$(mktemp -d "${TMPDIR:-/tmp}/cc-gate.XXXXXX")"
trap 'rm -rf "$_g"' RETURN

GATE="$PLUGIN/hooks/gate.sh"

# payload <command> — the PreToolUse envelope the harness delivers on stdin.
payload() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

# fire <repo> <command> — run the gate as the harness does. Echoes stdout.
fire() (
  cd "$1" || return 9
  payload "$2" | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null
)

decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }

_bloat='// ===== HELPERS =====
export const a = 1;
'
_clean='export const b = 2;
'

# newrepo <name> [--no-optin] — a repo with one committed clean file.
newrepo() {
  local r="$_g/$1"; shift
  mkdir -p "$r"; cd "$r" || return 1
  git init -q . 2>/dev/null
  git config user.email t@t; git config user.name t
  printf '%s' "$_clean" > base.ts
  git add base.ts; git commit -qm base
  [ "${1:-}" = "--no-optin" ] || touch "$r/.comment-cut-gate"
  cd - >/dev/null || return 1
  printf '%s' "$r"
}

# ---------- the deny path ----------
_r="$(newrepo denies)"
printf '%s' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
_out="$(fire "$_r" 'git commit -m "x"')"
check_eq "denies a staged file that adds bloat" "deny" "$(decision "$_out")"
check "deny reason names the finding" \
  "printf '%s' \"\$_out\" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'new.ts'"
check "deny reason states the retry proceeds" \
  "printf '%s' \"\$_out\" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'Re-issue'"
check "deny reason keeps the advisory caveat" \
  "printf '%s' \"\$_out\" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'not evidence'"

# ---------- deny once, then allow ----------
_out2="$(fire "$_r" 'git commit -m "x"')"
check_eq "the unchanged retry is allowed through" "" "$(decision "$_out2")"

printf '%s\n// const dead = gone();\n' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
check_eq "a different finding set denies again" "deny" "$(decision "$(fire "$_r" 'git commit -m "x"')")"

# ---------- pre-existing bloat is not this change's problem ----------
_r="$(newrepo preexisting)"
printf '%s' "$_bloat" > "$_r/old.ts"
(cd "$_r" && git add old.ts && git commit -qm "bloat lands")
printf '%s\nexport const c = 3;\n' "$_bloat" > "$_r/old.ts"
(cd "$_r" && git add old.ts)
check_eq "an unrelated edit beside an old banner is allowed" "" \
  "$(decision "$(fire "$_r" 'git commit -m "x"')")"

# ---------- opt-in ----------
_r="$(newrepo notoptedin --no-optin)"
printf '%s' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
check_eq "a repo without the marker is untouched" "" \
  "$(decision "$(fire "$_r" 'git commit -m "x"')")"

# ---------- command shapes ----------
_r="$(newrepo shapes)"
printf '%s' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
check_eq "git log --grep commit does not fire" "" \
  "$(decision "$(fire "$_r" 'git log --grep "commit"')")"
check_eq "an unrelated command does not fire" "" \
  "$(decision "$(fire "$_r" 'ls -la')")"

# gh pr create sees the branch range, not the index — the bloat here is already
# committed, which is exactly the case a staged-only file set would miss.
_r="$(newrepo prshape)"
(cd "$_r" && git branch -M main && git remote add origin . 2>/dev/null
 git update-ref refs/remotes/origin/main HEAD
 git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
 git checkout -qb feature)
printf '%s' "$_bloat" > "$_r/new.ts"
(cd "$_r" && git add new.ts && git commit -qm "adds bloat")
check_eq "gh pr create denies on already-committed bloat" "deny" \
  "$(decision "$(fire "$_r" 'gh pr create --fill')")"

# ---------- no findings ----------
_r="$(newrepo cleanrepo)"
printf '%s' "$_clean" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
check_eq "a clean staged file is allowed" "" \
  "$(decision "$(fire "$_r" 'git commit -m "x"')")"

# ---------- fail-open ----------
_r="$(newrepo failopen)"
printf '%s' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)

check_eq "the kill switch silences a would-be deny" "" \
  "$(decision "$(cd "$_r" && payload 'git commit -m "x"' | COMMENT_CUT_GATE_OFF=1 CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null)")"

check_eq "an unreadable checker is allowed through" "" \
  "$(decision "$(cd "$_r" && payload 'git commit -m "x"' | CLAUDE_PLUGIN_ROOT="$_g/nowhere" bash "$GATE" 2>/dev/null)")"

check_eq "malformed json on stdin is allowed through" "" \
  "$(decision "$(cd "$_r" && printf 'not json' | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null)")"

check_eq "empty stdin is allowed through" "" \
  "$(decision "$(cd "$_r" && printf '' | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null)")"

check_eq "a payload with no command is allowed through" "" \
  "$(decision "$(cd "$_r" && jq -n '{tool_name:"Bash",tool_input:{}}' | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null)")"

check_eq "outside a git repo it is allowed through" "" \
  "$(decision "$(cd "$_g" && payload 'git commit -m "x"' | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null)")"

# Absolute interpreter: an emptied PATH would otherwise hide `bash` itself and
# the 127 would be the shell's, not the gate's.
check_eq "without jq on PATH it is allowed through" "0" \
  "$(cd "$_r" && payload 'git commit -m "x"' | PATH=/nonexistent CLAUDE_PLUGIN_ROOT="$PLUGIN" "$BASH" "$GATE" >/dev/null 2>&1; echo "$?")"

# A non-writable git dir must not wedge every retry: the gate cannot record that
# it already denied, so it must allow rather than deny the same set forever.
_r="$(newrepo unwritable)"
printf '%s' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
chmod a-w "$_r/.git" 2>/dev/null
check_eq "a non-writable git dir allows rather than wedges" "" \
  "$(decision "$(fire "$_r" 'git commit -m "x"')")"
chmod u+w "$_r/.git" 2>/dev/null

# ---------- a linked worktree, where .git is a file ----------
_r="$(newrepo worktree)"
(cd "$_r" && git worktree add -q -b wt "$_g/wt" 2>/dev/null)
touch "$_g/wt/.comment-cut-gate"
printf '%s' "$_bloat" > "$_g/wt/new.ts"; (cd "$_g/wt" && git add new.ts)
check "the worktree's .git is a file, not a directory" "[ -f '$_g/wt/.git' ]"
check_eq "denies inside a linked worktree" "deny" \
  "$(decision "$(fire "$_g/wt" 'git commit -m "x"')")"
check_eq "and the retry there is allowed" "" \
  "$(decision "$(fire "$_g/wt" 'git commit -m "x"')")"

# The exit code is always 0. A hook that exits non-zero surfaces as an error on
# a tool call the user did nothing wrong on.
(cd "$_r" && payload 'git commit -m "x"' | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" >/dev/null 2>&1)
check_eq "the gate always exits 0" "0" "$?"

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

# fire <repo> <command> — run the gate as the harness does. Echoes stdout and
# sets _rc to the gate's exit status.
#
# _rc is why this is not a subshell. An empty decision means "allowed", but it is
# ALSO what a gate that crashed on its first line produces, and asserting only
# emptiness cannot tell those apart -- four fail-open guards were deleted from
# gate.sh with this suite still fully green before _rc existed.
_rc=0
fire() {
  local out
  out="$(cd "$1" && payload "$2" | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null)"
  _rc=$?
  printf '%s' "$out"
}

decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }

# allowed <name> <repo> <command> — the gate ran, exited 0, and emitted no
# decision. All three, or the assertion cannot fail.
allowed() {
  local out
  out="$(fire "$2" "$3")"
  if [ "$_rc" -eq 0 ] && [ -z "$(decision "$out")" ] && [ -z "$out" ]; then
    ok "$1"
  else
    bad "$1 (rc=$_rc, stdout='${out:0:60}')"
  fi
}

# allowed_raw <name> <stdout> <rc> — same contract for the cases that must build
# their own invocation (a stripped PATH, a hand-made payload).
allowed_raw() {
  if [ "$3" -eq 0 ] && [ -z "$2" ]; then ok "$1"; else bad "$1 (rc=$3, stdout='${2:0:60}')"; fi
}

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
allowed "the unchanged retry is allowed through" "$_r" 'git commit -m "x"' 

printf '%s\n// const dead = gone();\n' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
check_eq "a different finding set denies again" "deny" "$(decision "$(fire "$_r" 'git commit -m "x"')")"

# ---------- pre-existing bloat is not this change's problem ----------
_r="$(newrepo preexisting)"
printf '%s' "$_bloat" > "$_r/old.ts"
(cd "$_r" && git add old.ts && git commit -qm "bloat lands")
printf '%s\nexport const c = 3;\n' "$_bloat" > "$_r/old.ts"
(cd "$_r" && git add old.ts)
allowed "an unrelated edit beside an old banner is allowed" "$_r" 'git commit -m "x"' 

# ---------- commit -a lands unstaged tracked edits too ----------
# Three file sets, not one: `git commit`, `git commit -a`, and `gh pr create`.
# -am is the common spelling and an earlier flag pattern matched only -ma.
_r="$(newrepo commitall)"
printf '%s' "$_clean" > "$_r/tracked.ts"
(cd "$_r" && git add tracked.ts && git commit -qm "clean tracked file")
printf '%s' "$_bloat" > "$_r/tracked.ts"   # modified, NOT staged
allowed "plain commit ignores an unstaged edit" "$_r" 'git commit -m "x"' 
check_eq "commit -am denies on that same unstaged edit" "deny" \
  "$(decision "$(fire "$_r" 'git commit -am "x"')")"

_r="$(newrepo commitall2)"
printf '%s' "$_clean" > "$_r/tracked.ts"
(cd "$_r" && git add tracked.ts && git commit -qm "clean tracked file")
printf '%s' "$_bloat" > "$_r/tracked.ts"
check_eq "commit -a denies too" "deny" "$(decision "$(fire "$_r" 'git commit -a -m "x"')")"

_r="$(newrepo commitamend)"
printf '%s' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
check_eq "--amend is not read as the -a flag" "deny" \
  "$(decision "$(fire "$_r" 'git commit --amend -m "x"')")"

# ---------- the marker records only a deny that was actually emitted ----------
_r="$(newrepo marker)"
printf '%s' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
_gd="$_r/.git/comment-cut-gate.last"
check "no marker before the first deny" "[ ! -e '$_gd' ]"
fire "$_r" 'git commit -m "x"' >/dev/null
check "a marker exists after the deny" "[ -s '$_gd' ]"

# ---------- the index is what a plain commit lands, not the worktree ----------
# Staged clean, then edited. The bloat exists on disk but is not in the commit,
# so naming it would point the agent at a line the commit does not contain.
_r="$(newrepo indexonly)"
printf '%s' "$_clean" > "$_r/staged.ts"
(cd "$_r" && git add staged.ts)
printf '%s' "$_bloat" > "$_r/staged.ts"
allowed "worktree-only bloat is not judged by a plain commit" "$_r" 'git commit -m "x"'
check_eq "...but commit -a does judge it" "deny" \
  "$(decision "$(fire "$_r" 'git commit -am "x"')")"

# ---------- finishing a merge is not this commit's bloat ----------
_r="$(newrepo mergecommit)"
(cd "$_r" && git branch -M main && git checkout -qb side)
printf '%s' "$_bloat" > "$_r/theirs.ts"
(cd "$_r" && git add theirs.ts && git commit -qm "side adds bloat"
 git checkout -q main && printf 'export const z = 1;\n' > other.ts
 git add other.ts && git commit -qm "main moves on"
 git merge --no-commit --no-ff side >/dev/null 2>&1)
check "a merge is genuinely in progress" "[ -e '$_r/.git/MERGE_HEAD' ]"
allowed "finishing a merge is not denied over the incoming branch" "$_r" 'git commit -m "merge"'

# ---------- user diff config must not silently disable the gate ----------
_r="$(newrepo noprefix)"
(cd "$_r" && git config diff.noprefix true && git config diff.mnemonicPrefix true)
printf '%s' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
check_eq "denies even with diff.noprefix and mnemonicPrefix set" "deny" \
  "$(decision "$(fire "$_r" 'git commit -m "x"')")"

# ---------- a path with a space must not drop the finding set ----------
_r="$(newrepo spacedpath)"
printf '%s' "$_bloat" > "$_r/has space.ts"; (cd "$_r" && git add "has space.ts")
check_eq "denies on a path containing a space" "deny" \
  "$(decision "$(fire "$_r" 'git commit -m "x"')")"

# ---------- --allow-empty is not the -a flag ----------
_r="$(newrepo allowempty)"
printf '%s' "$_clean" > "$_r/tracked.ts"
(cd "$_r" && git add tracked.ts && git commit -qm clean)
printf '%s' "$_bloat" > "$_r/tracked.ts"   # unstaged
allowed "--allow-empty does not pull in unstaged edits" "$_r" 'git commit --allow-empty -m "x"'

# ---------- opt-in ----------
_r="$(newrepo notoptedin --no-optin)"
printf '%s' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
allowed "a repo without the marker is untouched" "$_r" 'git commit -m "x"' 

# ---------- command shapes ----------
_r="$(newrepo shapes)"
printf '%s' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
allowed "git log --grep commit does not fire" "$_r" 'git log --grep "commit"' 
allowed "an unrelated command does not fire" "$_r" 'ls -la' 

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
allowed "a clean staged file is allowed" "$_r" 'git commit -m "x"' 

# ---------- fail-open ----------
_r="$(newrepo failopen)"
printf '%s' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)

_o="$(cd "$_r" && payload 'git commit -m "x"' | COMMENT_CUT_GATE_OFF=1 CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null)"; _c=$?
allowed_raw "the kill switch silences a would-be deny" "$_o" "$_c"

_o="$(cd "$_r" && payload 'git commit -m "x"' | CLAUDE_PLUGIN_ROOT="$_g/nowhere" bash "$GATE" 2>/dev/null)"; _c=$?
allowed_raw "an unreadable checker is allowed through" "$_o" "$_c"

_o="$(cd "$_r" && printf 'not json' | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null)"; _c=$?
allowed_raw "malformed json on stdin is allowed through" "$_o" "$_c"

_o="$(cd "$_r" && printf '' | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null)"; _c=$?
allowed_raw "empty stdin is allowed through" "$_o" "$_c"

_o="$(cd "$_r" && jq -n '{tool_name:"Bash",tool_input:{}}' | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null)"; _c=$?
allowed_raw "a payload with no command is allowed through" "$_o" "$_c"

_o="$(cd "$_g" && payload 'git commit -m "x"' | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null)"; _c=$?
allowed_raw "outside a git repo it is allowed through" "$_o" "$_c"

# Absolute interpreter: an emptied PATH would otherwise hide `bash` itself and
# the 127 would be the shell's, not the gate's. Exit 0 alone proves nothing here
# -- the gate exits 0 on the deny path too -- so assert empty stdout with it.
_o="$(cd "$_r" && payload 'git commit -m "x"' | PATH=/nonexistent CLAUDE_PLUGIN_ROOT="$PLUGIN" "$BASH" "$GATE" 2>/dev/null)"; _c=$?
allowed_raw "without jq on PATH it is allowed through" "$_o" "$_c"

# A non-writable git dir must not wedge every retry: the gate cannot record that
# it already denied, so it must allow rather than deny the same set forever.
_r="$(newrepo unwritable)"
printf '%s' "$_bloat" > "$_r/new.ts"; (cd "$_r" && git add new.ts)
chmod a-w "$_r/.git" 2>/dev/null
allowed "a non-writable git dir allows rather than wedges" "$_r" 'git commit -m "x"' 
chmod u+w "$_r/.git" 2>/dev/null

# ---------- a linked worktree, where .git is a file ----------
_r="$(newrepo worktree)"
(cd "$_r" && git worktree add -q -b wt "$_g/wt" 2>/dev/null)
touch "$_g/wt/.comment-cut-gate"
printf '%s' "$_bloat" > "$_g/wt/new.ts"; (cd "$_g/wt" && git add new.ts)
check "the worktree's .git is a file, not a directory" "[ -f '$_g/wt/.git' ]"
check_eq "denies inside a linked worktree" "deny" \
  "$(decision "$(fire "$_g/wt" 'git commit -m "x"')")"
allowed "and the retry there is allowed" "$_g/wt" 'git commit -m "x"' 

# The exit code is always 0. A hook that exits non-zero surfaces as an error on
# a tool call the user did nothing wrong on.
(cd "$_r" && payload 'git commit -m "x"' | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" >/dev/null 2>&1)
check_eq "the gate always exits 0" "0" "$?"

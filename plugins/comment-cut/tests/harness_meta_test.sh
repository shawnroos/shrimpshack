# harness_meta_test.sh — the harness's own guards.
#
# The other suites cannot prove these: a guard that stops a broken run cannot be
# checked from inside the run it would stop. So this file builds throwaway plugin
# dirs, each with a deliberately broken test file, and runs harness.sh against
# them as a subprocess.
#
# Removing a guard and watching for red proves nothing here — deleting an
# assertion is green by construction. What matters is that each guard FIRES when
# its condition occurs, which is what these assert.

_h="$(mktemp -d "${TMPDIR:-/tmp}/cc-meta.XXXXXX")"
trap 'rm -rf "$_h"' RETURN

# fake_plugin <name> — a minimal plugin tree the harness can run against.
fake_plugin() {
  local d="$_h/$1"
  mkdir -p "$d/tests"
  cp "$PLUGIN/tests/harness.sh" "$d/tests/harness.sh" 2>/dev/null
  printf '%s' "$d"
}

# run_fake <dir> <expect-files> — returns the harness's exit code; stdout+stderr
# land in $_out.
run_fake() {
  _out="$(MIN_ASSERTIONS=1 EXPECT_FILES="$2" bash "$1/tests/harness.sh" 2>&1)"
  return $?
}

# --- a healthy fake passes, so a red result below means the guard, not the rig ---
_d="$(fake_plugin healthy)"
cat > "$_d/tests/a_test.sh" <<'EOF'
check_eq "fake assertion" "1" "1"
EOF
run_fake "$_d" 1
check_eq "a healthy fake suite exits 0" "0" "$?"

# --- a file that fails to parse must fail the run, not shorten it ---
_d="$(fake_plugin broken)"
cat > "$_d/tests/a_test.sh" <<'EOF'
check_eq "before the break" "1" "1"
if [ ; then
check_eq "after the break" "1" "1"
EOF
run_fake "$_d" 1
check_eq "a parse error fails the run" "1" "$?"
check "the parse error is named" "printf '%s' \"\$_out\" | grep -q 'failed to load'"

# --- a file that asserts nothing is a failure, not a pass ---
_d="$(fake_plugin silent)"
cat > "$_d/tests/a_test.sh" <<'EOF'
: # runs cleanly, asserts nothing
EOF
run_fake "$_d" 1
check_eq "a file with no assertions fails the run" "1" "$?"
check "the silent file is named" "printf '%s' \"\$_out\" | grep -q 'contributed no assertions'"

# --- an exit inside a sourced file must not swallow a recorded failure ---
_d="$(fake_plugin earlyexit)"
cat > "$_d/tests/a_test.sh" <<'EOF'
bad "a real failure"
exit 0
EOF
run_fake "$_d" 1
check_eq "an early exit cannot discard a failure" "1" "$?"

# --- a test file's cwd and side effects cannot reach the real tree ---
_d="$(fake_plugin escape)"
mkdir -p "$_d/victim"
printf 'do not delete me\n' > "$_d/victim/keep.txt"
cat > "$_d/tests/a_test.sh" <<'EOF'
cd ../victim 2>/dev/null && rm -rf ./keep.txt 2>/dev/null
check_eq "fake assertion" "1" "1"
EOF
run_fake "$_d" 1
check "a test file cannot delete outside its sandbox" "[ -f '$_d/victim/keep.txt' ]"

# --- a stray git write cannot reach a repo outside the sandbox ---
# This is not hypothetical: an unguarded `cd` in a test left
# `git update-ref refs/remotes/origin/main` running in the real repository, and
# it moved that ref.
_d="$(fake_plugin refwrite)"
mkdir -p "$_d/victim"
( cd "$_d/victim" || exit 1
  git init -q .
  git config user.email t@t; git config user.name t
  echo x > f.txt; git add f.txt; git commit -qm seed
  git update-ref refs/remotes/origin/main HEAD )
_before="$(git -C "$_d/victim" rev-parse refs/remotes/origin/main)"
cat > "$_d/tests/a_test.sh" <<'EOF'
cd ../victim 2>/dev/null
git update-ref refs/remotes/origin/main "$(git rev-parse HEAD 2>/dev/null)" 2>/dev/null
check_eq "fake assertion" "1" "1"
EOF
run_fake "$_d" 1
_after="$(git -C "$_d/victim" rev-parse refs/remotes/origin/main)"
check_eq "a test file cannot move another repo's refs" "$_before" "$_after"

# --- losing a whole test file must trip the count, which the floor cannot see ---
_d="$(fake_plugin dropped)"
cat > "$_d/tests/a_test.sh" <<'EOF'
check_eq "fake assertion" "1" "1"
EOF
run_fake "$_d" 2          # claim two files exist; only one does
check_eq "a missing test file fails the run" "1" "$?"
check "the file count is named" "printf '%s' \"\$_out\" | grep -q 'test files collected'"

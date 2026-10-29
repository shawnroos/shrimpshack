#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }

echo "programme-worktree.test.sh"

# mktemp under /var resolves to /private/var on macOS: the symlinked spelling is the point.
WORK="$(mktemp -d -t auto-pmwt.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
pw = load_lib_module("programme_worktree")
args = sys.argv[2:]
$(cat)
PYEOF
}

new_repo() {
  git init -q "$1" && git -C "$1" commit -q --allow-empty -m init
}

create() {
  run_py "$1" "$2" <<'EOF'
out = pw.create(args[0], args[1])
rec = out["record"]
print(out["status"], rec and rec["path"], rec and rec["repo"], out.get("error") or "")
EOF
}

REPO="${WORK}/repo"
REAL_REPO="$("$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$REPO")"
new_repo "$REPO"
TARGET="${REAL_REPO}/worktrees/programme-r1"

it "creating from a main checkout makes <checkout>/worktrees/programme-<run>, recorded with the main checkout"
OUT="$(create "$REPO" r1)"
check "created ${TARGET} ${REAL_REPO} " "$OUT"

it "the new worktree is registered and detached, and no branch was added"
LISTED="$(git -C "$REPO" worktree list --porcelain | grep -A3 "^worktree ${TARGET}$" | grep -c '^detached$')"
BRANCHES="$(git -C "$REPO" branch --list | wc -l | tr -d ' ')"
check "1 1" "${LISTED} ${BRANCHES}"

it "the record value carries path, repo and created_at"
OUT="$(run_py "$REPO" <<'EOF'
out = pw.create(args[0], "r1")
print(sorted(out["record"]), out["record"]["created_at"].endswith("Z"))
EOF
)"
check "['created_at', 'path', 'repo'] True" "$OUT"

it "a registered worktree already at the target is adopted, not added twice"
OUT="$(create "$REPO" r1)"
COUNT="$(git -C "$REPO" worktree list --porcelain | grep -c "^worktree ${TARGET}$")"
check "adopted ${TARGET} ${REAL_REPO}  1" "${OUT} ${COUNT}"

it "worktrees/ goes into .git/info/exclude once, and the main checkout's status stays clean"
create "$REPO" r2 >/dev/null
EXCL="$(grep -cx 'worktrees/' "${REPO}/.git/info/exclude")"
STATUS="$(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')"
check "1 0" "${EXCL} ${STATUS}"

it "a repo that already ignores worktrees/ gets no exclude line"
IGN="${WORK}/ignored"
new_repo "$IGN"
printf 'worktrees/\n' > "${IGN}/.gitignore"
git -C "$IGN" add .gitignore && git -C "$IGN" commit -q -m ignore
create "$IGN" r1 >/dev/null
check "0" "$(grep -cx 'worktrees/' "${IGN}/.git/info/exclude" 2>/dev/null || true)"

it "a .gitignore that re-includes worktrees/ still gets only one exclude line across creates"
NEG="${WORK}/negated"
new_repo "$NEG"
printf '!worktrees/\n' > "${NEG}/.gitignore"
create "$NEG" r1 >/dev/null
create "$NEG" r2 >/dev/null
check "1" "$(grep -cx 'worktrees/' "${NEG}/.git/info/exclude")"

it "creating from a linked worktree puts the programme worktree under the main checkout"
git -C "$REPO" worktree add -q --detach "${WORK}/linked" >/dev/null 2>&1
OUT="$(create "${WORK}/linked" r3)"
check "created ${REAL_REPO}/worktrees/programme-r3 ${REAL_REPO} " "$OUT"

it "a plain folder at the target makes creation refuse, naming the path, and leaves the folder alone"
mkdir -p "${REPO}/worktrees/programme-r4"
echo keep > "${REPO}/worktrees/programme-r4/note.txt"
OUT="$(create "$REPO" r4)"
case "$OUT" in
  "refused None None "*"${REAL_REPO}/worktrees/programme-r4"*) R=ok ;;
  *) R="$OUT" ;;
esac
check "ok keep 0" "${R} $(cat "${REPO}/worktrees/programme-r4/note.txt") $(git -C "$REPO" worktree list --porcelain | grep -c programme-r4)"

it "a registered worktree at the target where git status fails is reported, not adopted"
create "$REPO" r5 >/dev/null
BROKEN="${REAL_REPO}/worktrees/programme-r5"
echo "gitdir: ${WORK}/nowhere" > "${BROKEN}/.git"
OUT="$(create "$REPO" r5)"
case "$OUT" in
  "unusable None None "*"${BROKEN}"*) check ok ok ;;
  *) check "unusable ..." "$OUT" ;;
esac

it "a path outside any git repo is refused"
mkdir -p "${WORK}/plain"
OUT="$(create "${WORK}/plain" r6)"
case "$OUT" in "refused None None "*) check ok ok ;; *) check "refused ..." "$OUT" ;; esac

it "the module removes a worktree only inside release, and never prunes"
OUT="$("$PY" - "${AUTO_ROOT}/lib/programme_worktree.py" <<'EOF'
import re, sys
text = open(sys.argv[1]).read()
blocks = re.split(r"(?m)^(?=def )", text)
print(sorted({re.match(r"def (\w+)", b).group(1) if b.startswith("def ") else "<module>"
              for b in blocks if re.search(r'"remove"|"prune"|worktree (remove|prune)', b)}))
EOF
)"
check "['release']" "$OUT"

# auto-spawn.py rolls back worktrees it created moments earlier in the same call, with -f; it
# predates this guard and holds no one's work. Any other forced or pruning removal fails here.
it "no code in lib/ removes a worktree with -f or --force, or prunes worktrees"
HITS="$(grep -rnE '"remove"[^])]*"(-f|--force)"|worktree remove +(-f|--force)|worktree", *"prune"|worktree prune' \
  "${AUTO_ROOT}/lib" | grep -v '^[^:]*/lib/auto-spawn\.py:' || true)"
check "" "$HITS"

it "inside: the worktree and a subdirectory are inside; its parent and a sibling are not"
mkdir -p "${TARGET}/sub"
OUT="$(run_py "$TARGET" <<'EOF'
wt = args[0]
print(pw.inside(wt, wt), pw.inside(os.path.join(wt, "sub"), wt),
      pw.inside(os.path.dirname(wt), wt), pw.inside(wt + "-sibling", wt),
      pw.inside(None, wt), pw.inside(wt, None))
EOF
)"
check "True True False False False False" "$OUT"

it "inside: a symlinked spelling on one side still counts (/tmp vs /private/tmp)"
LINKDIR="${WORK}/link"
ln -s "$TARGET" "$LINKDIR"
OUT="$(run_py "$TARGET" "$LINKDIR" <<'EOF'
print(pw.inside(args[1], args[0]), pw.inside(os.path.join(args[0], "sub"), args[1]),
      pw.inside("/tmp", "/private/tmp"))
EOF
)"
check "True True True" "$OUT"

echo ""
echo "programme-worktree.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

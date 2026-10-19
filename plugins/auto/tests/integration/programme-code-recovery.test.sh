#!/usr/bin/env bash
# AE3 — vanished worker source: code captured from a synthetic worktree restores after the
# source is gone, and capture never mutates the source repository.
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

echo "programme-code-recovery.test.sh"

WORK="$(mktemp -d -t auto-code-recovery.XXXXXX)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
printf 'export FIXTURE_TOKEN="fixture-value-9f8e7d"\n' > "$CLAUDE_AUTO_SECRETS_FILE"
# shellcheck source=../helpers/preserve-fixtures.sh
. "${AUTO_ROOT}/tests/helpers/preserve-fixtures.sh"

RUN="$(field "$(pp create)" run)"

# ── Scenario 1 (AE3): local-only commit, binary change, staged/unstaged, untracked ──
SRC="${WORK}/w/rich"
mkrich "$SRC"
EXP_INDEX="$(index_listing "$SRC")"
EXP_TREE="$(tree_digest "$SRC")"
EXP_HEAD="$(g -C "$SRC" rev-parse HEAD)"
EXP_LOG="$(g -C "$SRC" log --format=%H%x09%s main)"
EXP_BRANCH="$(g -C "$SRC" symbolic-ref HEAD)"
EXP_STAGED_A="$(g -C "$SRC" ls-files -s a.txt | cut -d' ' -f2)"
BEFORE_GIT="$(gitdir_digest "$SRC")"
BEFORE_REFS="$(g -C "$SRC" for-each-ref --format='%(objectname) %(refname)')"
BEFORE_REFLOG="$(g -C "$SRC" reflog show --format=%H HEAD)"

OUT="$(pp capture "{\"run\":\"$RUN\",\"path\":\"$SRC\"}")"
SID="$(field "$OUT" source_id)"
it "capture of the rich worktree is complete and verified"
check "complete" "$(field "$OUT" status)"
it "the receipt is bound to a source generation"
case "$(field "$OUT" generation)" in [0-9a-f]*) pass ;; *) fail "generation [$(field "$OUT" generation)] in $OUT" ;; esac

it "capture left the source git dir byte-identical (no commit, ref, reflog or index write)"
check "$BEFORE_GIT" "$(gitdir_digest "$SRC")"
it "capture left the source refs and reflog unchanged"
check "${BEFORE_REFS}|${BEFORE_REFLOG}" \
  "$(g -C "$SRC" for-each-ref --format='%(objectname) %(refname)')|$(g -C "$SRC" reflog show --format=%H HEAD)"
it "capture left the source worktree unchanged"
check "$EXP_TREE" "$(tree_digest "$SRC")"

# Only the synthetic fixture is removed.
mv "$SRC" "${WORK}/moved-away"
rm -rf "${WORK}/moved-away"
it "the source is gone"
check "absent" "$([ -e "$SRC" ] && echo present || echo absent)"

OUT="$(pp verify "{\"run\":\"$RUN\",\"source\":\"$SID\"}")"
it "the independent verifier passes without the source"
check "True|" "$(field "$OUT" ok)|$(field "$OUT" mismatches)"

DEST="${WORK}/restored"
OUT="$(pp restore "{\"run\":\"$RUN\",\"source\":\"$SID\",\"dest\":\"$DEST\"}")"
it "restore materialises a repository"
check "True" "$(field "$OUT" ok)"
it "restored index (stages, modes, blob ids, raw names) equals the source index"
check "$EXP_INDEX" "$(index_listing "$DEST")"
it "restored worktree bytes, modes, deletions and symlink targets equal the source worktree"
check "$EXP_TREE" "$(tree_digest "$DEST")"
it "restored HEAD is the local-only commit on the same branch"
check "${EXP_HEAD}|${EXP_BRANCH}" "$(g -C "$DEST" rev-parse HEAD)|$(g -C "$DEST" symbolic-ref HEAD)"
it "restored branch history equals the source history"
check "$EXP_LOG" "$(g -C "$DEST" log --format=%H%x09%s main)"
it "the staged-only blob of a.txt is readable in the restored repo"
check "staged" "$(g -C "$DEST" cat-file blob "$EXP_STAGED_A")"
it "the unstaged worktree a.txt differs from its staged blob, as in the source"
check "unstaged" "$(cat "$DEST/a.txt")"
it "the binary worktree change is restored byte-for-byte"
check "0002" "$(od -An -tx1 -N2 "$DEST/img.bin" | tr -d ' \n')"
it "the restored repository passes git fsck"
if g -C "$DEST" fsck --full --strict --no-dangling >/dev/null 2>&1; then pass; else fail "fsck failed"; fi
it "a restore never overwrites an existing destination"
OUT="$(pp restore "{\"run\":\"$RUN\",\"source\":\"$SID\",\"dest\":\"$DEST\"}")"
check "False|dest_exists" "$(field "$OUT" ok)|$(field "$OUT" code)"

# ── Scenario 3: detached and reflog-only history, no source ref mutation ────────────
SRC3="${WORK}/w/detached"
mkrepo "$SRC3"
printf 'kept by reflog\n' > "$SRC3/r.txt"; g -C "$SRC3" add r.txt; g -C "$SRC3" commit -qm reflog-only
REFLOG_ONLY="$(g -C "$SRC3" rev-parse HEAD)"
g -C "$SRC3" reset -q --hard HEAD~1
g -C "$SRC3" checkout -q --detach
printf 'detached\n' > "$SRC3/d.txt"; g -C "$SRC3" add d.txt; g -C "$SRC3" commit -qm detached-only
DETACHED="$(g -C "$SRC3" rev-parse HEAD)"
it "fixture: the reflog-only commit is on no ref and the detached commit on no branch"
check "|" "$(g -C "$SRC3" for-each-ref --contains "$REFLOG_ONLY")|$(g -C "$SRC3" for-each-ref --contains "$DETACHED")"
BEFORE_GIT3="$(gitdir_digest "$SRC3")"
OBJECTS3="$(g -C "$SRC3" count-objects -v | grep -E '^(count|in-pack)')"
OUT="$(pp capture "{\"run\":\"$RUN\",\"path\":\"$SRC3\"}")"
SID3="$(field "$OUT" source_id)"
it "detached capture is complete"
check "complete" "$(field "$OUT" status)"
it "capture created no ref, commit or object in the source"
check "${BEFORE_GIT3}|${OBJECTS3}" "$(gitdir_digest "$SRC3")|$(g -C "$SRC3" count-objects -v | grep -E '^(count|in-pack)')"
rm -rf "$SRC3"
DEST3="${WORK}/restored3"
pp restore "{\"run\":\"$RUN\",\"source\":\"$SID3\",\"dest\":\"$DEST3\"}" >/dev/null
it "restored HEAD is detached at the detached-only commit"
check "${DETACHED}|detached" "$(g -C "$DEST3" rev-parse HEAD)|$(g -C "$DEST3" symbolic-ref -q HEAD || echo detached)"
it "the reflog-only commit and its tree are restored"
check "commit|kept by reflog" "$(g -C "$DEST3" cat-file -t "$REFLOG_ONLY")|$(g -C "$DEST3" show "$REFLOG_ONLY:r.txt")"

# ── Linked worktree (the shape worker worktrees have) ───────────────────────────────
MAIN="${WORK}/w/main"
mkrepo "$MAIN"
g -C "$MAIN" worktree add -q -b feature "${WORK}/w/linked" >/dev/null 2>&1
LINKED="${WORK}/w/linked"
printf 'feature work\n' > "$LINKED/f.txt"; g -C "$LINKED" add f.txt; g -C "$LINKED" commit -qm feature
printf 'wip\n' > "$LINKED/wip.txt"
EXP_INDEX_L="$(index_listing "$LINKED")"
EXP_TREE_L="$(tree_digest "$LINKED")"
BEFORE_GIT_L="$(gitdir_digest "$LINKED")"
OUT="$(pp capture "{\"run\":\"$RUN\",\"path\":\"$LINKED\"}")"
SIDL="$(field "$OUT" source_id)"
it "a linked worktree captures completely"
check "complete" "$(field "$OUT" status)"
it "capture left the shared git dir byte-identical"
check "$BEFORE_GIT_L" "$(gitdir_digest "$LINKED")"
rm -rf "$LINKED" "$MAIN"
DESTL="${WORK}/restoredL"
pp restore "{\"run\":\"$RUN\",\"source\":\"$SIDL\",\"dest\":\"$DESTL\"}" >/dev/null
it "the linked worktree restores its index, bytes and branch without the main repo"
check "${EXP_INDEX_L}|${EXP_TREE_L}|refs/heads/feature" \
  "$(index_listing "$DESTL")|$(tree_digest "$DESTL")|$(g -C "$DESTL" symbolic-ref HEAD)"

echo
echo "programme-code-recovery.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Exact code capture (KTD9): binary privacy admission, fidelity of restored shapes, unsafe
# capture refusal (AE4), self-contained bundles, generation-bound receipts and git isolation.
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
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "programme-preserve.test.sh"

WORK="$(mktemp -d -t auto-preserve.XXXXXX)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
SECRET="fixture-value-9f8e7d"
printf 'export FIXTURE_TOKEN="%s"\n' "$SECRET" > "$CLAUDE_AUTO_SECRETS_FILE"
# shellcheck source=../helpers/preserve-fixtures.sh
. "${AUTO_ROOT}/tests/helpers/preserve-fixtures.sh"

RUN="$(field "$(pp create)" run)"
HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"
capture() { pp capture "{\"run\":\"$RUN\",\"path\":\"$1\"${2:+,$2}}"; }
hatched() { local h="$1"; shift; env CLAUDE_AUTO_TEST_HARNESS=1 "CLAUDE_AUTO_TEST_PRESERVE_${h}=1" "$PY" "$DRIVER" "$AUTO_ROOT" "$@" 2>&1; }
cleanup_of() { pp cleanup "{\"run\":\"$RUN\",\"source\":\"$1\"}"; }
leaks() { grep -rlaF -- "$1" "$HOME_DIR" 2>/dev/null | wc -l | tr -d ' '; }
hexs() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

# ── Binary privacy admission ───────────────────────────────────────────────────────
scan() { field "$(pp scan "{\"hex\":\"$1\"}")" decision; }
it "binary bytes without secrets are admitted"
check "admitted" "$(scan "$(printf '\000\001\377plain' | od -An -tx1 | tr -d ' \n')")"
it "a secrets-file value inside binary bytes is prohibited"
check "prohibited" "$(scan "$(printf '\000\377%s\000' "$SECRET" | od -An -tx1 | tr -d ' \n')")"
it "a token pattern inside binary bytes is prohibited"
check "prohibited" "$(scan "$(printf '\000\377ghp_abcdefghijklmnopqrstuvwxyz0123\000' | od -An -tx1 | tr -d ' \n')")"
it "a UTF-16 encoded secrets-file value is prohibited"
check "prohibited" "$(scan "$("$PY" -c 'import sys; print(("x"+sys.argv[1]).encode("utf-16-le").hex())' "$SECRET")")"
it "compressed bytes cannot be scanned and are uncertain"
check "uncertain" "$(scan "$(printf 'plain text' | gzip -c | od -An -tx1 | tr -d ' \n')")"
it "a payload with a mismatched precomputed admission is refused by publish (digest-bound)"
OUT="$("$PY" - "$AUTO_ROOT" "$RUN" <<'PYEOF' 2>&1
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
pa = load_lib_module("programme_artifacts"); pp = load_lib_module("programme_preserve")
good = pp.admit_binary(b"\x00clean")
try:
    with pa.publisher(sys.argv[2]):
        pa.publish(sys.argv[2], b"\x00other", "application/octet-stream", admission=good)
    print("ACCEPTED")
except pa.ArtifactError as exc:
    print(exc.code)
PYEOF
)"
check "unsupported" "$OUT"

# ── Scenario 2: deletions, exec mode, symlinks, unusual names, conflict stages ─────
SRC2="${WORK}/w/shapes"
mkrich "$SRC2"
EXP2="$(index_listing "$SRC2")|$(tree_digest "$SRC2")"
OUT="$(capture "$SRC2")"
SID2="$(field "$OUT" source_id)"
it "the shapes fixture captures completely"
check "complete" "$(field "$OUT" status)"
mv "$SRC2" "${WORK}/gone2"; rm -rf "${WORK}/gone2"
pp restore "{\"run\":\"$RUN\",\"source\":\"$SID2\",\"dest\":\"${WORK}/r2\"}" >/dev/null
it "restored index and worktree equal the source (names, modes, symlinks, deletions)"
check "$EXP2" "$(index_listing "${WORK}/r2")|$(tree_digest "${WORK}/r2")"
it "the executable keeps its mode and the deleted files stay deleted"
check "x|absent|absent" "$([ -x "${WORK}/r2/run.sh" ] && echo x)|$([ -e "${WORK}/r2/gone.txt" ] && echo present || echo absent)|$([ -e "${WORK}/r2/staged-gone.txt" ] && echo present || echo absent)"
it "symlink targets are kept verbatim and never followed"
check "a.txt|../../outside/target" "$(readlink "${WORK}/r2/link")|$(readlink "${WORK}/r2/dangling")"
it "a newline in a file name round-trips"
check "nl" "$(cat "${WORK}/r2/$(printf 'line\nbreak.txt')")"

SRCC="${WORK}/w/conflict"
mkconflict "$SRCC"
EXPC="$(index_listing "$SRCC")"
it "fixture: the conflict fixture has stages 1, 2 and 3"
check "1 2 3" "$(g -C "$SRCC" ls-files -s c.txt | awk '{print $3}' | tr '\n' ' ' | sed 's/ $//')"
OUT="$(capture "$SRCC")"
SIDC="$(field "$OUT" source_id)"
it "conflict capture is complete"
check "complete" "$(field "$OUT" status)"
rm -rf "$SRCC"
pp restore "{\"run\":\"$RUN\",\"source\":\"$SIDC\",\"dest\":\"${WORK}/rc\"}" >/dev/null
it "conflict-stage blobs and the merge-marked worktree restore exactly"
check "$EXPC" "$(index_listing "${WORK}/rc")"

# ── Scenario 4 (AE4): unsafe capture blocks cleanup and retains the source ─────────
SRC4="${WORK}/w/history"
mkrepo "$SRC4"
printf 'key=%s\n' "$SECRET" > "$SRC4/cfg.txt"; g -C "$SRC4" add cfg.txt; g -C "$SRC4" commit -qm leak
g -C "$SRC4" rm -q cfg.txt; g -C "$SRC4" commit -qm unleak
BEFORE4="$(gitdir_digest "$SRC4")|$(tree_digest "$SRC4")"
OUT="$(capture "$SRC4")"
SID4="$(field "$OUT" source_id)"
it "a known secret anywhere in required history refuses capture as prohibited"
check "False|prohibited" "$(field "$OUT" ok)|$(field "$OUT" code)"
it "the refusal names no secret"
lacks "$SECRET" "$OUT"
it "cleanup refuses for the refused source"
check "False" "$(field "$(cleanup_of "code:$(printf '%s' "$(cd "$SRC4" && pwd -P)" | shasum -a 256 | cut -c1-24)")" allowed)"
it "the source is retained untouched"
check "$BEFORE4" "$(gitdir_digest "$SRC4")|$(tree_digest "$SRC4")"

SRC4b="${WORK}/w/untracked-secret"
mkrepo "$SRC4b"
printf '\000bin %s\000' "$SECRET" > "$SRC4b/blob.dat"
it "a secret in a required untracked binary file is prohibited"
check "prohibited" "$(field "$(capture "$SRC4b")" code)"

SRC4c="${WORK}/w/ignored-secret"
mkrepo "$SRC4c"
printf '.env\n' > "$SRC4c/.gitignore"; g -C "$SRC4c" add .gitignore; g -C "$SRC4c" commit -qm ignore
printf 'X=%s\n' "$SECRET" > "$SRC4c/.env"
it "an ignored file holding a secret is not required by default and capture completes"
check "complete" "$(field "$(capture "$SRC4c")" status)"
it "a required ignored file holding a secret refuses capture"
check "prohibited" "$(field "$(capture "$SRC4c" '"ignored":[".env"]')" code)"

SRC4d="${WORK}/w/lfs"
mkrepo "$SRC4d"
printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%064d\nsize 12\n' 0 > "$SRC4d/big.psd"
g -C "$SRC4d" add big.psd; g -C "$SRC4d" commit -qm lfs
it "a required LFS payload (external bytes) refuses capture as unsupported"
check "unsupported" "$(field "$(capture "$SRC4d")" code)"

SRC4e="${WORK}/w/submodule"
mkrepo "$SRC4e"
SUBC="$(g -C "$SRC4e" rev-parse HEAD)"
g -C "$SRC4e" update-index --add --cacheinfo "160000,${SUBC},vendor/sub"
it "a submodule gitlink refuses capture as unsupported"
check "unsupported" "$(field "$(capture "$SRC4e")" code)"

SRC4f="${WORK}/w/lock"
mkrepo "$SRC4f"
: > "$SRC4f/.git/index.lock"
it "a live index.lock makes quiescence uncertain"
check "quiescence_uncertain" "$(field "$(capture "$SRC4f")" code)"
rm -f "$SRC4f/.git/index.lock"

SRC4g="${WORK}/w/moving"
mkrepo "$SRC4g"
RESUME="${HOME_DIR}/.test-resume-preserve"
rm -f "$RESUME"
hatched PAUSE_BEFORE_RESCAN capture "{\"run\":\"$RUN\",\"path\":\"$SRC4g\"}" > "${WORK}/moving.out" &
BG=$!
for _ in $(seq 1 100); do grep -q paused "${WORK}/moving.out" 2>/dev/null && break; sleep 0.1; done
printf 'written during capture\n' > "$SRC4g/a.txt"
touch "$RESUME"
wait "$BG"
OUT="$(grep -v paused "${WORK}/moving.out")"
it "a source that changes during capture makes quiescence uncertain"
check "False|quiescence_uncertain" "$(field "$OUT" ok)|$(field "$OUT" code)"
rm -f "$RESUME"

it "no prohibited fixture bytes exist anywhere in the home after the refusals"
check "0" "$(leaks "$SECRET")"
it "positive control: the leak grep finds a planted copy"
printf '%s' "$SECRET" > "${HOME_DIR}/planted"; check "1" "$(leaks "$SECRET")"; rm -f "${HOME_DIR}/planted"

# ── Scenario 5: an incremental bundle relying on source objects fails ─────────────
SRC5="${WORK}/w/incremental"
mkrepo "$SRC5"
printf 'two\n' > "$SRC5/b.txt"; g -C "$SRC5" add b.txt; g -C "$SRC5" commit -qm two
OUT="$(hatched INCREMENTAL capture "{\"run\":\"$RUN\",\"path\":\"$SRC5\"}")"
it "a capture whose bundle has prerequisites is incomplete, with the source still present"
check "incomplete" "$(field "$OUT" status)"
has "bundle_prerequisites" "$(field "$OUT" reasons)"
it "cleanup refuses after an incomplete capture"
check "False" "$(field "$(cleanup_of "$(field "$OUT" source_id)")" allowed)"
g -C "$SRC5" bundle create -q "${WORK}/inc.bundle" HEAD~1..HEAD 2>/dev/null
it "a git-made incremental bundle fails the bundle check"
OUT="$(pp bundle "{\"file\":\"${WORK}/inc.bundle\"}")"
check "False|bundle_prerequisites" "$(field "$OUT" ok)|$(field "$OUT" code)"

# ── Scenario 6: changed inventory or substituted worktree invalidates the receipt ───
SRC6="${WORK}/w/receipt"
mkrepo "$SRC6"
printf 'wip\n' > "$SRC6/wip.txt"
OUT="$(capture "$SRC6")"
SID6="$(field "$OUT" source_id)"
it "positive control: an unchanged source after a complete capture may be cleaned"
OUT="$(cleanup_of "$SID6")"
check "True" "$(field "$OUT" allowed)"
printf 'later edit\n' >> "$SRC6/wip.txt"
it "an edit after capture invalidates the receipt"
OUT="$(cleanup_of "$SID6")"
check "False" "$(field "$OUT" allowed)"
has "generation_changed" "$(field "$OUT" reasons)"
printf 'wip\n' > "$SRC6/wip.txt"
mv "$SRC6" "${WORK}/w/receipt-orig"
cp -Rp "${WORK}/w/receipt-orig" "$SRC6"
it "a substituted worktree with identical content invalidates the receipt"
OUT="$(cleanup_of "$SID6")"
check "False" "$(field "$OUT" allowed)"
has "identity_changed" "$(field "$OUT" reasons)"
rm -rf "$SRC6"; mv "${WORK}/w/receipt-orig" "$SRC6"
it "the original worktree back in place is allowed again"
check "True" "$(field "$(cleanup_of "$SID6")" allowed)"
it "a tampered retained object closes cleanup"
OBJ6="$("$PY" - "$AUTO_ROOT" "$RUN" "$SID6" <<'PYEOF'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
pa = load_lib_module("programme_artifacts"); pp = load_lib_module("programme_preserve")
entry = pp.entry_for(sys.argv[2], sys.argv[3])
print(pa.object_path(sys.argv[2], entry["manifest"]["digest"]))
PYEOF
)"
cp -p "$OBJ6" "${WORK}/obj6.bak"; chmod u+w "$OBJ6"; printf 'x' >> "$OBJ6"
check "False" "$(field "$(cleanup_of "$SID6")" allowed)"
/bin/cp -f "${WORK}/obj6.bak" "$OBJ6"
it "cleanup is excluded while a capture of the source is running"
hatched PAUSE_BEFORE_RESCAN capture "{\"run\":\"$RUN\",\"path\":\"$SRC6\"}" > "${WORK}/excl.out" &
BG=$!
for _ in $(seq 1 100); do grep -q paused "${WORK}/excl.out" 2>/dev/null && break; sleep 0.1; done
OUT="$(cleanup_of "$SID6")"
touch "$RESUME"; wait "$BG"; rm -f "$RESUME"
check "False" "$(field "$OUT" allowed)"
has "capture_in_progress" "$(field "$OUT" reasons)"

# ── Scenario 7: no hooks, filters, textconv, fsmonitor or project code run ─────────
SRC7="${WORK}/w/hostile"
mkrich "$SRC7"
MARK="${WORK}/marks"; mkdir -p "$MARK" "${WORK}/hooks"
cat > "${WORK}/mark.sh" <<EOF
#!/bin/sh
echo "\$0 \$*" >> "${MARK}/ran"
cat
EOF
chmod +x "${WORK}/mark.sh"
for h in pre-commit post-checkout post-index-change reference-transaction pre-auto-gc post-rewrite fsmonitor-watchman; do
  ln -sf "${WORK}/mark.sh" "${WORK}/hooks/$h"; ln -sf "${WORK}/mark.sh" "$SRC7/.git/hooks/$h"
done
printf '* filter=x diff=x\n' > "$SRC7/.gitattributes"
g -C "$SRC7" config core.hooksPath "${WORK}/hooks"
g -C "$SRC7" config core.fsmonitor "${WORK}/mark.sh"
g -C "$SRC7" config filter.x.clean "${WORK}/mark.sh clean"
g -C "$SRC7" config filter.x.smudge "${WORK}/mark.sh smudge"
g -C "$SRC7" config filter.x.process "${WORK}/mark.sh process"
g -C "$SRC7" config filter.x.required true
g -C "$SRC7" config diff.x.textconv "${WORK}/mark.sh textconv"
g -C "$SRC7" config core.pager "${WORK}/mark.sh pager"
OUT="$(env GIT_DIR=/nonexistent GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath \
  GIT_CONFIG_VALUE_0="${WORK}/hooks" GIT_EXTERNAL_DIFF="${WORK}/mark.sh" \
  "$PY" "$DRIVER" "$AUTO_ROOT" capture "{\"run\":\"$RUN\",\"path\":\"$SRC7\"}" 2>&1)"
SID7="$(field "$OUT" source_id)"
it "a source with planted hooks, filters, textconv and fsmonitor captures completely"
check "complete" "$(field "$OUT" status)"
OUT="$(pp verify "{\"run\":\"$RUN\",\"source\":\"$SID7\"}")"
pp restore "{\"run\":\"$RUN\",\"source\":\"$SID7\",\"dest\":\"${WORK}/r7\"}" >/dev/null
it "the verifier and restore pass"
check "True" "$(field "$OUT" ok)"
it "collector, verifier and restore ran no hook, filter, textconv, pager or fsmonitor"
check "none" "$(cat "${MARK}/ran" 2>/dev/null || echo none)"
it "positive control: the planted fsmonitor and filters do run under plain git"
g -C "$SRC7" status >/dev/null 2>&1
has "mark.sh" "$(cat "${MARK}/ran" 2>/dev/null)"

# ── Scenario 8: independently asserted inventories catch omissions ─────────────────
SRC8="${WORK}/w/omit"
mkconflict "$SRC8"
printf 'staged only\n' > "$SRC8/s.txt"; g -C "$SRC8" add s.txt
printf 'scratch/\n' >> "$SRC8/.git/info/exclude"; mkdir -p "$SRC8/scratch"; printf 'needed\n' > "$SRC8/scratch/keep.txt"
OLDHEAD="$(g -C "$SRC8" rev-parse HEAD)"
# Independent expectation, from plain git and shasum on the fixture only.
IND_INDEX="$(index_listing "$SRC8")"
IND_STAGED="$(g -C "$SRC8" ls-files -s s.txt | cut -d' ' -f2)"
IND_IGNORED="$(shasum -a 256 < "$SRC8/scratch/keep.txt" | cut -c1-64)"
SRC8D="${WORK}/w/omit-detached"
mkrepo "$SRC8D"; g -C "$SRC8D" checkout -q --detach
printf 'det\n' > "$SRC8D/x.txt"; g -C "$SRC8D" add x.txt; g -C "$SRC8D" commit -qm det
IND_DETACHED="$(g -C "$SRC8D" rev-parse HEAD)"
independent() {  # $1 restored conflict repo, $2 restored detached repo
  local a b c d
  a="$( [ "$(index_listing "$1")" = "$IND_INDEX" ] && echo stages-ok || echo stages-bad)"
  b="$(g -C "$1" cat-file -e "$IND_STAGED" 2>/dev/null && echo staged-ok || echo staged-bad)"
  c="$( [ -f "$1/scratch/keep.txt" ] && [ "$(shasum -a 256 < "$1/scratch/keep.txt" | cut -c1-64)" = "$IND_IGNORED" ] && echo ignored-ok || echo ignored-bad)"
  d="$(g -C "$2" cat-file -e "$IND_DETACHED" 2>/dev/null && echo detached-ok || echo detached-bad)"
  echo "$a $b $c $d"
}
run8() {  # $1 hatch or NONE, $2 tag
  local o1 o2 s1 s2
  if [ "$1" = NONE ]; then
    o1="$(capture "$SRC8" '"ignored":["scratch/keep.txt"]')"; o2="$(capture "$SRC8D")"
  else
    o1="$(hatched "$1" capture "{\"run\":\"$RUN\",\"path\":\"$SRC8\",\"ignored\":[\"scratch/keep.txt\"]}")"
    o2="$(hatched "$1" capture "{\"run\":\"$RUN\",\"path\":\"$SRC8D\"}")"
  fi
  s1="$(field "$o1" source_id)"; s2="$(field "$o2" source_id)"
  pp restore "{\"run\":\"$RUN\",\"source\":\"$s1\",\"dest\":\"${WORK}/r8-$2\"}" >/dev/null
  pp restore "{\"run\":\"$RUN\",\"source\":\"$s2\",\"dest\":\"${WORK}/r8d-$2\"}" >/dev/null
  echo "$(field "$o1" status)/$(field "$o2" status) $(independent "${WORK}/r8-$2" "${WORK}/r8d-$2")"
}
it "positive control: a faithful capture satisfies every independent assertion"
check "complete/complete stages-ok staged-ok ignored-ok detached-ok" "$(run8 NONE ok)"
it "omitted conflict stages: the module verifier and the independent index check both fail"
check "incomplete/complete stages-bad staged-ok ignored-ok detached-ok" "$(run8 OMIT_STAGES stages)"
it "an omitted staged-only blob is caught"
check "incomplete/complete stages-ok staged-bad ignored-ok detached-ok" "$(run8 OMIT_STAGED_BLOBS staged)"
it "an omitted required ignored file is caught"
check "incomplete/complete stages-ok staged-ok ignored-bad detached-ok" "$(run8 OMIT_IGNORED ignored)"
it "an omitted detached commit is caught"
check "complete/incomplete stages-ok staged-ok ignored-ok detached-bad" "$(run8 OMIT_DETACHED detached)"

# ── Scenario 9: alternates and promisor configuration give no fallback ──────────────
SRC9="${WORK}/w/alt"
mkrepo "$SRC9"
printf 'more\n' > "$SRC9/m.txt"; g -C "$SRC9" add m.txt; g -C "$SRC9" commit -qm more
mkdir -p "${WORK}/w/borrower"; g -C "${WORK}/w/borrower" init -q
printf '%s\n' "$SRC9/.git/objects" > "${WORK}/w/borrower/.git/objects/info/alternates"
g -C "${WORK}/w/borrower" fetch -q "$SRC9" main:refs/heads/main 2>/dev/null
g -C "${WORK}/w/borrower" checkout -q main 2>/dev/null
it "a source that borrows objects through alternates refuses capture as unsupported"
check "unsupported" "$(field "$(capture "${WORK}/w/borrower")" code)"
SRC9p="${WORK}/w/promisor"
mkrepo "$SRC9p"
g -C "$SRC9p" config remote.origin.url "file://$SRC9"
g -C "$SRC9p" config remote.origin.promisor true
g -C "$SRC9p" config extensions.partialClone origin
it "a partial-clone (promisor) source refuses capture as unsupported"
check "unsupported" "$(field "$(capture "$SRC9p")" code)"
mkdir -p "${WORK}/home9"
printf '[remote "origin"]\n\turl = file://%s\n\tpromisor = true\n[extensions]\n\tpartialClone = origin\n' "$SRC9" > "${WORK}/home9/.gitconfig"
OUT="$(env HOME="${WORK}/home9" GIT_ALTERNATE_OBJECT_DIRECTORIES="$SRC9/.git/objects" \
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=remote.origin.promisor GIT_CONFIG_VALUE_0=true \
  GIT_CONFIG_KEY_1=remote.origin.url GIT_CONFIG_VALUE_1="file://$SRC9" \
  CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_PRESERVE_DROP_OBJECT=1 \
  "$PY" "$DRIVER" "$AUTO_ROOT" capture "{\"run\":\"$RUN\",\"path\":\"$SRC9\"}" 2>&1)"
it "with alternates, promisor config and the source all reachable, an incomplete bundle still fails"
check "incomplete" "$(field "$OUT" status)"
has "objects_missing" "$(field "$OUT" reasons)"
SID9="$(field "$OUT" source_id)"
OUT="$(env HOME="${WORK}/home9" GIT_ALTERNATE_OBJECT_DIRECTORIES="$SRC9/.git/objects" \
  "$PY" "$DRIVER" "$AUTO_ROOT" verify "{\"run\":\"$RUN\",\"source\":\"$SID9\"}" 2>&1)"
it "re-verifying later under the same injected environment still fails"
check "False" "$(field "$OUT" ok)"
it "the source objects were not used: the source repo is unchanged and no fetch happened"
check "0" "$(find "$SRC9/.git" -name '*.promisor' | wc -l | tr -d ' ')"

# ── Lost response and privacy of the code area ────────────────────────────────────
SRC10="${WORK}/w/replay"
mkrepo "$SRC10"
O1="$(capture "$SRC10" '"op":"op-preserve-1"')"
O2="$(capture "$SRC10" '"op":"op-preserve-1"')"
it "a retried capture with the same operation id returns the original receipt"
check "$(field "$O1" receipt_id)|True" "$(field "$O2" receipt_id)|$(field "$O2" replayed)"
it "retained code objects are private (files 0600, dirs 0700)"
check "0" "$(find "${HOME_DIR}/artifacts" \( -type f ! -perm 600 ! -name '.publish.lock' \) -o \( -type d ! -perm 700 \) | wc -l | tr -d ' ')"
it "no verifier scratch repository is left in the home"
check "0" "$(find "${HOME_DIR}" -name 'verify-*' | wc -l | tr -d ' ')"

# ── CLI: preserve-code ────────────────────────────────────────────────────────────
PROG="${AUTO_ROOT}/lib/programme.py"
SRC11="${WORK}/w/cli"
mkrepo "$SRC11"; printf 'cli wip\n' > "$SRC11/w.txt"
OUT="$("$PY" "$PROG" preserve-code --run "$RUN" --source "$SRC11" 2>&1)"
it "preserve-code captures from the driving session and reports a complete receipt"
check "True|complete|code_captured" "$(field "$OUT" ok)|$(field "$OUT" status)|$(field "$OUT" kind)"
OUT="$("$PY" "$PROG" preserve-code --run "$RUN" --source "$SRC11" --check 2>&1)"
it "preserve-code --check allows cleanup of the unchanged source"
check "True|code_cleanup_check" "$(field "$OUT" allowed)|$(field "$OUT" kind)"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-worker "$PY" "$PROG" preserve-code --run "$RUN" --source "$SRC11" 2>&1)"
it "another session may not run preserve-code"
has "driving session" "$OUT"
OUT="$("$PY" "$PROG" preserve-code --run "$RUN" --source "${WORK}/w" 2>&1)"
it "a path that is not a worktree top refuses with invalid_source"
check "False|invalid_source" "$(field "$OUT" ok)|$(field "$OUT" code)"

echo
echo "programme-preserve.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

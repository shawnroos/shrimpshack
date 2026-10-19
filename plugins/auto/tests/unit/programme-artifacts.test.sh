#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "programme-artifacts.test.sh"

WORK="$(mktemp -d -t auto-artifacts.XXXXXX)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
SECRET="fixture-value-9f8e7d"
printf 'export FIXTURE_TOKEN="%s"\n' "$SECRET" > "$CLAUDE_AUTO_SECRETS_FILE"
SRC="${WORK}/src"
mkdir -p "$SRC"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
ps = load_lib_module("programme_store")
pa = load_lib_module("programme_artifacts")
args = sys.argv[2:]
def refs(run):
    with ps.open_store(run) as s:
        return sorted(r.digest for r in s.payload_refs())
def retained(run):
    rec = load_lib_module("programme_authority").read_record(run)
    return (rec["programme"].get("retained") or {})
def code_of(fn):
    try:
        fn()
        return "ACCEPTED"
    except pa.ArtifactError as exc:
        return exc.code
$(cat)
PYEOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"
HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"
OBJ="${HOME_DIR}/artifacts/objects"
prog add-item linear:ABC-1 --run "$RUN"
prog add-item linear:ABC-2 --run "$RUN"

collect() { prog collect-result --run "$RUN" --item "$1" --attempt "$2" --source "$3" --root "$4" "${@:5}"; }
nobjects() { find "$OBJ" -type f 2>/dev/null | wc -l | tr -d ' '; }
nrefs() { run_py "$RUN" <<'EOF'
print(len(refs(args[0])))
EOF
}
leaks() { grep -rla -- "$1" "$HOME_DIR" 2>/dev/null | wc -l | tr -d ' '; }

# --- AE3: vanished worker source ------------------------------------------------
it "collect-result retains the worker's result and acknowledges its digest"
mkdir -p "${SRC}/w1/out"
printf 'build passed on 3 browsers\n' > "${SRC}/w1/out/result.txt"
collect linear:ABC-1 a1 out/result.txt "${SRC}/w1"
DIGEST="$(shasum -a 256 "${SRC}/w1/out/result.txt" | cut -d' ' -f1)"
check "0 true ${DIGEST}" "$CODE $(printf '%s' "$OUT" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(str(d["collected"]).lower(), d["ref"]["digest"])')"

it "the acknowledged digest is a committed payload reference of the store"
OUT="$(run_py "$RUN" "$DIGEST" <<'EOF'
print(args[1] in refs(args[0]))
EOF
)"
check "True" "$OUT"

it "AE3: after the synthetic source is removed, the result restores byte for byte"
rm -rf "${SRC}/w1"
OUT="$(run_py "$RUN" <<'EOF'
r = pa.restore(args[0], "result:linear:ABC-1/a1/out/result.txt")
print(r["bytes"].decode(), r["authorizes"], r["verification"], end="")
EOF
)"
check "build passed on 3 browsers
 False origin_verifier_unavailable" "$OUT"

it "the result is bound to its item, attempt, source and digest"
OUT="$(run_py "$RUN" <<'EOF'
e = retained(args[0])["results"]["result:linear:ABC-1/a1/out/result.txt"]
print(e["item"], e["attempt"], e["source"], e["provenance"], e["authorizes"], len(e["ref"]["digest"]))
EOF
)"
check "linear:ABC-1 a1 out/result.txt worker_result False 64" "$OUT"

# --- scenario 2: failures prevent success -------------------------------------
mkdir -p "${SRC}/w2"
BEFORE_OBJ="$(nobjects)"
BEFORE_REFS="$(nrefs)"

it "a missing source refuses collection (source_missing) and records the failure"
collect linear:ABC-1 a2 nope.txt "${SRC}/w2"
OUT2="$(run_py "$RUN" <<'EOF'
f = retained(args[0])["failures"][-1]
print(f["code"], f["identity"])
EOF
)"
check "1 source_missing source_missing result:linear:ABC-1/a2/nope.txt" "$CODE $(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["code"])') $OUT2"

it "an inaccessible source refuses collection (source_unreadable)"
printf 'hidden\n' > "${SRC}/w2/locked.txt"
chmod 000 "${SRC}/w2/locked.txt"
collect linear:ABC-1 a2 locked.txt "${SRC}/w2"
chmod 600 "${SRC}/w2/locked.txt"
check "1" "$CODE"
has '"code": "source_unreadable"' "$OUT"

printf 'partial result\n' > "${SRC}/w2/r.txt"
it "a short write is caught by read-back and nothing is referenced"
OUT="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_ARTIFACT_SHORT_WRITE=1 "$PY" "$PROG" collect-result --run "$RUN" \
  --item linear:ABC-1 --attempt a2 --source r.txt --root "${SRC}/w2" 2>&1)"; CODE=$?
check "1 ${BEFORE_REFS} ${BEFORE_OBJ}" "$CODE $(nrefs) $(nobjects)"
has '"code": "short_write"' "$OUT"

it "a directory-sync failure refuses collection and references nothing"
OUT="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_ARTIFACT_FAIL_DIR_SYNC=1 "$PY" "$PROG" collect-result --run "$RUN" \
  --item linear:ABC-1 --attempt a2 --source r.txt --root "${SRC}/w2" 2>&1)"; CODE=$?
check "1 ${BEFORE_REFS}" "$CODE $(nrefs)"
has '"code": "sync_failed"' "$OUT"

it "a source that does not match the claimed digest is refused (digest_mismatch)"
collect linear:ABC-1 a2 r.txt "${SRC}/w2" --digest "$(printf '%064d' 0)"
check "1 ${BEFORE_REFS}" "$CODE $(nrefs)"
has '"code": "digest_mismatch"' "$OUT"

it "the fault hooks do nothing without CLAUDE_AUTO_TEST_HARNESS"
OUT="$(env -u CLAUDE_AUTO_TEST_HARNESS CLAUDE_AUTO_TEST_ARTIFACT_SHORT_WRITE=1 CLAUDE_AUTO_TEST_ARTIFACT_FAIL_DIR_SYNC=1 "$PY" "$PROG" collect-result \
  --run "$RUN" --item linear:ABC-1 --attempt a2 --source r.txt --root "${SRC}/w2" 2>&1)"; CODE=$?
check "0" "$CODE"

# --- scenario 3: containment, size, privacy -----------------------------------
it "path traversal out of --root is refused before anything is read"
printf 'outside\n' > "${SRC}/outside.txt"
collect linear:ABC-1 a3 ../outside.txt "${SRC}/w2"
has '"code": "outside_root"' "$OUT"

it "an absolute source path is refused"
collect linear:ABC-1 a3 "${SRC}/outside.txt" "${SRC}/w2"
has '"code": "invalid_source"' "$OUT"

it "a symlinked source file is refused (symlink substitution)"
ln -s "${SRC}/outside.txt" "${SRC}/w2/link.txt"
collect linear:ABC-1 a3 link.txt "${SRC}/w2"
has '"code": "symlink"' "$OUT"

it "a source reached through a symlinked directory is refused"
mkdir -p "${SRC}/realdir" && printf 'x\n' > "${SRC}/realdir/f.txt"
ln -s "${SRC}/realdir" "${SRC}/w2/dirlink"
collect linear:ABC-1 a3 dirlink/f.txt "${SRC}/w2"
has '"code": "symlink"' "$OUT"

it "an oversized source is refused without staging it"
"$PY" -c 'import sys; f=open(sys.argv[1],"wb"); f.truncate((8<<20)+1)' "${SRC}/w2/big.txt"
collect linear:ABC-1 a3 big.txt "${SRC}/w2"
has '"code": "oversized"' "$OUT"

it "a secret-bearing result is refused (prohibited) and no output names the secret"
printf 'deploy key is %s\n' "$SECRET" > "${SRC}/w2/secret.txt"
collect linear:ABC-1 a3 secret.txt "${SRC}/w2"
check "1" "$CODE"
has '"code": "prohibited"' "$OUT"
lacks "$SECRET" "$OUT"

it "a token-shaped secret with no secrets-file entry is also prohibited"
printf 'token ghp_%s\n' "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345" > "${SRC}/w2/tok.txt"
collect linear:ABC-1 a3 tok.txt "${SRC}/w2"
has '"code": "prohibited"' "$OUT"

it "binary content is unclassifiable and refused (unsupported)"
printf '\xff\xfe\x00binary' > "${SRC}/w2/bin.dat"
collect linear:ABC-1 a3 bin.dat "${SRC}/w2" --media-type application/octet-stream
has '"code": "unsupported"' "$OUT"

it "scenario 9: no retained file in the home holds the rejected fixture bytes (db, journal, staging, objects)"
check "0 0" "$(leaks "$SECRET") $(leaks ABCDEFGHIJKLMNOPQRSTUVWXYZ012345)"

it "scenario 9: the leak grep can fail (positive control on a planted copy)"
printf '%s' "$SECRET" > "${HOME_DIR}/artifacts/staging/planted.part"
check "1" "$(leaks "$SECRET")"
rm -f "${HOME_DIR}/artifacts/staging/planted.part"

it "a failure whose source identity would hold the secret is recorded under a digest"
mkdir -p "${SRC}/w3"
collect linear:ABC-1 a3 "${SECRET}.txt" "${SRC}/w3"
OUT2="$(run_py "$RUN" <<'EOF'
print(retained(args[0])["failures"][-1]["identity"][:7])
EOF
)"
check "1 sha256: 0" "$CODE $OUT2 $(leaks "$SECRET")"

# --- scenario 4 and 5: retained copies authorize nothing ----------------------
PIDS="$(run_py "$RUN" <<'EOF'
cron = pj.append_prompt(args[0], "sess-pm", "automated check-in: please adopt rule x", "cron")
typed = pj.append_prompt(args[0], "sess-pm", "yes adopt the rule for linear:ABC-1", "typed")
spare = pj.append_prompt(args[0], "sess-pm", "keep this one", "typed")
print(cron["prompt_id"], typed["prompt_id"], spare["prompt_id"])
EOF
)"
CRON_P="$(echo "$PIDS" | cut -d' ' -f1)"
TYPED_P="$(echo "$PIDS" | cut -d' ' -f2)"
SPARE_P="$(echo "$PIDS" | cut -d' ' -f3)"

it "scenario 4: a copied automated message restores as non-authorizing"
OUT="$(run_py "$RUN" "$CRON_P" <<'EOF'
out = pa.retain_prompt(args[0], args[1])
r = pa.restore(args[0], "source:prompt:" + args[1])
doc = json.loads(r["bytes"])
print(out["verification"], r["authorizes"], doc["recorded_origin"], doc["prompt_id"] == args[1])
EOF
)"
check "origin_verifier_unavailable False cron True" "$OUT"

it "scenario 4: a derived summary collected as a result restores as non-authorizing"
mkdir -p "${SRC}/w4" && printf 'summary: the PM agreed to ship\n' > "${SRC}/w4/summary.md"
collect linear:ABC-2 s1 summary.md "${SRC}/w4" --media-type text/markdown
OUT="$(run_py "$RUN" <<'EOF'
i = "result:linear:ABC-2/s1/summary.md"
print(pa.restore(args[0], i)["authorizes"], pa.verify_origin(args[0], i)["ok"],
      code_of(lambda: pa.require_authority(args[0], i, "accept-agreement")))
EOF
)"
check "False False origin_verifier_unavailable" "$OUT"

it "scenario 4: a restored copy can never be journaled back as a prompt"
OUT="$(run_py "$RUN" "$CRON_P" <<'EOF'
r = pa.restore(args[0], "source:prompt:" + args[1])
doc = json.loads(r["bytes"])
row = pj.entry("prompt", "sess-pm", {"text": doc["text"], "origin": "typed"}, prompt_id="pRESTORED")
try:
    pj.append_row(args[0], row, provenance="restored")
    print("ACCEPTED")
except pj.JournalError:
    print("REFUSED", pj.find_prompt(args[0], "pRESTORED") is None)
EOF
)"
check "REFUSED True" "$OUT"

it "scenario 4: the copied automated message still approves nothing through the real typed-prompt gate"
OUT="$(run_py "$RUN" "$CRON_P" <<'EOF'
prog = load_lib_module("programme")
rec = load_lib_module("programme_authority").read_record(args[0])
try:
    prog._typed_prompt(args[0], rec, args[1])
    print("ACCEPTED")
except prog.ProgrammeError as exc:
    print("REFUSED", "not typed" in str(exc))
EOF
)"
check "REFUSED True" "$OUT"

it "prune keeps a prompt an inventory requires until its retained copy is readable"
OUT="$(run_py "$RUN" "$TYPED_P" "$SPARE_P" <<'EOF'
inv = pa.freeze_inventory(args[0], owner="linear:ABC-1", required=["source:prompt:" + args[1]])
removed = pj.prune_uncited_prompts(args[0], max_age_seconds=-1)
print(pj.find_prompt(args[0], args[1]) is not None, pj.find_prompt(args[0], args[2]) is None,
      inv["inventory_id"])
EOF
)"
INV_P="$(echo "$OUT" | cut -d' ' -f3)"
check "True True" "$(echo "$OUT" | cut -d' ' -f1-2)"

it "scenario 5: once retained, the original prompt can be pruned and its copy still reads"
OUT="$(run_py "$RUN" "$TYPED_P" "$INV_P" <<'EOF'
pa.retain_prompt(args[0], args[1])
receipt = pa.check_preservation(args[0], args[2])
pj.prune_uncited_prompts(args[0], max_age_seconds=-1)
doc = json.loads(pa.restore(args[0], "source:prompt:" + args[1])["bytes"])
print(receipt["status"], pj.find_prompt(args[0], args[1]) is None, doc["recorded_origin"])
EOF
)"
check "complete True typed" "$OUT"

it "scenario 5: with the original gone, authority-sensitive use refuses (origin_verifier_unavailable)"
OUT="$(run_py "$RUN" "$TYPED_P" <<'EOF'
prog = load_lib_module("programme")
rec = load_lib_module("programme_authority").read_record(args[0])
try:
    prog._typed_prompt(args[0], rec, args[1])
    gate = "ACCEPTED"
except prog.ProgrammeError:
    gate = "REFUSED"
print(gate, code_of(lambda: pa.require_authority(args[0], "source:prompt:" + args[1], "adopt-rule")),
      pa.verify_origin(args[0], "source:prompt:" + args[1])["reason"])
EOF
)"
check "REFUSED origin_verifier_unavailable origin_verifier_unavailable" "$OUT"

# --- scenario 7: omitted required result --------------------------------------
mkdir -p "${SRC}/w7" && printf 'part one\n' > "${SRC}/w7/one.txt" && printf 'part two\n' > "${SRC}/w7/two.txt"
it "scenario 7: one required result missing while every collected digest passes leaves preservation incomplete"
collect linear:ABC-2 b1 one.txt "${SRC}/w7"
OUT="$(run_py "$RUN" <<'EOF'
inv = pa.freeze_inventory(args[0], owner="linear:ABC-2",
                          required=["result:linear:ABC-2/b1/one.txt", "result:linear:ABC-2/b1/two.txt"])
r = pa.check_preservation(args[0], inv["inventory_id"])
st = {e["identity"]: e["status"] for e in r["entries"]}
gate = pa.cleanup_allowed(args[0], inv["inventory_id"])
print(r["status"], st["result:linear:ABC-2/b1/one.txt"], st["result:linear:ABC-2/b1/two.txt"],
      gate["allowed"], inv["inventory_id"])
EOF
)"
INV7="$(echo "$OUT" | cut -d' ' -f5)"
check "incomplete captured unavailable False" "$(echo "$OUT" | cut -d' ' -f1-4)"

it "scenario 7: collecting the omitted result completes preservation and opens the cleanup gate"
collect linear:ABC-2 b1 two.txt "${SRC}/w7"
OUT="$(run_py "$RUN" "$INV7" <<'EOF'
r = pa.check_preservation(args[0], args[1])
print(r["status"], pa.cleanup_allowed(args[0], args[1])["allowed"], r["receipt_id"])
EOF
)"
RCPT7="$(echo "$OUT" | cut -d' ' -f3)"
check "complete True" "$(echo "$OUT" | cut -d' ' -f1-2)"

it "scenario 8: a lost-response retry of the preservation check returns the original receipt"
OUT="$(run_py "$RUN" "$INV7" <<'EOF'
r = pa.check_preservation(args[0], args[1])
print(r["receipt_id"], r["replayed"])
EOF
)"
check "${RCPT7} True" "$OUT"

it "a retained object whose bytes changed fails its digest check and closes the cleanup gate"
TWO="$(shasum -a 256 "${SRC}/w7/two.txt" | cut -d' ' -f1)"
TWO_PATH="${OBJ}/${TWO:0:2}/${TWO}"
cp -p "$TWO_PATH" "${WORK}/two.bak"
chmod 600 "$TWO_PATH"; printf 'part TWO\n' > "$TWO_PATH"
OUT="$(run_py "$RUN" "$INV7" <<'EOF'
print(code_of(lambda: pa.restore(args[0], "result:linear:ABC-2/b1/two.txt")),
      pa.cleanup_allowed(args[0], args[1])["allowed"])
EOF
)"
check "digest_mismatch False" "$OUT"
cp -p "${WORK}/two.bak" "$TWO_PATH"

# --- scenario 8: conflicting object, lost response ----------------------------
it "scenario 8: a preexisting conflicting object is never replaced"
mkdir -p "${SRC}/w8" && printf 'genuine bytes\n' > "${SRC}/w8/g.txt"
G="$(shasum -a 256 "${SRC}/w8/g.txt" | cut -d' ' -f1)"
mkdir -p "${OBJ}/${G:0:2}" && printf 'impostor\n' > "${OBJ}/${G:0:2}/${G}"
cp "${OBJ}/${G:0:2}/${G}" "${WORK}/impostor.bak"
collect linear:ABC-2 c1 g.txt "${SRC}/w8"
check "1 same" "$CODE $(cmp -s "${WORK}/impostor.bak" "${OBJ}/${G:0:2}/${G}" && echo same || echo replaced)"
has '"code": "payload_conflict"' "$OUT"
rm -f "${OBJ}/${G:0:2}/${G}"

it "scenario 8: a lost-response retry with the same operation id replays the original receipt"
collect linear:ABC-2 c1 g.txt "${SRC}/w8" --op op-collect-1
FIRST="$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d["revision"], d["replayed"], d["ref"]["digest"])')"
collect linear:ABC-2 c1 g.txt "${SRC}/w8" --op op-collect-1
SECOND="$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d["revision"], d["replayed"], d["ref"]["digest"])')"
REV1="$(echo "$FIRST" | cut -d' ' -f1)"
check "${REV1} False ${G}|${REV1} True ${G}" "${FIRST}|${SECOND}"

# --- kill after staging, before the reference commit --------------------------
it "a collector killed after publishing, before its commit, leaves bytes but no reference; a retry reuses them"
mkdir -p "${SRC}/w9" && printf 'killed mid-collection\n' > "${SRC}/w9/k.txt"
K="$(shasum -a 256 "${SRC}/w9/k.txt" | cut -d' ' -f1)"
rm -f "${HOME_DIR}/.test-resume-artifact"
CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_ARTIFACT_PAUSE_BEFORE_COMMIT=1 "$PY" "$PROG" collect-result --run "$RUN" \
  --item linear:ABC-2 --attempt k1 --source k.txt --root "${SRC}/w9" > "${WORK}/kill.out" 2>&1 &
KPID=$!
for _ in $(seq 1 100); do grep -q paused: "${WORK}/kill.out" 2>/dev/null && break; sleep 0.1; done
kill -9 "$KPID" 2>/dev/null; wait "$KPID" 2>/dev/null
OUT="$(run_py "$RUN" "$K" <<'EOF'
print(os.path.exists(pa.object_path(args[0], args[1])), args[1] in refs(args[0]),
      "result:linear:ABC-2/k1/k.txt" in retained(args[0])["results"])
EOF
)"
check "True False False" "$OUT"
collect linear:ABC-2 k1 k.txt "${SRC}/w9"
check "0 True" "$CODE $(run_py "$RUN" "$K" <<'EOF'
print(args[1] in refs(args[0]))
EOF
)"

# --- scenario 6: concurrency --------------------------------------------------
it "scenario 6: a collection paused across end commits after it with readable bytes (preservation is allowed after end)"
mkdir -p "${SRC}/w6" && printf 'late but owned\n' > "${SRC}/w6/l.txt"
rm -f "${HOME_DIR}/.test-resume-artifact"
RUN6="$(run_py <<'EOF'
print(ph.create_programme(["w6"], "sess-pm")["run"])
EOF
)"
HOME6="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN6}"
"$PY" "$PROG" add-item linear:ABC-6 --run "$RUN6" >/dev/null 2>&1
CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_ARTIFACT_PAUSE_BEFORE_COMMIT=1 "$PY" "$PROG" collect-result --run "$RUN6" \
  --item linear:ABC-6 --attempt e1 --source l.txt --root "${SRC}/w6" > "${WORK}/end.out" 2>&1 &
EPID=$!
for _ in $(seq 1 100); do grep -q paused: "${WORK}/end.out" 2>/dev/null && break; sleep 0.1; done
run_py "$RUN6" <<'EOF' >/dev/null
ph.end_programme(args[0], "test end")
EOF
touch "${HOME6}/.test-resume-artifact"
wait "$EPID"; ECODE=$?
OUT="$(run_py "$RUN6" <<'EOF'
rec = load_lib_module("programme_authority").read_record(args[0])
ok = all(os.path.exists(pa.object_path(args[0], d)) for d in refs(args[0]))
r = pa.restore(args[0], "result:linear:ABC-6/e1/l.txt")["bytes"].decode().strip()
print(bool(rec["programme"].get("ended")), len(refs(args[0])), ok, r)
EOF
)"
check "0 True 1 True late but owned" "$ECODE $OUT"

it "scenario 6: a claim after the inventory froze makes preservation incomplete (changed), never silently complete"
OUT="$(run_py "$RUN" <<'EOF'
inv = pa.freeze_inventory(args[0], owner="linear:ABC-1", required=["result:linear:ABC-1/a1/out/result.txt"])
pj.append_claim(args[0], "sess-w", {"item": "linear:ABC-1", "deliverable": "merged", "ref": "o/r#9"})
r = pa.check_preservation(args[0], inv["inventory_id"])
st = {e["identity"]: e["status"] for e in r["entries"]}
print(r["status"], st["claims:linear:ABC-1"], pa.cleanup_allowed(args[0], inv["inventory_id"])["allowed"])
EOF
)"
check "incomplete changed False" "$OUT"

it "scenario 6: prune racing a paused prompt retention keeps the required prompt; retention then completes"
P6="$(run_py "$RUN" <<'EOF'
print(pj.append_prompt(args[0], "sess-pm", "please keep linear:ABC-2 open", "typed")["prompt_id"])
EOF
)"
INV6="$(run_py "$RUN" "$P6" <<'EOF'
print(pa.freeze_inventory(args[0], owner="linear:ABC-2", required=["source:prompt:" + args[1]])["inventory_id"])
EOF
)"
rm -f "${HOME_DIR}/.test-resume-artifact"
CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_ARTIFACT_PAUSE_BEFORE_COMMIT=1 run_py "$RUN" "$P6" > "${WORK}/prune.out" <<'EOF' &
out = pa.retain_prompt(args[0], args[1])
print("retained", out["identity"])
EOF
RPID=$!
for _ in $(seq 1 100); do grep -q paused: "${WORK}/prune.out" 2>/dev/null && break; sleep 0.1; done
KEPT="$(run_py "$RUN" "$P6" <<'EOF'
pj.prune_uncited_prompts(args[0], max_age_seconds=-1)
print(pj.find_prompt(args[0], args[1]) is not None)
EOF
)"
touch "${HOME_DIR}/.test-resume-artifact"
wait "$RPID"
OUT="$(run_py "$RUN" "$INV6" <<'EOF'
print(pa.check_preservation(args[0], args[1])["status"])
EOF
)"
check "True complete" "$KEPT $OUT"
has "retained source:prompt:${P6}" "$(cat "${WORK}/prune.out")"

it "scenario 6: a prompt pruned before retention fails collection; no reference to missing bytes exists"
P7="$(run_py "$RUN" <<'EOF'
print(pj.append_prompt(args[0], "sess-pm", "uncited and old", "typed")["prompt_id"])
EOF
)"
OUT="$(run_py "$RUN" "$P7" <<'EOF'
pj.prune_uncited_prompts(args[0], max_age_seconds=-1)
c = code_of(lambda: pa.retain_prompt(args[0], args[1]))
ok = all(os.path.exists(pa.object_path(args[0], d)) for d in refs(args[0]))
print(c, ok, "source:prompt:" + args[1] in retained(args[0])["sources"])
EOF
)"
check "source_missing True False" "$OUT"

# --- U7 hook: archive write exclusion ------------------------------------------
it "while the archive exclusion is held, a publisher refuses (home_write_excluded) and writes no bytes"
mkdir -p "${SRC}/wx" && printf 'excluded write\n' > "${SRC}/wx/x.txt"
BEFORE_OBJ="$(nobjects)"
rm -f "${WORK}/excl.release"
run_py "$RUN" "${WORK}/excl.release" "${WORK}/excl.held" > /dev/null <<'EOF' &
import time
def hold():
    open(args[2], "w").close()
    while not os.path.exists(args[1]):
        time.sleep(0.05)
pa.exclude_publishers(args[0], hold)
EOF
XPID=$!
for _ in $(seq 1 100); do [ -f "${WORK}/excl.held" ] && break; sleep 0.1; done
collect linear:ABC-2 x1 x.txt "${SRC}/wx"
touch "${WORK}/excl.release"; wait "$XPID"
check "1 ${BEFORE_OBJ}" "$CODE $(nobjects)"
has '"code": "home_write_excluded"' "$OUT"

it "the archive exclusion waits for an in-flight publisher to finish before it is granted"
rm -f "${HOME_DIR}/.test-resume-artifact" "${WORK}/drain.at" "${WORK}/resume.at"
CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_ARTIFACT_PAUSE_BEFORE_COMMIT=1 "$PY" "$PROG" collect-result --run "$RUN" \
  --item linear:ABC-2 --attempt x2 --source x.txt --root "${SRC}/wx" > "${WORK}/drain.out" 2>&1 &
DPID=$!
for _ in $(seq 1 100); do grep -q paused: "${WORK}/drain.out" 2>/dev/null && break; sleep 0.1; done
run_py "$RUN" "${WORK}/drain.at" > /dev/null <<'EOF' &
import time
pa.exclude_publishers(args[0], lambda: open(args[1], "w").write(str(time.time())))
EOF
SPID=$!
sleep 0.5
EARLY="$([ -f "${WORK}/drain.at" ] && echo granted-early || echo waiting)"
"$PY" -c 'import time; print(time.time())' > "${WORK}/resume.at"
touch "${HOME_DIR}/.test-resume-artifact"
wait "$DPID"; DCODE=$?
wait "$SPID"
ORDER="$("$PY" -c 'import sys; print(float(open(sys.argv[1]).read()) >= float(open(sys.argv[2]).read()))' "${WORK}/drain.at" "${WORK}/resume.at")"
check "waiting 0 True" "$EARLY $DCODE $ORDER"

it "after the seal, a publisher refuses before staging any byte (sealed)"
run_py "$RUN" <<'EOF' >/dev/null
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
import programme_records
programme_records.edit(args[0], "prog.setdefault('archive', {})['sealed_at'] = '2026-10-19T00:00:00Z'", globals())
EOF
printf 'after seal\n' > "${SRC}/wx/after.txt"
BEFORE_OBJ="$(nobjects)"
STAGED_BEFORE="$(find "${HOME_DIR}/artifacts/staging" -type f | wc -l | tr -d ' ')"
collect linear:ABC-2 x3 after.txt "${SRC}/wx"
check "1 ${BEFORE_OBJ} ${STAGED_BEFORE}" "$CODE $(nobjects) $(find "${HOME_DIR}/artifacts/staging" -type f | wc -l | tr -d ' ')"
has '"code": "sealed"' "$OUT"

# --- privacy of the area ------------------------------------------------------
it "every file in the artifact area is 0600 and every directory 0700"
FILES="$(find "${HOME_DIR}/artifacts" -type f | wc -l | tr -d ' ')"
BADF="$(find "${HOME_DIR}/artifacts" -type f ! -perm 600 | wc -l | tr -d ' ')"
BADD="$(find "${HOME_DIR}/artifacts" -type d ! -perm 700 | wc -l | tr -d ' ')"
if [ "$FILES" -gt 3 ]; then check "0 0" "$BADF $BADD"; else fail "only ${FILES} files: the check would pass vacuously"; fi

it "a legacy (unpromoted) programme refuses collection and is not touched"
OUT="$(run_py <<'EOF'
home = os.path.join(ph.programmes_dir(), "prog-legacy-x")
os.makedirs(home, mode=0o700)
try:
    pa.collect_result("prog-legacy-x", item="linear:A-1", attempt="a", source="f", root="/tmp")
    print("ACCEPTED")
except pa.ArtifactError as exc:
    print(exc.code, os.listdir(home))
EOF
)"
check "not_promoted []" "$OUT"

echo
echo "programme-artifacts.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

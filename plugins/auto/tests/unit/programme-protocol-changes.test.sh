#!/usr/bin/env bash
# Protocol change reporting: the acknowledged snapshot, the read-time comparison in the rules block,
# ack-protocol, and the conflict line for a grant Ruling that Authority now holds narrower.
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

echo "programme-protocol-changes.test.sh"

WORK="$(mktemp -d -t auto-programme-protocol-changes.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_CARRYOVER_STORE="${WORK}/personal/carryover.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_SPINOFF_TIMEOUT=2
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
mkdir -p "${WORK}/personal"
PERSONAL="$CLAUDE_AUTO_PERSONAL_PROTOCOL"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
for tool in board herdr spinoff; do
  code=0; [ "$tool" = spinoff ] && code=3
  printf '#!/bin/sh\nexit %s\n' "$code" > "${FAKES}/${tool}"
  chmod +x "${FAKES}/${tool}"
done
export PATH="${FAKES}:${PATH}"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "fixtures"))
from _bootstrap import load_lib_module
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
core = load_lib_module("run_record_core")
import programme_records
args = sys.argv[2:]
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

prompt() {
  run_py "$RUN" "$1" <<'EOF'
run, text = args
print(fixture_prompt(run, "sess-pm", text, "typed")["prompt_id"])
EOF
}

OUT=""
CODE=0
CRASHES=""
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
  case "$OUT" in *Traceback*) CRASHES="${CRASHES}$* | " ;; esac
}

# The rules block alone: the text between the auto-rules tags.
rules_block() {
  "$PY" "$PROG" rules --run "$RUN" 2>&1 | sed -n '/^<auto-rules>$/,/^<\/auto-rules>$/p'
}

record_digest() {
  run_py "$RUN" <<'EOF'
import hashlib
print(hashlib.sha256(json.dumps(programme_records.load(args[0]), sort_keys=True).encode()).hexdigest()[:16])
EOF
}

baseline() {
  "$PY" "$PROG" context --run "$RUN" 2>&1 | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["decisions"][sys.argv[1]]["in_force"]["baseline"])' "$1"
}

for item in herdr:a herdr:b herdr:c; do
  prog add-item "$item" --title "$item" --kind fix_only --run "$RUN"
done

# ── the acknowledged snapshot ─────────────────────────────────────────────
it "before any acknowledgement the rules block asks for one and lists no change"
OUT="$(rules_block)"
has "protocol not acknowledged" "$OUT"
lacks "protocol change:" "$OUT"

it "ack-protocol records the merged levels and rule hashes for the programme"
prog ack-protocol --run "$RUN"
check "0 act True" "$CODE $(run_py "$RUN" <<'EOF'
ack = programme_records.load(args[0])["programme"]["protocol_ack"]
snap = next(iter(ack["repos"].values()))
print(snap["autonomy"]["prod_off_flag"], all(h.startswith("sha256:") for h in snap["rules"].values()))
EOF
)"

it "after ack-protocol the rules block lists no change and asks for nothing"
OUT="$(rules_block)"
lacks "protocol not acknowledged" "$OUT"
lacks "protocol change:" "$OUT"

# ── Covers AE1: a hand edit with no programme write ──────────────────────
printf '{"protocol_format": 1, "autonomy": {"prod_off_flag": {"level": "propose"}}}' > "$PERSONAL"
BEFORE="$(record_digest)"
it "Covers AE1. a hand edit to personal Authority shows in the next rules block with its old and new level"
OUT="$(rules_block)"
has "protocol change: Authority prod_off_flag act -> propose" "$OUT"
it "Covers AE1. the comparison is made at read time: reading the rules writes nothing to the record"
check "$BEFORE" "$(record_digest)"
it "the change line sits inside the one rules block"
check "1 1" "$("$PY" "$PROG" rules --run "$RUN" 2>&1 | grep -c '^<auto-rules>$') $(rules_block | grep -c 'prod_off_flag act -> propose')"
it "the rules view data carries the change"
check '[["autonomy", "prod_off_flag", "act", "propose"]]' "$(run_py "$RUN" <<'EOF'
programme = load_lib_module("programme")
rules = programme.rules_in_force(programme_records.load(args[0]))
print(json.dumps([[c["section"], c["id"], c["was"], c["now"]] for c in rules["protocol_changes"]["changed"]]))
EOF
)"

it "Covers AE1. after ack-protocol the change is no longer listed"
prog ack-protocol --run "$RUN"
check "0" "$CODE"
lacks "protocol change: Authority prod_off_flag" "$(rules_block)"

# ── a widening rejected on this machine ──────────────────────────────────
printf '{"protocol_format": 1, "autonomy": {"prod_off_flag": {"level": "propose"}, "eval_waiver": {"level": "act"}}}' > "$PERSONAL"
it "a hand-edited widening is listed as rejected with its reason"
OUT="$(rules_block)"
has "protocol change: Authority eval_waiver at the personal layer rejected (not_adopted)" "$OUT"
lacks "eval_waiver propose -> act" "$OUT"
it "after ack-protocol the rejected widening is no longer listed"
prog ack-protocol --run "$RUN"
lacks "protocol change: Authority eval_waiver" "$(rules_block)"

# ── Done standards ────────────────────────────────────────────────────────
it "a hand-edited Done standard is listed as rejected"
"$PY" - "$PERSONAL" "${AUTO_ROOT}/protocol/defaults.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
rule = dict(next(r for r in json.load(open(sys.argv[2]))["rules"] if r["id"] == "fix-only"))
rule["requires"] = [r for r in rule["requires"] if r != "recorded"]
rule.pop("autonomy", None)
doc["rules"] = [rule]
json.dump(doc, open(sys.argv[1], "w"))
EOF
has "protocol change: Done standard fix-only at the personal layer rejected (" "$(rules_block)"
prog ack-protocol --run "$RUN"
lacks "protocol change: Done standard fix-only" "$(rules_block)"
printf '{"protocol_format": 1, "autonomy": {"prod_off_flag": {"level": "propose"}}}' > "$PERSONAL"
prog ack-protocol --run "$RUN"

it "a Done standard whose content differs from the acknowledged hash is listed as changed, a new one as added"
run_py "$RUN" <<'EOF' >/dev/null
def mutate(rec):
    snap = next(iter(rec["programme"]["protocol_ack"]["repos"].values()))
    snap["rules"]["fix-only"] = "sha256:0"
    del snap["rules"]["shared-blocker"]
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
OUT="$(rules_block)"
has "protocol change: Done standard fix-only changed" "$OUT"
has "protocol change: Done standard shared-blocker added" "$OUT"
prog ack-protocol --run "$RUN"

# ── Covers AE6: a grant Ruling that Authority now narrows ────────────────
P_G1="$(prompt 'g1: you pick the tools for herdr:a yourself, tool choice')"
prog record-ruling g1 --kind tool_choice --effect grant --scope "PM picks tools" --applies-to herdr:a \
  --prompt "$P_G1" --run "$RUN"
P_G2="$(prompt 'g2: you pick the tools for herdr:c yourself, tool choice')"
prog record-ruling g2 --kind tool_choice --effect grant --scope "PM picks tools on c" --applies-to herdr:c \
  --prompt "$P_G2" --run "$RUN"
it "a grant recorded while Authority holds act shows no conflict"
check "act" "$(baseline g1)"
lacks "Ruling conflict" "$(rules_block)"

printf '{"protocol_format": 1, "autonomy": {"prod_off_flag": {"level": "propose"}, "tool_choice": {"level": "propose"}}}' > "$PERSONAL"
it "Covers AE6. once Authority holds the kind narrower than the grant's baseline, a conflict line names the Ruling"
OUT="$(rules_block)"
has "Ruling conflict: g1 grants tool_choice on herdr:a, but Authority now holds tool_choice at propose (act when granted)" "$OUT"
has "Ruling conflict: g2" "$OUT"
it "Covers AE6. the gate applies the narrower level: the PM may not decide tool_choice on herdr:a alone"
prog log-decision --kind tool_choice --item herdr:a --why "pick a tool" --run "$RUN"
check "nonzero" "$([ "$CODE" -ne 0 ] && echo nonzero)"
it "Covers AE6. ack-protocol does not clear a conflict"
prog ack-protocol --run "$RUN"
OUT="$(rules_block)"
has "Ruling conflict: g1" "$OUT"
lacks "protocol change: Authority tool_choice" "$OUT"

it "Covers AE6. a new revision Shawn accepts records a fresh baseline and the conflict line goes"
P_W="$(prompt 'g1: add herdr:b')"
prog record-ruling g1 --kind tool_choice --effect grant --scope "PM picks tools" --applies-to herdr:a \
  --applies-to herdr:b --prompt "$P_W" --run "$RUN"
P_WA="$(prompt 'accept g1 for herdr:b too')"
prog accept-context g1 --prompt "$P_WA" --run "$RUN"
check "0 propose" "$CODE $(baseline g1)"
OUT="$(rules_block)"
lacks "Ruling conflict: g1" "$OUT"
has "Ruling conflict: g2" "$OUT"

it "Covers AE6. closing the Ruling also clears its conflict line"
prog close-ruling g2 --as fulfilled --why "tools picked" --run "$RUN"
check "0" "$CODE"
lacks "Ruling conflict" "$(rules_block)"

# ── per remit repo ────────────────────────────────────────────────────────
ALPHA="${WORK}/repos/alpha"
mkdir -p "$ALPHA"
it "a repo added to the remit has no acknowledged snapshot until ack-protocol"
OUT="$(printf '%s' "{\"spaces\":[\"w2\"],\"repos\":[{\"path\":\"${ALPHA}\",\"github\":\"shawn/alpha\"}]}" | "$PY" "$PROG" set-remit --run "$RUN" 2>&1)"
has "protocol not acknowledged for shawn/alpha" "$(rules_block)"
prog ack-protocol --run "$RUN"
check "0 shawn/alpha" "$CODE $(run_py "$RUN" <<'EOF'
print(" ".join(sorted(programme_records.load(args[0])["programme"]["protocol_ack"]["repos"])))
EOF
)"
lacks "protocol not acknowledged" "$(rules_block)"

# ── a rejected check command ──────────────────────────────────────────────
printf '{"protocol_format": 1, "autonomy": {"prod_off_flag": {"level": "propose"}}, "checks": {"shawn/alpha": {"verified.lookup": {"argv": ["lookup", "{id}"]}}}}' > "$PERSONAL"
it "an unadopted check command is listed as rejected under its own section name"
has "protocol change: check command shawn/alpha:verified.lookup at the personal layer rejected (check_not_adopted)" "$(rules_block)"
rm -f "$PERSONAL"

# ── several remit repos, each with its own project layer ─────────────────
# publish <name> [tool_choice level]: a clone whose default branch carries that project layer, if any.
publish() {
  local seed="${WORK}/seed-$1" clone="${WORK}/clone-$1"
  mkdir -p "${seed}/.claude"
  git -C "$seed" init -q -b main
  if [ -n "${2:-}" ]; then
    printf '{"protocol_format": 1, "autonomy": {"tool_choice": {"level": "%s"}}}' "$2" > "${seed}/.claude/auto-protocol.json"
  else
    : > "${seed}/README"
  fi
  git -C "$seed" add -A
  git -C "$seed" -c user.name=t -c user.email=t@t commit -q -m seed
  git clone -q "$seed" "$clone"
  printf '%s' "$clone"
}
# republish <name> <tool_choice level>: change that project layer on the default branch and fetch it.
republish() {
  local seed="${WORK}/seed-$1"
  mkdir -p "${seed}/.claude"
  printf '{"protocol_format": 1, "autonomy": {"tool_choice": {"level": "%s"}}}' "$2" > "${seed}/.claude/auto-protocol.json"
  git -C "$seed" add -A
  git -C "$seed" -c user.name=t -c user.email=t@t commit -q -m change
  git -C "${WORK}/clone-$1" fetch -q
}
remit() {
  local body='{"spaces":["w5"],"repos":['
  local sep=""
  for path in "$@"; do body="${body}${sep}{\"path\":\"${path}\"}"; sep=","; done
  OUT="$(printf '%s]}' "$body" | "$PY" "$PROG" set-remit --run "$RUN" 2>&1)"
}

REPO_ACT="$(publish act act)"
REPO_NARROW="$(publish narrow propose)"
REPO_OUT="$(publish outside)"
RUN="$(run_py <<'EOF'
print(ph.create_programme(["w5"], "sess-pm")["run"])
EOF
)"
remit "$REPO_ACT" "$REPO_OUT"
prog add-item herdr:r --title "r" --kind fix_only --repo "$REPO_ACT" --run "$RUN"
prog add-item herdr:o --title "o" --kind fix_only --repo "$REPO_OUT" --run "$RUN"
P_GP="$(prompt 'gp: tool choice across the programme is yours')"
prog record-ruling gp --kind tool_choice --effect grant --scope "PM picks tools" --prompt "$P_GP" --run "$RUN"
P_GR="$(prompt 'gr: tool choice on herdr:r is yours')"
prog record-ruling gr --kind tool_choice --effect grant --scope "PM picks tools on r" --applies-to herdr:r \
  --prompt "$P_GR" --run "$RUN"
P_GO="$(prompt 'go: tool choice on herdr:o is yours')"
prog record-ruling go --kind tool_choice --effect grant --scope "PM picks tools on o" --applies-to herdr:o \
  --prompt "$P_GO" --run "$RUN"
it "grants recorded while every repo they read holds act show no conflict"
check "act act act" "$(baseline gp) $(baseline gr) $(baseline go)"
lacks "Ruling conflict" "$(rules_block)"

remit "$REPO_ACT"
it "dropping a repo from the remit leaves its item's repo in place"
check "${REPO_OUT}" "$(run_py "$RUN" <<'EOF'
print(programme_records.load(args[0])["programme"]["items"]["herdr:o"].get("repo"))
EOF
)"
republish outside propose
it "a grant on an item whose repo is outside the remit reads that repo's layer, not the remit's"
OUT="$(rules_block)"
has "Ruling conflict: go grants tool_choice on herdr:o, but Authority now holds tool_choice at propose (act when granted)" "$OUT"
lacks "Ruling conflict: gp" "$OUT"

remit "$REPO_ACT" "$REPO_NARROW"
it "a second remit repo whose project layer narrows the kind puts a programme-wide grant in conflict at that level"
OUT="$(rules_block)"
has "Ruling conflict: gp grants tool_choice on programme, but Authority now holds tool_choice at propose (act when granted)" "$OUT"
it "an item grant reads only its own repo's layer, so the narrower repo leaves it alone"
lacks "Ruling conflict: gr" "$OUT"

it "with no grant active, only acknowledged repos are compared, and the rest are listed as unacknowledged"
prog close-ruling gp --as fulfilled --why "done" --run "$RUN"
prog close-ruling gr --as fulfilled --why "done" --run "$RUN"
prog close-ruling go --as fulfilled --why "done" --run "$RUN"
prog ack-protocol --run "$RUN"
republish narrow never
remit "$REPO_ACT" "$REPO_NARROW" "$REPO_OUT"
OUT="$(rules_block)"
has "protocol change: Authority tool_choice propose -> never (repos: ${REPO_NARROW})" "$OUT"
has "protocol not acknowledged for ${REPO_OUT}" "$OUT"
lacks "Ruling conflict" "$OUT"

it "no verb crashed with a traceback"
check "" "$CRASHES"

echo ""
echo "programme-protocol-changes.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

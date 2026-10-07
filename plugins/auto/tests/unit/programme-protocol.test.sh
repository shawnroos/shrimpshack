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

echo "programme-protocol.test.sh"

WORK="$(mktemp -d -t auto-protocol.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_MACHINE="studio"
export PROMPTS_FILE="${WORK}/prompts.json"
export APPROVALS_FILE="${WORK}/approvals.json"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
printf '%s' '{"prog-1/p1": {"origin": "typed", "text_hash": "h1"}, "prog-1/p2": {"origin": "cron", "text_hash": "h2"}}' > "$PROMPTS_FILE"

N=0
fresh() {
  N=$((N + 1))
  export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal-${N}/protocol.json"
}

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
pp = load_lib_module("programme_protocol")
args = sys.argv[2:]
with open(os.environ["PROMPTS_FILE"]) as fh:
    PROMPTS = json.load(fh)
def approvals():
    try:
        with open(os.environ["APPROVALS_FILE"]) as fh:
            return json.load(fh)
    except FileNotFoundError:
        return {}
def approve(run_id, prompt_id, digest):
    data = approvals()
    data.setdefault(run_id + "/" + prompt_id, []).append(digest)
    with open(os.environ["APPROVALS_FILE"], "w") as fh:
        json.dump(data, fh)
def lookup(run_id, prompt_id):
    prompt = PROMPTS.get(run_id + "/" + prompt_id)
    if prompt is None:
        return None
    return dict(prompt, approved=approvals().get(run_id + "/" + prompt_id, []))
def rule(rid, kinds, requires, autonomy="act"):
    return {"id": rid, "applies_when": {"change_kinds": kinds}, "requires": requires,
            "evidence_bar": {r: "checked" for r in requires}, "caveat": "", "autonomy": autonomy,
            "added_by": "shawn", "added_at": "2026-10-06T10:00:00Z", "why": "test"}
def adopt(entry, machine="studio", prompt="p1", widening=None, prompt_hash="h1", target=None):
    target = target or pp.target_of("rules", entry.get("id"))
    record = {"machine": machine, "run_id": "prog-1", "prompt_id": prompt, "quote": "yes, adopt it",
              "prompt_hash": prompt_hash, "hash": pp.content_hash(entry)}
    if widening is not None:
        record["widening"] = widening
    approve("prog-1", prompt, pp.approval_key(target, record["hash"]))
    out = dict(entry)
    out["adoption"] = record
    return out
def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(data if isinstance(data, str) else json.dumps(data))
def personal(data):
    write(os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"], data)
def seed(name, data):
    write(os.path.join(os.environ["WORK"], "seed-" + name, ".claude", "auto-protocol.json"), data)
def reasons(p):
    return sorted("%s/%s/%s" % (r["layer"], r.get("id"), r["reason"]) for r in p["rejected"])
$(cat)
PYEOF
}
export WORK

publish() {
  local name="$1" seed="${WORK}/seed-$1" bare="${WORK}/bare-$1.git" clone="${WORK}/clone-$1"
  mkdir -p "$seed"
  git -C "$seed" init -q -b main
  git -C "$seed" add -A
  git -C "$seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed
  git clone -q --bare "$seed" "$bare"
  git clone -q "$bare" "$clone"
  printf '%s' "$clone"
}

fresh
it "the default layer alone: code behind a flag needs merged, flagged, verified and recorded"
OUT="$(run_py <<'EOF'
p = pp.load(prompt_lookup=lookup)
m = pp.match(p, ["flagged_code"])
print(m["matched_rule"], m["deliverables"], p["rejected"])
EOF
)"
check "['flagged-code'] ['merged', 'flagged', 'verified', 'recorded'] []" "$OUT"

it "the default layer carries all six change-kind rules"
OUT="$(run_py <<'EOF'
p = pp.load()
for kind in ("fix_only", "shared_package", "evals_or_docs", "product_question", "shared_blocker"):
    m = pp.match(p, [kind])
    print(kind, m["matched_rule"], m["requires"], m["deliverables"])
EOF
)"
check "fix_only ['fix-only'] ['merged', 'verified', 'recorded'] ['merged', 'verified', 'recorded']
shared_package ['shared-package'] ['merged', 'released', 'recorded'] ['merged', 'released', 'recorded']
evals_or_docs ['evals-or-docs'] ['merged', 'recorded'] ['merged', 'recorded']
product_question ['product-question'] ['handed'] []
shared_blocker ['shared-blocker'] ['debugged'] []" "$OUT"

it "the default layer carries the action autonomy mapping"
OUT="$(run_py <<'EOF'
a = pp.load()["autonomy"]
print(a["merge_at_gate"]["level"], a["file_issue"]["level"], a["eval_backed_prerelease"]["level"],
      a["prod_deploy"]["level"], a["fix_other_team_code"]["level"], a["merge_around_gate"]["level"], len(a))
EOF
)"
check "act act act_and_tell propose never never 12" "$OUT"

it "two change kinds on one item union their deliverables in a fixed order"
OUT="$(run_py <<'EOF'
m = pp.match(pp.load(), ["shared_package", "flagged_code"])
print(m["matched_rule"], m["deliverables"], m["autonomy"])
EOF
)"
check "['flagged-code', 'shared-package'] ['merged', 'flagged', 'verified', 'released', 'recorded'] act_and_tell" "$OUT"

for FIELD in id applies_when requires evidence_bar caveat autonomy added_by added_at why; do
  fresh
  it "a personal rule missing ${FIELD} is rejected and the reason names the field"
  OUT="$(run_py "$FIELD" <<'EOF'
r = rule("docs-verified", ["evals_or_docs"], ["verified"])
del r[args[0]]
personal({"rules": [adopt(r)]})
p = pp.load(prompt_lookup=lookup)
hits = [x for x in p["rejected"] if x["layer"] == "personal"]
print(len(hits), hits[0]["reason"], hits[0]["detail"] == args[0], "docs-verified" in p["rules"])
EOF
)"
  check "1 missing_field True False" "$OUT"
done

fresh
it "a personal rule with an unknown key is rejected"
OUT="$(run_py <<'EOF'
r = rule("docs-verified", ["evals_or_docs"], ["verified"])
r["severity"] = "high"
personal({"rules": [adopt(r)]})
print(reasons(pp.load(prompt_lookup=lookup)))
EOF
)"
check "['personal/docs-verified/unknown_key']" "$OUT"

fresh
it "a personal rule with a well-formed adoption record adds a deliverable to docs-only changes"
OUT="$(run_py <<'EOF'
personal({"rules": [adopt(rule("docs-verified", ["evals_or_docs"], ["verified"]))]})
p = pp.load(prompt_lookup=lookup)
m = pp.match(p, ["evals_or_docs"])
print(m["matched_rule"], m["deliverables"], p["rules"]["docs-verified"]["layer"], p["rules"]["docs-verified"]["adopted_on"], p["rejected"])
EOF
)"
check "['docs-verified', 'evals-or-docs'] ['merged', 'verified', 'recorded'] personal None []" "$OUT"

fresh
it "a personal rule with no adoption record is rejected as not_adopted"
OUT="$(run_py <<'EOF'
personal({"rules": [rule("docs-verified", ["evals_or_docs"], ["verified"])]})
p = pp.load(prompt_lookup=lookup)
print(reasons(p), pp.match(p, ["evals_or_docs"])["deliverables"])
EOF
)"
check "['personal/docs-verified/not_adopted'] ['merged', 'recorded']" "$OUT"

fresh
it "a personal rule whose adoption record lacks a hash is rejected as adoption_malformed"
OUT="$(run_py <<'EOF'
r = adopt(rule("docs-verified", ["evals_or_docs"], ["verified"]))
del r["adoption"]["hash"]
personal({"rules": [r]})
print(reasons(pp.load(prompt_lookup=lookup)))
EOF
)"
check "['personal/docs-verified/adoption_malformed']" "$OUT"

fresh
it "an unknown autonomy level sometimes is rejected"
OUT="$(run_py <<'EOF'
personal({"rules": [adopt(rule("docs-verified", ["evals_or_docs"], ["verified"], autonomy="sometimes"))]})
print(reasons(pp.load(prompt_lookup=lookup)))
EOF
)"
check "['personal/docs-verified/unknown_autonomy']" "$OUT"

it "an unknown deliverable shipped is rejected"
OUT="$(run_py <<'EOF'
personal({"rules": [adopt(rule("docs-verified", ["evals_or_docs"], ["shipped"]))]})
print(reasons(pp.load(prompt_lookup=lookup)))
EOF
)"
check "['personal/docs-verified/unknown_deliverable']" "$OUT"

it "an evidence bar that does not cover every requirement is rejected"
OUT="$(run_py <<'EOF'
r = rule("docs-verified", ["evals_or_docs"], ["verified", "recorded"])
r["evidence_bar"] = {"verified": "checked"}
personal({"rules": [adopt(r)]})
print(reasons(pp.load(prompt_lookup=lookup)))
EOF
)"
check "['personal/docs-verified/bad_value']" "$OUT"

it "two rules with one id in one layer are both rejected"
OUT="$(run_py <<'EOF'
r = adopt(rule("docs-verified", ["evals_or_docs"], ["verified"]))
personal({"rules": [r, r]})
p = pp.load(prompt_lookup=lookup)
print(reasons(p), "docs-verified" in p["rules"])
EOF
)"
check "['personal/docs-verified/duplicate_id', 'personal/docs-verified/duplicate_id'] False" "$OUT"

it "a layer stamped with a newer protocol format is rejected whole"
OUT="$(run_py <<'EOF'
personal({"protocol_format": 99, "rules": [adopt(rule("docs-verified", ["evals_or_docs"], ["verified"]))]})
p = pp.load(prompt_lookup=lookup)
print(reasons(p), "docs-verified" in p["rules"])
EOF
)"
check "['personal/None/newer_format'] False" "$OUT"

it "a layer with an unknown top-level key is rejected whole"
OUT="$(run_py <<'EOF'
personal({"rulez": [], "rules": [adopt(rule("docs-verified", ["evals_or_docs"], ["verified"]))]})
p = pp.load(prompt_lookup=lookup)
print(reasons(p), "docs-verified" in p["rules"])
EOF
)"
check "['personal/None/unknown_key'] False" "$OUT"

fresh
it "a personal rule may narrow a default rule's autonomy with a plain adoption"
OUT="$(run_py <<'EOF'
personal({"rules": [adopt(rule("fix-only", ["fix_only"], ["merged", "verified", "recorded"], autonomy="propose"))]})
p = pp.load(prompt_lookup=lookup)
print(p["rules"]["fix-only"]["autonomy"], p["rules"]["fix-only"]["layer"], p["rejected"])
EOF
)"
check "propose personal []" "$OUT"

fresh
run_py <<'EOF' >/dev/null
seed("widen", {"autonomy": {"fix_other_team_code": adopt({"level": "act"}, target="autonomy:fix_other_team_code")},
               "rules": [adopt(rule("shared-blocker", ["shared_blocker"], ["debugged"], autonomy="act"))]})
EOF
REPO_W="$(publish widen)"
it "a project layer that widens fixing another team's code from never to act, unmarked, is rejected"
OUT="$(run_py "$REPO_W" <<'EOF'
p = pp.load(repo_path=args[0], prompt_lookup=lookup)
print(reasons(p), p["autonomy"]["fix_other_team_code"]["level"], p["rules"]["shared-blocker"]["autonomy"])
EOF
)"
check "['project/fix_other_team_code/widening_unmarked', 'project/shared-blocker/widening_unmarked'] never never" "$OUT"

run_py <<'EOF' >/dev/null
seed("widen2", {"autonomy": {"fix_other_team_code": adopt({"level": "act"}, widening=True, target="autonomy:fix_other_team_code")},
                "rules": [adopt(rule("shared-blocker", ["shared_blocker"], ["debugged"], autonomy="act"), widening=True)]})
EOF
REPO_W2="$(publish widen2)"
it "the same widening with a widening adoption record loads"
OUT="$(run_py "$REPO_W2" <<'EOF'
p = pp.load(repo_path=args[0], prompt_lookup=lookup)
print(p["rejected"], p["autonomy"]["fix_other_team_code"]["level"], p["autonomy"]["fix_other_team_code"]["layer"], p["rules"]["shared-blocker"]["autonomy"])
EOF
)"
check "[] act project act" "$OUT"

fresh
run_py <<'EOF' >/dev/null
seed("plain", {"rules": [adopt(rule("web-flag", ["flagged_code"], ["merged"]))]})
EOF
REPO_P="$(publish plain)"
it "a missing personal file loads the plugin and project layers with no error"
OUT="$(run_py "$REPO_P" <<'EOF'
p = pp.load(repo_path=args[0], prompt_lookup=lookup)
print(p["rejected"], p["notices"], "web-flag" in p["rules"], "flagged-code" in p["rules"])
EOF
)"
check "[] [] True True" "$OUT"

it "the personal path comes from the override, and the default path sits under ~/.claude/shared/auto"
OUT="$(run_py <<'EOF'
print(pp.personal_path() == os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"])
del os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"]
print(pp.personal_path() == os.path.expanduser("~/.claude/shared/auto/protocol.json"))
EOF
)"
check "True
True" "$OUT"

it "with the override set, a bad file at the real personal path is never read and the home stays untouched"
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}/.claude/shared/auto"
printf '{not json' > "${FAKE_HOME}/.claude/shared/auto/protocol.json"
BEFORE="$(ls -lR "${FAKE_HOME}/.claude" | shasum)"
OUT="$(HOME="$FAKE_HOME" run_py <<'EOF'
print(pp.load()["rejected"])
EOF
)"
AFTER="$(ls -lR "${FAKE_HOME}/.claude" | shasum)"
check "[] same" "$OUT $( [ "$BEFORE" = "$AFTER" ] && echo same || echo changed )"

fresh
mkdir -p "${WORK}/seed-broken/.claude"
printf '{"rules": [' > "${WORK}/seed-broken/.claude/auto-protocol.json"
REPO_B="$(publish broken)"
it "an unparseable project file rejects that layer while the others load"
OUT="$(run_py "$REPO_B" <<'EOF'
personal({"rules": [adopt(rule("docs-verified", ["evals_or_docs"], ["verified"]))]})
p = pp.load(repo_path=args[0], prompt_lookup=lookup)
print(reasons(p), "docs-verified" in p["rules"], "flagged-code" in p["rules"])
EOF
)"
check "['project/None/malformed_layer'] True True" "$OUT"

fresh
it "a personal path that is a folder rejects that layer while the others load"
mkdir -p "$CLAUDE_AUTO_PERSONAL_PROTOCOL"
OUT="$(run_py <<'EOF'
p = pp.load(prompt_lookup=lookup)
print(reasons(p), "flagged-code" in p["rules"], [l["status"] for l in p["layers"]])
EOF
)"
check "['personal/None/malformed_layer'] True ['loaded', 'rejected']" "$OUT"

fresh
it "a missing plugin file is reported, not raised"
OUT="$(run_py <<'EOF'
p = pp.load(plugin_path="/nonexistent/defaults.json")
print(reasons(p), p["rules"])
EOF
)"
check "['plugin/None/malformed_layer'] {}" "$OUT"

fresh
it "a sync-conflict copy beside the personal file is ignored and reported"
OUT="$(run_py <<'EOF'
personal({"rules": [adopt(rule("docs-verified", ["evals_or_docs"], ["verified"]))]})
base = os.path.dirname(os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"])
write(os.path.join(base, "protocol.sync-conflict-20261006-101010-ABCDEFG.json"),
      {"rules": [adopt(rule("conflict-rule", ["evals_or_docs"], ["flagged"]))]})
p = pp.load(prompt_lookup=lookup)
print([(n["layer"], n["kind"], os.path.basename(n["path"])) for n in p["notices"]], "conflict-rule" in p["rules"], "docs-verified" in p["rules"])
EOF
)"
check "[('personal', 'sync_conflict', 'protocol.sync-conflict-20261006-101010-ABCDEFG.json')] False True" "$OUT"

fresh
it "a proposed rule in the record changes no item's deliverables and is listed as proposed"
OUT="$(run_py <<'EOF'
record = {"run_kind": "programme", "programme": {"proposed_rules": [rule("docs-flagged", ["evals_or_docs"], ["flagged"])]}}
p = pp.load(prompt_lookup=lookup)
before = pp.match(p, ["evals_or_docs"])
after = pp.match(pp.load(prompt_lookup=lookup), ["evals_or_docs"])
rows = pp.summary(p, record)
print(before == after, after["deliverables"], [(r["id"], r["status"]) for r in rows if r["id"] == "docs-flagged"])
EOF
)"
check "True ['merged', 'recorded'] [('docs-flagged', 'proposed')]" "$OUT"

it "validate_proposal accepts the R19 format and refuses an adoption record or an unknown level"
OUT="$(run_py <<'EOF'
good = rule("docs-flagged", ["evals_or_docs"], ["flagged"])
print(pp.validate_proposal(good)["ok"],
      pp.validate_proposal(adopt(good))["reason"],
      pp.validate_proposal(rule("x", ["evals_or_docs"], ["flagged"], autonomy="sometimes"))["reason"])
EOF
)"
check "True unknown_key unknown_autonomy" "$OUT"

it "an item kind no rule matches gives no matching rule"
OUT="$(run_py <<'EOF'
m = pp.match(pp.load(), ["infra_migration"])
print(m["matched_rule"], m["deliverables"], m["reason"])
EOF
)"
check "None [] no_matching_rule" "$OUT"

fresh
it "a valid checks block for a repo, adopted on this machine, loads"
OUT="$(run_py <<'EOF'
personal({"checks": {"acme/web": {
    "verified.lookup": adopt({"argv": ["dd-trace", "{id}"]}, target="check:acme/web:verified.lookup"),
    "verified.deployed_sha": adopt({"argv": ["deployed-sha", "{id}", "{sha}"]}, target="check:acme/web:verified.deployed_sha")}}})
p = pp.load(repo_key="acme/web", prompt_lookup=lookup)
print(p["rejected"], p["checks"]["acme/web"]["verified.lookup"]["argv"], p["checks"]["acme/web"]["verified.deployed_sha"]["layer"])
EOF
)"
check "[] ['dd-trace', '{id}'] personal" "$OUT"

it "an unknown command key rejects the whole checks block for that repo"
OUT="$(run_py <<'EOF'
personal({"checks": {"acme/web": {
    "verified.lookup": adopt({"argv": ["dd-trace", "{id}"]}, target="check:acme/web:verified.lookup"),
    "verified.delete": adopt({"argv": ["rm", "{id}"]})}}})
p = pp.load(repo_key="acme/web", prompt_lookup=lookup)
print(reasons(p), "acme/web" in p["checks"])
EOF
)"
check "['personal/acme/web/unknown_check'] False" "$OUT"

it "a check argv with an unknown placeholder rejects the block"
OUT="$(run_py <<'EOF'
personal({"checks": {"acme/web": {"verified.lookup": adopt({"argv": ["dd-trace", "{token}"]})}}})
p = pp.load(repo_key="acme/web", prompt_lookup=lookup)
print(reasons(p), "acme/web" in p["checks"])
EOF
)"
check "['personal/acme/web/bad_value'] False" "$OUT"

it "a checks command with no local adoption is not loaded"
OUT="$(run_py <<'EOF'
personal({"checks": {"acme/web": {
    "verified.lookup": {"argv": ["dd-trace", "{id}"]},
    "verified.deployed_sha": adopt({"argv": ["deployed-sha", "{id}"]}, machine="laptop")}}})
p = pp.load(repo_key="acme/web", prompt_lookup=lookup)
print(reasons(p), p["checks"].get("acme/web", {}))
EOF
)"
check "['personal/acme/web:verified.deployed_sha/check_not_adopted_here', 'personal/acme/web:verified.lookup/check_not_adopted'] {}" "$OUT"

fresh
run_py <<'EOF' >/dev/null
seed("worker", {"rules": [adopt(rule("web-flag", ["flagged_code"], ["merged"]))],
                "checks": {"verified.lookup": adopt({"argv": ["committed-lookup", "{id}"]}, target="check:acme/web:verified.lookup")}})
EOF
REPO_K="$(publish worker)"
run_py "$REPO_K" <<'EOF' >/dev/null
path = os.path.join(args[0], ".claude", "auto-protocol.json")
write(path, {"rules": [adopt(rule("worker-rule", ["evals_or_docs"], []))],
             "checks": {"verified.lookup": adopt({"argv": ["worker-lookup", "{id}"]}, target="check:acme/web:verified.lookup")}})
EOF
git -C "$REPO_K" -c user.name=t -c user.email=t@t commit -q -am "worker edit"
run_py "$REPO_K" <<'EOF' >/dev/null
path = os.path.join(args[0], ".claude", "auto-protocol.json")
write(path, {"rules": [adopt(rule("dirty-rule", ["evals_or_docs"], []))]})
EOF
it "a worker's edits to the project file in its worktree are ignored; the default branch copy loads"
OUT="$(run_py "$REPO_K" <<'EOF'
p = pp.load(repo_path=args[0], repo_key="acme/web", prompt_lookup=lookup)
print("web-flag" in p["rules"], "worker-rule" in p["rules"], "dirty-rule" in p["rules"], p["checks"]["acme/web"]["verified.lookup"]["argv"][0], p["rejected"])
EOF
)"
check "True False False committed-lookup []" "$OUT"

it "a project checks block overrides the personal one for the same repo"
OUT="$(run_py "$REPO_K" <<'EOF'
personal({"checks": {"acme/web": {"verified.lookup": adopt({"argv": ["personal-lookup", "{id}"]}, target="check:acme/web:verified.lookup"),
                                  "verified.deployed_sha": adopt({"argv": ["personal-sha", "{sha}"]}, target="check:acme/web:verified.deployed_sha")}}})
p = pp.load(repo_path=args[0], repo_key="acme/web", prompt_lookup=lookup)
c = p["checks"]["acme/web"]
print(c["verified.lookup"]["argv"][0], c["verified.lookup"]["layer"], c["verified.deployed_sha"]["argv"][0])
EOF
)"
check "committed-lookup project personal-sha" "$OUT"

NOREMOTE="${WORK}/noremote"
mkdir -p "${NOREMOTE}/.claude"
git -C "$NOREMOTE" init -q -b main
printf '{"rules": []}' > "${NOREMOTE}/.claude/auto-protocol.json"
it "a repo with no resolvable default branch skips the project layer and reports it"
OUT="$(run_py "$NOREMOTE" <<'EOF'
p = pp.load(repo_path=args[0], prompt_lookup=lookup)
print(reasons(p), "flagged-code" in p["rules"], p["layers"][-1]["layer"], p["layers"][-1]["status"])
EOF
)"
check "['project/None/no_default_branch'] True project rejected" "$OUT"

for CASE in "missing:p9:h1" "cron:p2:h2" "mismatch:p1:other"; do
  fresh
  it "a same-machine adoption citing a prompt that is ${CASE%%:*} is rejected as adoption_unverified"
  OUT="$(run_py "$CASE" <<'EOF'
_, prompt, phash = args[0].split(":")
personal({"rules": [adopt(rule("docs-verified", ["evals_or_docs"], ["verified"]), prompt=prompt, prompt_hash=phash)]})
print(reasons(pp.load(prompt_lookup=lookup)))
EOF
)"
  check "['personal/docs-verified/adoption_unverified']" "$OUT"
done

fresh
it "a same-machine adoption with no prompt lookup available is rejected as adoption_unverified"
OUT="$(run_py <<'EOF'
personal({"rules": [adopt(rule("docs-verified", ["evals_or_docs"], ["verified"]))]})
def boom(run_id, prompt_id):
    raise RuntimeError("journal unreadable")
print(reasons(pp.load()), reasons(pp.load(prompt_lookup=boom)))
EOF
)"
check "['personal/docs-verified/adoption_unverified'] ['personal/docs-verified/adoption_unverified']" "$OUT"

it "a rule edited after adoption no longer matches its hash and is rejected"
OUT="$(run_py <<'EOF'
r = adopt(rule("docs-verified", ["evals_or_docs"], ["verified"]))
r["autonomy"] = "act_and_tell"
personal({"rules": [r]})
print(reasons(pp.load(prompt_lookup=lookup)))
EOF
)"
check "['personal/docs-verified/adoption_unverified']" "$OUT"

it "an adoption from another machine loads, marked with its machine, without a prompt lookup"
OUT="$(run_py <<'EOF'
personal({"rules": [adopt(rule("docs-verified", ["evals_or_docs"], ["verified"]), machine="laptop", prompt="p404")]})
calls = []
def spy(run_id, prompt_id):
    calls.append(prompt_id)
    return None
p = pp.load(prompt_lookup=spy)
print(p["rejected"], p["rules"]["docs-verified"]["adopted_on"], calls)
EOF
)"
check "[] laptop []" "$OUT"

fresh
run_py <<'EOF' >/dev/null
seed("foreign", {"rules": [adopt(rule("flagged-code", ["flagged_code"], ["merged"]), machine="nowhere")],
                 "autonomy": {"merge_around_gate": adopt({"level": "act"}, machine="nowhere", widening=True, target="autonomy:merge_around_gate")}})
EOF
REPO_F="$(publish foreign)"
it "a project rule and autonomy entry adopted on another machine are rejected"
OUT="$(run_py "$REPO_F" <<'EOF'
p = pp.load(repo_path=args[0], prompt_lookup=lookup)
print(reasons(p), p["rules"]["flagged-code"]["requires"], p["autonomy"]["merge_around_gate"]["level"])
EOF
)"
check "['project/flagged-code/not_adopted_here', 'project/merge_around_gate/not_adopted_here'] ['merged', 'flagged', 'verified', 'recorded'] never" "$OUT"

fresh
it "a check whose argv changed after adoption, with its hash recomputed and a real typed prompt, is rejected"
OUT="$(run_py <<'EOF'
entry = adopt({"argv": ["dd-trace", "{id}"]}, target="check:acme/web:verified.lookup")
entry["argv"] = ["forged-lookup", "{id}"]
entry["adoption"]["hash"] = pp.content_hash(entry)
personal({"checks": {"acme/web": {"verified.lookup": entry}}})
p = pp.load(repo_key="acme/web", prompt_lookup=lookup)
print(reasons(p), [r["detail"] for r in p["rejected"]], "acme/web" in p["checks"])
EOF
)"
check "['personal/acme/web:verified.lookup/adoption_unverified'] ['no approval'] False" "$OUT"

it "an approval for one autonomy action or check does not load the same content under another"
OUT="$(run_py <<'EOF'
gate = adopt({"level": "act"}, widening=True, target="autonomy:merge_around_gate")
look = adopt({"argv": ["dd-trace", "{id}"]}, target="check:acme/web:verified.lookup")
personal({"autonomy": {"merge_around_gate": gate, "full_release": dict(gate)},
          "checks": {"acme/web": {"verified.lookup": look}, "acme/api": {"verified.lookup": dict(look)}}})
p = pp.load(repo_key="acme/web", prompt_lookup=lookup)
print(reasons(p), p["autonomy"]["merge_around_gate"]["level"], p["autonomy"]["full_release"]["level"], sorted(p["checks"]))
EOF
)"
check "['personal/acme/api:verified.lookup/adoption_unverified', 'personal/full_release/adoption_unverified'] act propose ['acme/web']" "$OUT"

it "a rule rewritten after adoption, with its hash recomputed and a real typed prompt, is rejected"
OUT="$(run_py <<'EOF'
r = adopt(rule("docs-verified", ["evals_or_docs"], ["verified"]))
r["requires"] = ["merged"]
r["evidence_bar"] = {"merged": "checked"}
r["adoption"]["hash"] = pp.content_hash(r)
personal({"rules": [r]})
print(reasons(pp.load(prompt_lookup=lookup)))
EOF
)"
check "['personal/docs-verified/adoption_unverified']" "$OUT"

it "machine_name follows the override"
OUT="$(run_py <<'EOF'
print(pp.machine_name())
EOF
)"
check "studio" "$OUT"

echo ""
echo "programme-protocol.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

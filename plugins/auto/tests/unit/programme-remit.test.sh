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

echo "programme-remit.test.sh"

WORK="$(mktemp -d -t auto-programme-remit.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH HERDR_ENV CLAUDE_AUTO_REPO LINEAR_API_KEY 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
SNAP="${WORK}/snapshot.json"
BOARD="${WORK}/board.json"
mkdir -p "$FAKES"
export SNAP BOARD PY

cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
case "$1 ${2:-}" in
  "status server") echo "status: running" ;;
  "api snapshot") cat "$SNAP" ;;
  "agent list") "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1]))["result"]["snapshot"]; print(json.dumps({"result":{"agents":s["agents"]}}))' "$SNAP" ;;
esac
exit 0
EOF
cat > "${FAKES}/board" <<'EOF'
#!/bin/bash
cat "$BOARD"
EOF
chmod +x "${FAKES}"/*
export PATH="${FAKES}:/usr/bin:/bin"

mkrepo() {
  mkdir -p "$1"
  ( cd "$1" && git init -q && git checkout -q -b "$2" ) >/dev/null 2>&1
}
REPO_A="${WORK}/repos/ai-labs"
REPO_B="${WORK}/repos/other"
REPO_C="${WORK}/repos/plans-only"
mkrepo "$REPO_A" shot-kinds
mkrepo "$REPO_B" main
mkrepo "$REPO_C" main
mkdir -p "${REPO_C}/docs/plans"
printf -- '---\ntitle: Remit plan\n---\nWork for AI-1 here.\n' > "${REPO_C}/docs/plans/2026-10-07-remit-plan.md"
REPO_A="$(cd "$REPO_A" && pwd -P)"
REPO_B="$(cd "$REPO_B" && pwd -P)"
REPO_C="$(cd "$REPO_C" && pwd -P)"

"$PY" - "$SNAP" "$REPO_A" "$REPO_B" <<'PYEOF'
import json, sys
path, repo_a, repo_b = sys.argv[1:4]
def pane(pid, cwd, title, sess):
    return {"pane_id": pid, "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": "term_" + pid.split(":")[1],
            "agent": "claude", "agent_status": "idle", "cwd": cwd, "label": None,
            "terminal_title_stripped": title,
            "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sess}}
panes = [pane("w2:p30", repo_a, "AI-753 Shot kinds", "sess-w1"),
         pane("w2:p31", repo_a, "XY-12 other team", "sess-w2"),
         pane("w2:p32", repo_b, "AI-760 elsewhere", "sess-w3"),
         pane("w2:p33", repo_a, "AI-770 other project", "sess-w4"),
         pane("w2:p34", repo_a, "AI-780 no project", "sess-w5")]
doc = {"result": {"snapshot": {"workspaces": [{"workspace_id": "w2"}], "tabs": [], "panes": panes, "agents": panes}}}
json.dump(doc, open(path, "w"))
PYEOF

"$PY" - "$BOARD" <<'PYEOF'
import json, sys
def issue(title, project=None):
    out = {"title": title, "state": {"name": "In Progress", "type": "started"}, "url": "https://linear.app/x"}
    if project:
        out["project"] = {"id": "p-" + project.lower().replace(" ", "-"), "name": project}
    return out
issues = {"AI-753": issue("Shot kinds", "Cue jobs"), "XY-12": issue("Other team", "Cue jobs"),
          "AI-760": issue("Elsewhere", "Cue jobs"), "AI-770": issue("Other project", "Other"),
          "AI-780": issue("No project"), "AI-790": issue("Nobody on it", "Cue jobs")}
json.dump({"issues": issues}, open(sys.argv[1], "w"))
PYEOF

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
prog = record(run)["programme"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}
journal_count() {
  run_py "$RUN" "$1" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == args[1]]))
EOF
}
prompt() {
  run_py "$RUN" "$1" <<'EOF'
print(pj.append_prompt(args[0], "sess-pm", args[1], "typed")["prompt_id"])
EOF
}
lease_run() {
  run_py "$1" <<'EOF'
lease = ph.read_lease(ph.lease_path("default", args[0]))
print(lease["run"] if lease else "none")
EOF
}

OUT=""
CODE=0
prog() { OUT="$("$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
remit_in() { local input="$1"; shift; OUT="$(printf '%s' "$input" | "$PY" "$PROG" set-remit "$@" 2>&1)"; CODE=$?; }
jq_py() {
  "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(json.dumps(eval(sys.argv[1]), sort_keys=True))' "$1" <<< "$OUT"
}

it "a new programme's remit has empty repos and tracker scope"
check '[[], {"initiatives": [], "projects": [], "teams": []}]' "$(field '[prog["remit"]["repos"], prog["remit"]["tracker"]]')"

REMIT="{\"repos\":[{\"path\":\"${REPO_A}\",\"github\":\"shawnroos/ai-labs\"},{\"path\":\"${REPO_C}\",\"github\":null}],
 \"tracker\":{\"teams\":[{\"key\":\"AI\",\"name\":\"AI Labs\",\"id\":\"t-1\"}],\"projects\":[],\"initiatives\":[]}}"

it "set-remit before the agreement is accepted needs no prompt"
remit_in "$REMIT"
check 0 "$CODE"
check '["AI"]' "$(field '[t["key"] for t in prog["remit"]["tracker"]["teams"]]')"

it "set-remit keeps the spaces it was not given"
check '[{"server": "default", "workspace": "w2"}]' "$(field 'prog["remit"]["spaces"]')"

it "set-remit stamps the remit term as a proposal and journals remit_set"
check '"proposal" 1' "$(field 'prog["agreement"]["terms"]["remit"]["set_by"]') $(journal_count remit_set)"

it "set-remit refuses input that is not JSON"
remit_in "nope"
check 2 "$CODE"

it "set-remit refuses a relative repo path"
remit_in '{"repos":[{"path":"repos/ai-labs","github":null}]}'
check 1 "$CODE"

it "set-remit refuses a GitHub name that is not owner/name"
remit_in "{\"repos\":[{\"path\":\"${REPO_A}\",\"github\":\"not a repo\"}]}"
check 1 "$CODE"

it "set-remit refuses a team key that is not an issue prefix"
remit_in '{"tracker":{"teams":[{"key":"ai labs"}]}}'
check 1 "$CODE"

it "set-remit refuses more teams than the cap"
MANY="$("$PY" -c 'import json; print(json.dumps({"tracker": {"teams": [{"key": "T%d" % n} for n in range(30)]}}))')"
remit_in "$MANY"
check 1 "$CODE"

it "set-remit refuses an empty space list"
remit_in '{"spaces":[]}'
check 1 "$CODE"

it "a refused set-remit changes nothing"
check '["AI"]' "$(field '[t["key"] for t in prog["remit"]["tracker"]["teams"]]')"

ACCEPT="$(prompt 'accept the agreement')"
prog accept-agreement --prompt "$ACCEPT"

it "after acceptance set-remit needs a typed prompt"
remit_in '{"tracker":{"teams":[{"key":"AI"},{"key":"CUE","name":"Cue"}]}}'
check 1 "$CODE"

it "a prompt that does not name the added team is refused"
VAGUE="$(prompt 'add that other team too')"
remit_in '{"tracker":{"teams":[{"key":"AI"},{"key":"CUE","name":"Cue"}]}}' --prompt "$VAGUE"
check 1 "$CODE"
has "CUE" "$OUT"

it "a prompt naming the added team is accepted"
NAMED="$(prompt 'add the CUE team to the remit')"
remit_in '{"tracker":{"teams":[{"key":"AI"},{"key":"CUE","name":"Cue"}]}}' --prompt "$NAMED"
check 0 "$CODE"
check '["shawn", ["AI", "CUE"]]' "$(field '[prog["agreement"]["terms"]["remit"]["set_by"], [t["key"] for t in prog["remit"]["tracker"]["teams"]]]')"

it "removing a team needs a prompt naming it"
DROP="$(prompt 'drop CUE from the remit')"
remit_in '{"tracker":{"teams":[{"key":"AI"}]}}' --prompt "$DROP"
check 0 "$CODE"

it "set-remit adding a space takes its lease"
ADD="$(prompt 'add space w5 to the remit')"
remit_in '{"spaces":["w2","w5"]}' --prompt "$ADD"
check "0 $RUN" "$CODE $(lease_run w5)"

it "set-remit removing a space releases its lease"
REM="$(prompt 'remove space w5 from the remit')"
remit_in '{"spaces":["w2"]}' --prompt "$REM"
check "0 none" "$CODE $(lease_run w5)"

it "set-remit refuses a space another programme holds"
OTHER="$(run_py <<'EOF'
print(ph.create_programme(["w7"], "sess-other")["run"])
EOF
)"
HELD="$(prompt 'add space w7 to the remit')"
remit_in '{"spaces":["w2","w7"]}' --prompt "$HELD"
check "1 $OTHER [{\"server\": \"default\", \"workspace\": \"w2\"}]" "$CODE $(lease_run w7) $(field 'prog["remit"]["spaces"]')"

it "a set-remit adding a free and a held space takes neither lease"
BOTH="$(prompt 'add spaces w5 and w7 to the remit')"
remit_in '{"spaces":["w2","w5","w7"]}' --prompt "$BOTH"
check "1 none $OTHER [{\"server\": \"default\", \"workspace\": \"w2\"}]" "$CODE $(lease_run w5) $(lease_run w7) $(field 'prog["remit"]["spaces"]')"

it "a session that does not drive the programme may not set the remit"
OUT="$(printf '{"tracker":{"teams":[]}}' | CLAUDE_CODE_SESSION_ID=sess-worker "$PY" "$PROG" set-remit --run "$RUN" --prompt "$NAMED" 2>&1)"
check 1 "$?"

prog sweep
SWEEP="$OUT"

it "the sweep proposes the in-scope issues remit panes work on"
check '["linear:AI-753", "linear:AI-770", "linear:AI-780"]' "$(jq_py 'sorted(p["item"] for p in d["proposals"])')"

it "a pane on an issue outside the remit teams is skipped"
check '"issue_out_of_remit"' "$(jq_py '[s["why"] for s in d["skipped"] if s["pane"] == "w2:p31"][0]')"

it "a pane whose repo is outside the remit repos is reported, not proposed"
check '"repo_out_of_remit"' "$(jq_py '[s["why"] for s in d["skipped"] if s["pane"] == "w2:p32"][0]')"

it "in-scope issues no pane works on are unstaffed proposals"
check '["AI-790"]' "$(jq_py 'sorted(u["issue"] for u in d["unstaffed"])')"

it "unstaffed issues are never adopted"
check 'false' "$(field '"linear:AI-790" in prog["items"]')"

it "plans are read from a remit repo no pane works in"
has "$REPO_C" "$(jq_py '[r["repo"] for r in d["plans"]]')"

PROJ="$(prompt 'only the Cue jobs project')"
remit_in '{"tracker":{"teams":[{"key":"AI"}],"projects":[{"name":"Cue jobs","id":"p-cue-jobs"}]}}' --prompt "$PROJ"
prog sweep

it "with a project set, a pane on another project's issue is skipped"
check '"issue_out_of_remit"' "$(jq_py '[s["why"] for s in d["skipped"] if s["pane"] == "w2:p33"][0]')"

it "with a project set, an issue with no known project is skipped as project_unknown"
check '"project_unknown"' "$(jq_py '[s["why"] for s in d["skipped"] if s["pane"] == "w2:p34"][0]')"

it "the in-project issue is still proposed"
check '["linear:AI-753"]' "$(jq_py '[p["item"] for p in d["proposals"]]')"

it "the merged check is unknown for a PR outside the remit repos"
OUT="$(run_py "$RUN" <<'EOF'
pe = load_lib_module("programme_evidence")
prog = ph.normalize_programme(record(args[0])["programme"])
v = pe.run_check(args[0], "linear:AI-753", "merged", "someone/else#5", {"remit_repos": prog["remit"]["repos"]})
print(v["result"], "outside the remit" in (v["note"] or ""))
EOF
)"
check "unknown True" "$OUT"

it "the merged check context carries the remit repos"
OUT="$(run_py "$RUN" <<'EOF'
pe = load_lib_module("programme_evidence")
prog = ph.normalize_programme(record(args[0])["programme"])
prog["items"]["linear:AI-753"] = ph.new_item("linear:AI-753")
ctx = pe._context(None, prog, "linear:AI-753", "merged", None)
print([r["github"] for r in ctx["remit_repos"]])
EOF
)"
check "['shawnroos/ai-labs', None]" "$OUT"

it "the view shows the remit's three parts"
OUT="$(run_py "$RUN" <<'EOF'
pv = load_lib_module("programme_view")
view = pv.build(record(args[0]), [])
print("\n".join(r["text"] for r in view["rows"] if r["text"].startswith("  spaces") or r["text"].startswith("  repos") or r["text"].startswith("  tracker")))
EOF
)"
has "spaces: default.w2" "$OUT"
has "repos: shawnroos/ai-labs" "$OUT"
has "tracker: teams AI; projects Cue jobs" "$OUT"

echo
echo "programme-remit.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

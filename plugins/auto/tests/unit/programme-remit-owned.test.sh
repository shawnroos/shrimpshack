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

echo "programme-remit-owned.test.sh"

WORK="$(mktemp -d -t auto-programme-remit-owned.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"
export CLAUDE_AUTO_WORKER_WAIT="1"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH HERDR_ENV CLAUDE_AUTO_REPO LINEAR_API_KEY 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
CALLS="${WORK}/calls.log"
SNAP="${WORK}/snapshot.json"
BOARD="${WORK}/board.json"
mkdir -p "$FAKES"
export CALLS SNAP BOARD PY

cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
printf 'herdr %s\n' "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "status server") echo "status: running"; echo "version: 0.9.3" ;;
  "api snapshot") cat "$SNAP" ;;
  "agent list")
    "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1]))["result"]["snapshot"]; print(json.dumps({"id":"1","result":{"type":"agent_list","agents":s["agents"]}}))' "$SNAP" ;;
esac
exit 0
EOF

cat > "${FAKES}/board" <<'EOF'
#!/bin/bash
cat "$BOARD"
EOF

# The real spinoff prints "▸ worktree:    <path>"; FAKE_WT is that path and FAKE_PANE_CWD is where the pane really sits.
cat > "${FAKES}/spinoff" <<'EOF'
#!/bin/bash
printf 'spinoff %s\n' "$*" >> "$CALLS"
sid=""
while [ $# -gt 0 ]; do
  [ "$1" = "--session-id" ] && sid="$2"
  shift
done
[ -n "${FAKE_WT:-}" ] && echo "▸ worktree:    ${FAKE_WT}"
echo "  herdr agent pane: ${FAKE_PANE:-w2:p40} (launched with the brief)"
"$PY" - "$SNAP" "$sid" "${FAKE_PANE:-w2:p40}" "${FAKE_PANE_CWD:-${FAKE_WT:-/tmp}}" <<'PYEOF'
import json, sys
path, sid, pid, cwd = sys.argv[1:5]
doc = json.load(open(path))
snap = doc["result"]["snapshot"]
pane = {"pane_id": pid, "tab_id": "w2:t3", "workspace_id": "w2", "terminal_id": "term_" + pid.split(":")[1],
        "agent": "claude", "agent_status": "idle", "cwd": cwd, "label": "worker",
        "terminal_title_stripped": "worker",
        "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sid}}
snap["panes"].append(pane)
snap["agents"].append(pane)
json.dump(doc, open(path, "w"))
PYEOF
exit "${FAKE_SPINOFF_EXIT:-0}"
EOF
chmod +x "${FAKES}"/*
export PATH="${FAKES}:/usr/bin:/bin"

mkrepo() {
  mkdir -p "$1"
  ( cd "$1" && git init -q && git checkout -q -b main && git remote add origin "$2" ) >/dev/null 2>&1
  ( cd "$1" && pwd -P )
}
REPO_A="$(mkrepo "${WORK}/repos/ai-labs" https://github.com/acme/ai-labs.git)"
REPO_B="$(mkrepo "${WORK}/repos/other" https://example.com/not-github.git)"
WT0="$(mkrepo "${WORK}/wt/w0" https://github.com/acme/w0.git)"
WT1="$(mkrepo "${WORK}/wt/w1" https://github.com/acme/w1.git)"
WT2="$(mkrepo "${WORK}/wt/w2" https://github.com/acme/w2.git)"
ln -s "$REPO_A" "${WORK}/link-a"

"$PY" - "$SNAP" <<'PYEOF'
import json, sys
doc = {"result": {"snapshot": {"workspaces": [{"workspace_id": "w2"}], "tabs": [], "panes": [], "agents": []}}}
json.dump(doc, open(sys.argv[1], "w"))
PYEOF
echo '{"issues": {}}' > "$BOARD"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
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
items = prog["items"]
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
print(fixture_prompt(args[0], "sess-pm", args[1], "typed")["prompt_id"])
EOF
}
OUT=""
CODE=0
prog() { OUT="$("$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
remit_in() { local input="$1"; shift; OUT="$(printf '%s' "$input" | "$PY" "$PROG" set-remit "$@" 2>&1)"; CODE=$?; }
jq_py() {
  "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(json.dumps(eval(sys.argv[1]), sort_keys=True))' "$1" <<< "$OUT"
}
repo_paths() { field '[r["path"] for r in prog["remit"]["repos"]]'; }
start() {
  local item="$1"
  prog add-item "$item" --title "Worker $item"
  prog start-worker "$item" -- --name "w-${item#linear:}" --handoff /tmp/h.md
}

# R6: an empty repo list means "no limit"; a PM-created entry would narrow it, so none is added.
FAKE_WT="$WT0" start linear:AI-9
it "an empty remit repo list gets no PM-created entry"
check '[]' "$(repo_paths)"
it "that start still succeeds"
check 0 "$CODE"

remit_in "{\"repos\":[{\"path\":\"${REPO_A}\",\"github\":\"acme/ai-labs\"}]}"
it "a typed remit with one repo is the starting point"
check "[\"${REPO_A}\"]" "$(repo_paths)"
ACCEPT="$(prompt 'accept the agreement')"
prog accept-agreement --prompt "$ACCEPT"

# R1, R2: a worker the PM starts joins the remit with no typed line.
FAKE_WT="$WT1" FAKE_PANE=w2:p41 start linear:AI-1
it "start-worker succeeds"
check 0 "$CODE"
it "the worker's repo joins the remit with no typed prompt"
check "[\"${REPO_A}\", \"${WT1}\"]" "$(repo_paths)"
it "the new entry is marked PM-created with the item and the minted session"
check '["pm-created", "linear:AI-1", true]' "$(field '[[r["via"]["kind"], r["via"]["item"], r["via"]["session"] == items["linear:AI-1"]["owner"]["session_id"]] for r in prog["remit"]["repos"] if r["path"].endswith("wt/w1")][0]')"
it "the entry's GitHub name stays empty, because the worker can rewrite the worktree's git config"
check 'null' "$(field '[r["github"] for r in prog["remit"]["repos"] if r["path"].endswith("wt/w1")][0]')"
it "the typed entry carries no mark"
check 'false' "$(field '"via" in prog["remit"]["repos"][0]')"
it "the add is journaled as PM-created, apart from a typed remit_set"
check "1" "$(journal_count remit_worker_added)"
it "the item's start records the repo, so a retire can tell who else works there"
check "\"${WT1}\"" "$(field 'items["linear:AI-1"]["starts"][-1]["repo"]')"
it "the start output says what was added"
has "remit_added" "$OUT"

prog sweep
it "the sweep tracks the new pane instead of skipping it as repo_out_of_remit"
check '[]' "$(jq_py '[s for s in d["skipped"] if s["pane"] == "w2:p41"]')"

# R5: the pane's live folder is not trusted; it must match the worktree the PM launched.
FAKE_WT="$WT2" FAKE_PANE=w2:p42 FAKE_PANE_CWD="$REPO_B" start linear:AI-2
it "a pane whose folder differs from the launched worktree adds nothing"
check "[\"${REPO_A}\", \"${WT1}\"]" "$(repo_paths)"
it "the start output says why nothing was added"
has "does not match" "$OUT"

# KTD4: an existing entry is never rewritten, even through a symlink spelling.
FAKE_WT="${WORK}/link-a" FAKE_PANE=w2:p43 start linear:AI-3
it "a repo already in the remit through a symlink gets no second entry"
check "[\"${REPO_A}\", \"${WT1}\"]" "$(repo_paths)"
it "and the typed entry is not relabelled PM-created"
check 'false' "$(field '"via" in prog["remit"]["repos"][0]')"

# No worktree line from spinoff: nothing to anchor on.
FAKE_WT="" FAKE_PANE=w2:p44 FAKE_PANE_CWD="$WT2" start linear:AI-4
it "a spinoff that reports no worktree adds nothing"
check "[\"${REPO_A}\", \"${WT1}\"]" "$(repo_paths)"

# R5: stdin never sets the mark; an unchanged entry keeps the stored one.
NAMED="$(prompt "add repo other to the remit")"
remit_in "{\"repos\":[{\"path\":\"${REPO_A}\",\"github\":\"acme/ai-labs\"},{\"path\":\"${WT1}\",\"github\":\"acme/w1\",\"via\":{\"kind\":\"forged\"}},{\"path\":\"${REPO_B}\",\"github\":null,\"via\":{\"kind\":\"pm-created\",\"item\":\"linear:AI-1\"}}]}" --prompt "$NAMED"
it "a typed set-remit adding a repo succeeds"
check 0 "$CODE"
it "an unchanged PM-created entry keeps its stored mark, not the one in stdin"
check '["pm-created", "linear:AI-1"]' "$(field '[[r["via"]["kind"], r["via"]["item"]] for r in prog["remit"]["repos"] if r["path"].endswith("wt/w1")][0]')"
it "a mark smuggled in on a new repo is dropped"
check 'false' "$(field '"via" in [r for r in prog["remit"]["repos"] if r["path"] == "'"$REPO_B"'"][0]')"

# R5: after acceptance a new repo still needs the typed prompt.
remit_in "{\"repos\":[{\"path\":\"${REPO_A}\",\"github\":null},{\"path\":\"${WT0}\",\"github\":null}]}"
it "set-remit without a prompt is still refused after acceptance"
check 1 "$CODE"

# R6 + pure functions: retire and the authority consumers.
it "retiring a worker drops the entry found by its item, with the folder already gone"
check '["'"$WT1"'", null]' "$(run_py "$RUN" <<'EOF'
mod = load_lib_module("programme_remit_owned")
prog = ph.normalize_programme(record(args[0])["programme"])
shutil_rm = __import__("shutil").rmtree
shutil_rm(prog["remit"]["repos"][1]["path"])
out = mod.drop_for_item(prog, "linear:AI-1")
print(json.dumps([out["dropped"], out["reason"]]))
EOF
)"
it "the dropped entry is gone from the programme and the typed ones remain"
check '2' "$(run_py "$RUN" <<'EOF'
mod = load_lib_module("programme_remit_owned")
prog = ph.normalize_programme(record(args[0])["programme"])
mod.drop_for_item(prog, "linear:AI-1")
print(len(prog["remit"]["repos"]))
EOF
)"
it "a typed entry is never dropped by a retire"
check 'null' "$(run_py "$RUN" <<'EOF'
mod = load_lib_module("programme_remit_owned")
prog = ph.normalize_programme(record(args[0])["programme"])
del prog["remit"]["repos"][1]["via"]
print(json.dumps(mod.drop_for_item(prog, "linear:AI-1")["dropped"]))
EOF
)"
it "an entry another open item still works in is kept"
check 'null' "$(run_py "$RUN" <<'EOF'
mod = load_lib_module("programme_remit_owned")
prog = ph.normalize_programme(record(args[0])["programme"])
other = ph.new_item("linear:AI-5")
other["starts"] = [{"ok": True, "repo": prog["remit"]["repos"][1]["path"]}]
prog["items"]["linear:AI-5"] = other
print(json.dumps(mod.drop_for_item(prog, "linear:AI-1")["dropped"]))
EOF
)"
it "the last remaining entry is kept, because an empty list would mean no limit"
check '[null, 1]' "$(run_py "$RUN" <<'EOF'
mod = load_lib_module("programme_remit_owned")
prog = ph.normalize_programme(record(args[0])["programme"])
prog["remit"]["repos"] = [r for r in prog["remit"]["repos"] if r.get("via")]
out = mod.drop_for_item(prog, "linear:AI-1")
print(json.dumps([out["dropped"], len(prog["remit"]["repos"])]))
EOF
)"
it "PM-created entries are left out of the repo keys carry-over and rulings use"
check '[true, true, true, true]' "$(run_py "$RUN" <<'EOF'
co = load_lib_module("programme_carryover")
rulings = load_lib_module("programme_rulings")
changes = load_lib_module("programme_protocol_changes")
prog = ph.normalize_programme(record(args[0])["programme"])
mine = [r["path"] for r in prog["remit"]["repos"] if r.get("via")]
assert mine, "the programme should hold a PM-created entry here"
keys = co.repo_keys(prog)
paths = rulings.repos_for(prog, ["programme"])
print(json.dumps([len(prog["remit"]["repos"]) > len(keys), "acme/w1" not in keys, mine[0] not in paths,
                  mine[0] not in [p for _, p in changes._repos(prog)]]))
EOF
)"

# R4: a stale path in the stored remit never blocks a later change.
rm -rf "$WT1"
STALE="$(prompt 'refresh the remit')"
remit_in "{\"repos\":[{\"path\":\"${REPO_A}\",\"github\":\"acme/ai-labs\"},{\"path\":\"${WT1}\",\"github\":\"acme/w1\"},{\"path\":\"${REPO_B}\",\"github\":null}]}" --prompt "$STALE"
it "a stored path whose folder is gone is dropped, not a rejection"
check 0 "$CODE"
it "the drop needs no typed words naming it, and the list loses only that path"
check "[\"${REPO_A}\", \"${REPO_B}\"]" "$(repo_paths)"
it "the output carries a notice naming the dropped path"
has "$WT1" "$OUT"

remit_in "{\"repos\":[{\"path\":\"${REPO_A}\",\"github\":null},{\"path\":\"${WORK}/never/existed\",\"github\":null}]}" --prompt "$(prompt "add repo existed to the remit")"
it "a brand-new path that does not exist is still rejected"
check 1 "$CODE"

# R3 through the verb's own write: start a worker, then retire it with its folder already gone.
WT3="$(mkrepo "${WORK}/wt/w3" https://github.com/acme/w3.git)"
FAKE_WT="$WT3" FAKE_PANE=w2:p45 start linear:AI-6
it "a new worker's repo joins the remit before the retire"
has "$WT3" "$(repo_paths)"
rm -rf "$WT3"
RETIRE="$(run_py "$RUN" <<'EOF'
gone = load_lib_module("programme_gone_panes")
class Host:
    def refresh_view(self, *a, **k): pass
rec = record(args[0])
first = gone._drop_remit_entry(Host(), args[0], ph.home_path(args[0]), rec, "sess-pm", "linear:AI-6")
second = gone._drop_remit_entry(Host(), args[0], ph.home_path(args[0]), record(args[0]), "sess-pm", "linear:AI-6")
print(json.dumps([bool(first["dropped"]), second["dropped"]]))
EOF
)"
it "the retire drops the entry once and a repeat drops nothing"
check '[true, null]' "$RETIRE"
it "the remit no longer lists the retired worker's repo"
check "[\"${REPO_A}\", \"${REPO_B}\"]" "$(repo_paths)"
it "the drop is journaled as its own kind"
check "1" "$(journal_count remit_worker_dropped)"
it "a later set-remit needs no words about the retired repo"
remit_in "{\"repos\":[{\"path\":\"${REPO_A}\",\"github\":\"acme/ai-labs\"},{\"path\":\"${REPO_B}\",\"github\":null}]}" --prompt "$(prompt 'refresh the remit again')"
check 0 "$CODE"

# A launch that fails adds nothing.
WT4="$(mkrepo "${WORK}/wt/w4" https://github.com/acme/w4.git)"
FAKE_WT="$WT4" FAKE_PANE=w2:p46 FAKE_SPINOFF_EXIT=1 start linear:AI-7
it "a failed spinoff leaves the remit alone"
check "[\"${REPO_A}\", \"${REPO_B}\"]" "$(repo_paths)"

# The repo cap and the swallowed write failure.
it "a remit already at the repo cap gets no entry"
check '[null, true]' "$(run_py "$RUN" "$WT4" <<'EOF'
mod = load_lib_module("programme_remit_owned")
prog = {"remit": {"repos": [{"path": "/nowhere/%d" % n} for n in range(mod.REPO_CAP)]}}
out = mod.add_for_worker(prog, worktree=args[1], folder=args[1], item="x", session="s", at="t")
print(json.dumps([out["added"], "most it holds" in out["reason"]]))
EOF
)"
it "a failed remit write after a retire is reported, not raised"
check 'true' "$(run_py "$RUN" "$WT4" <<'EOF'
gone = load_lib_module("programme_gone_panes")
class Host:
    def refresh_view(self, *a, **k): pass
prog = ph.normalize_programme(record(args[0])["programme"])
prog["remit"]["repos"].append({"path": args[1], "github": None, "via": {"kind": "pm-created", "item": "linear:AI-7"}})
out = gone._drop_remit_entry(Host(), args[0], "/nonexistent/home", {"programme": prog}, "sess-pm", "linear:AI-7")
print(json.dumps(out["dropped"] is None and out["reason"].startswith("the remit write failed")))
EOF
)"

# A second item in one PM-created repo, and an adopted item: the entry stays until the last one leaves.
FAKE_WT="$WT4" FAKE_PANE=w2:p47 start linear:AI-8
FAKE_WT="$WT4" FAKE_PANE=w2:p48 start linear:AI-9b
it "two workers in one new repo share a single PM-created entry"
check '1' "$(field 'len([r for r in prog["remit"]["repos"] if r["path"] == "'"$WT4"'"])')"
it "the entry stays while the other worker is open and goes when the last one retires"
check '[null, true]' "$(run_py "$RUN" <<'EOF'
mod = load_lib_module("programme_remit_owned")
prog = ph.normalize_programme(record(args[0])["programme"])
first = mod.drop_for_item(prog, "linear:AI-8")["dropped"]
prog["items"]["linear:AI-9b"]["state"] = "done"
second = mod.drop_for_item(prog, "linear:AI-8")["dropped"]
print(json.dumps([first, bool(second)]))
EOF
)"
it "an adopted item with this repo as its repo also keeps the entry"
check 'null' "$(run_py "$RUN" <<'EOF'
mod = load_lib_module("programme_remit_owned")
prog = ph.normalize_programme(record(args[0])["programme"])
prog["items"]["linear:AI-9b"]["state"] = "done"
prog["items"]["linear:AI-9b"]["repo"] = None
adopted = ph.new_item("linear:AI-20")
adopted["repo"] = [r["path"] for r in prog["remit"]["repos"] if r.get("via")][0]
prog["items"]["linear:AI-20"] = adopted
print(json.dumps(mod.drop_for_item(prog, "linear:AI-8")["dropped"]))
EOF
)"

# An item cannot be pointed at a PM-created worktree to reach authority lookups.
prog add-item linear:AI-21 --title "points at the worktree" --repo "$WT4"
it "add-item --repo with a PM-created worktree leaves the item without a repo"
check 'null' "$(field 'items["linear:AI-21"].get("repo")')"

# R4 with only stale paths listed: the typed removal of the live repos is honoured, the list is not emptied.
WT5="$(mkrepo "${WORK}/wt/w5" https://github.com/acme/w5.git)"
remit_in "{\"repos\":[{\"path\":\"${REPO_A}\",\"github\":null},{\"path\":\"${REPO_B}\",\"github\":null},{\"path\":\"${WT4}\",\"github\":null},{\"path\":\"${WT5}\",\"github\":null}]}" --prompt "$(prompt 'add repo w5 to the remit')"
it "a typed set-remit adds a new repo alongside the stored ones"
check 0 "$CODE"
rm -rf "$WT5"
remit_in "{\"repos\":[{\"path\":\"${WT5}\",\"github\":null}]}" --prompt "$(prompt 'remove repos ai-labs, other and w4 from the remit')"
it "a list of only stale paths keeps those paths and honours the typed removals"
check "0 [\"${WT5}\"]" "$CODE $(repo_paths)"

echo
echo "programme-remit-owned.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
